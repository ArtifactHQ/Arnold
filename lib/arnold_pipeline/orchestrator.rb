require "arnold_pipeline/library/manager"
require "arnold_pipeline/agents/spec_generator"
require "arnold_pipeline/agents/task_breaker"
require "arnold_pipeline/agents/executor"
require "arnold_pipeline/agents/analyzer"
require "arnold_pipeline/agents/tier_gate_check"
require "arnold_pipeline/tier_calculator"

module ArnoldPipeline
  class Orchestrator
    STAGES = %i[generate_spec break_tasks execute analyze].freeze
    STAGE_CHECKPOINTS = { generate_spec: :spec, break_tasks: :tasks, execute: :executed }.freeze

    attr_reader :library_manager, :spec_generator, :task_breaker, :executor, :analyzer, :tier_gate_check, :logger

    def initialize(
      library_manager: nil,
      spec_generator: nil,
      task_breaker: nil,
      executor: nil,
      analyzer: nil,
      tier_gate_check: nil,
      logger: nil
    )
      @logger = logger || Logger.new($stdout, level: Logger::INFO)
      @library_manager = library_manager || Library::Manager.new(library_path: ArnoldPipeline.configuration.library_path)
      @spec_generator = spec_generator || Agents::SpecGenerator.new(logger: @logger)
      @task_breaker = task_breaker || Agents::TaskBreaker.new(logger: @logger)
      @executor = executor || Agents::Executor.new(logger: @logger)
      @analyzer = analyzer || Agents::Analyzer.new(logger: @logger)
      @tier_gate_check = tier_gate_check || Agents::TierGateCheck.new(logger: @logger)
    end

    def call(nl_input:, stop_after: nil)
      pipeline_run = PipelineRun.create!(nl_input:, status: :pending)
      run_pipeline!(pipeline_run, from: :generate_spec, stop_after:)
    end

    def resume(pipeline_run:, stop_after: nil)
      unless pipeline_run.paused? || pipeline_run.failed?
        raise ArgumentError, "Cannot resume a #{pipeline_run.status} pipeline run"
      end

      stage = infer_resume_stage(pipeline_run)
      run_pipeline!(pipeline_run, from: stage, stop_after:)
    end

    private

    def run_pipeline!(pipeline_run, from:, stop_after: nil)
      start_index = STAGES.index(from)

      begin
        STAGES[start_index..].each do |stage|
          if stage == :analyze
            analysis_loop!(pipeline_run)
          else
            send(:"#{stage}!", pipeline_run)
            checkpoint = STAGE_CHECKPOINTS[stage]
            if checkpoint && stop_after == checkpoint
              return pause!(pipeline_run, checkpoint)
            end
          end
        end
      rescue TierGateError => e
        logger.warn { "Pipeline paused: #{e.message}" }
        pipeline_run.reload
      rescue => e
        pipeline_run.update!(status: :failed, metadata: (pipeline_run.metadata || {}).merge("error" => e.message))
        logger.error { "Pipeline failed: #{e.message}" }
        raise
      end

      pipeline_run.reload
    end

    def generate_spec!(pipeline_run)
      pipeline_run.update!(status: :generating_spec)
      logger.info { "Generating spec..." }

      persona = library_manager.find_persona(pipeline_run.nl_input)
      recipe = library_manager.find_recipe(pipeline_run.nl_input)
      domain_type = library_manager.find_domain_type(pipeline_run.nl_input)
      logger.info { "Selected domain type: #{domain_type.code} — #{domain_type.name}" }

      result = spec_generator.call(
        nl_input: pipeline_run.nl_input,
        persona:,
        recipe:,
        domain_type:
      )

      if pipeline_run.specification
        spec = pipeline_run.specification
        spec.update!(
          content: result[:content],
          structured_data: result[:structured_data],
          version: spec.version + 1
        )
      else
        pipeline_run.create_specification!(
          content: result[:content],
          structured_data: result[:structured_data],
          version: 1
        )
      end
    end

    def break_tasks!(pipeline_run)
      pipeline_run.update!(status: :breaking_tasks)
      logger.info { "Breaking tasks..." }

      pipeline_run.tasks.destroy_all

      task_data = task_breaker.call(spec_content: pipeline_run.specification.content)

      task_data.each do |td|
        pipeline_run.tasks.create!(
          title: td["title"],
          description: td["description"],
          priority: td["priority"] || 0,
          labels: td["labels"] || [],
          position: td["position"],
          depends_on: td["depends_on"] || []
        )
      end

      TierCalculator.call(pipeline_run.tasks.reload)
    end

    def execute!(pipeline_run)
      pipeline_run.update!(status: :executing)
      logger.info { "Executing tasks..." }

      max_tier = pipeline_run.tasks.maximum(:tier) || 0
      accumulated_context = load_accumulated_context(pipeline_run)

      (0..max_tier).each do |tier_num|
        tier_tasks = pipeline_run.tasks.in_tier(tier_num).to_a

        # Resume: skip fully resolved tiers
        if tier_tasks.all? { |t| tier_task_resolved?(t) }
          logger.info { "Tier #{tier_num}: skipping (all #{tier_tasks.size} tasks already resolved)" }
          next
        end

        logger.info { "Tier #{tier_num}: executing #{tier_tasks.size} tasks" }

        prior_context = build_prior_context(accumulated_context)

        # Publish (executor skips tasks with existing external_id)
        executor.call(tasks: tier_tasks, pipeline_run:, prior_context:)

        # Await results for this tier only
        pipeline_run.update!(status: :awaiting_results)
        executor.await_results(pipeline_run:, tasks: tier_tasks)

        # Merge this tier before next tier starts
        merge_tier_results!(pipeline_run, tier_tasks)

        # Gate check + context (when either feature is enabled)
        if gate_check_needed?
          gate_result = run_tier_gate!(pipeline_run, tier_num, tier_tasks)

          if gate_result
            if ArnoldPipeline.configuration.tier_gate_enabled && !gate_result["pass"]
              handle_tier_gate_failure!(pipeline_run, tier_num, tier_tasks, gate_result, accumulated_context)
            end

            if ArnoldPipeline.configuration.context_propagation_enabled
              store_tier_context!(pipeline_run, tier_num, gate_result["context_summary"])
              accumulated_context = load_accumulated_context(pipeline_run)
            end
          end
        end
      end
    end

    def analysis_loop!(pipeline_run)
      max_iterations = ArnoldPipeline.configuration.max_iterations
      existing_iterations = pipeline_run.iterations.count
      iteration_number = existing_iterations

      loop do
        iteration_number += 1
        analysis = analyze!(pipeline_run, iteration_number)

        case analysis["decision"]
        when "done"
          pipeline_run.update!(status: :completed)
          merge_results!(pipeline_run)
          break
        when "iterate_tasks"
          handle_iterate_tasks!(pipeline_run, analysis)
          execute!(pipeline_run)
        when "iterate_spec"
          handle_iterate_spec!(pipeline_run, analysis)
          break_tasks!(pipeline_run)
          execute!(pipeline_run)
        end

        if iteration_number >= max_iterations
          pipeline_run.update!(status: :max_iterations_reached)
          merge_results!(pipeline_run)
          break
        end
      end
    end

    def analyze!(pipeline_run, iteration_number)
      pipeline_run.update!(status: :analyzing)
      logger.info { "Analyzing iteration #{iteration_number}..." }

      persona = library_manager.find_persona("testing quality review")
      tasks = pipeline_run.tasks.reload
      diffs = tasks.map { |t| t.result_diff }.compact.join("\n\n")
      comments = format_task_comments(tasks)

      result = analyzer.call(
        spec_content: pipeline_run.specification.content,
        diffs:,
        iteration_number:,
        persona:,
        comments:
      )

      pipeline_run.iterations.create!(
        number: iteration_number,
        decision: result["decision"],
        confidence: result["confidence"],
        reasoning: result["reasoning"],
        execution_results: diffs,
        corrective_data: result["corrective_data"]
      )

      logger.info { "Decision: #{result['decision']} (confidence: #{result['confidence']}%)" }

      result
    end

    def handle_iterate_tasks!(pipeline_run, analysis)
      logger.info { "Iterating tasks based on analysis feedback..." }

      corrective_tasks = analysis.dig("corrective_data", "tasks") || []
      pipeline_run.tasks.destroy_all

      corrective_tasks.each_with_index do |td, i|
        title = td["title"].presence
        unless title
          logger.warn { "Skipping corrective task at index #{i}: missing title" }
          next
        end

        pipeline_run.tasks.create!(
          title: title,
          description: td["description"],
          priority: td["priority"] || 0,
          labels: td["labels"] || [],
          position: i,
          depends_on: td["depends_on"] || []
        )
      end

      TierCalculator.call(pipeline_run.tasks.reload)
    end

    def handle_iterate_spec!(pipeline_run, analysis)
      logger.info { "Iterating spec based on analysis feedback..." }
      spec_changes = analysis.dig("corrective_data", "spec_changes") || ""

      spec = pipeline_run.specification
      updated_content = "#{spec.content}\n\n## Clarifications (Iteration)\n#{spec_changes}"
      spec.update!(content: updated_content, version: spec.version + 1)
    end

    def format_task_comments(tasks)
      sections = tasks.filter_map do |task|
        comments = task.result_comments
        next if comments.blank?

        lines = comments.map { |c| "[#{c['source']}] #{c['author']}: #{c['body']}" }
        "### Task: #{task.title} (#{task.status})\n#{lines.join("\n")}"
      end

      sections.join("\n\n")
    end

    def merge_results!(pipeline_run)
      logger.info { "Merging results..." }
      executor.merge_results(pipeline_run:)
    rescue => e
      logger.warn { "Merge failed (non-fatal): #{e.message}" }
    end

    def merge_tier_results!(pipeline_run, tier_tasks)
      logger.info { "Merging tier results..." }
      executor.merge_results(pipeline_run:, tasks: tier_tasks)
    rescue => e
      logger.warn { "Tier merge failed (non-fatal): #{e.message}" }
    end

    def gate_check_needed?
      ArnoldPipeline.configuration.tier_gate_enabled || ArnoldPipeline.configuration.context_propagation_enabled
    end

    def run_tier_gate!(pipeline_run, tier_num, tier_tasks)
      tier_tasks.each(&:reload)

      task_summaries = tier_tasks.map { |t| "- **#{t.title}**: #{t.description}" }.join("\n")
      diffs = tier_tasks.map(&:result_diff).compact.join("\n\n")
      comments = format_task_comments(tier_tasks)

      result = tier_gate_check.call(
        tier_number: tier_num,
        task_summaries: task_summaries,
        diffs: diffs,
        comments: comments
      )

      if result
        status = result["pass"] ? "PASSED" : "FAILED"
        issues = result["issues"]&.join("; ") || "none"
        logger.info { "Tier #{tier_num} gate: #{status} — issues: #{issues}" }
      end

      result
    rescue => e
      logger.warn { "Tier gate check failed (non-fatal): #{e.message}" }
      nil
    end

    def handle_tier_gate_failure!(pipeline_run, tier_num, tier_tasks, gate_result, accumulated_context)
      metadata = pipeline_run.metadata || {}
      tier_retries = metadata["tier_retries"] || {}
      retry_count = tier_retries[tier_num.to_s] || 0
      max_retries = ArnoldPipeline.configuration.max_tier_retries

      if retry_count >= max_retries
        issues_text = (gate_result["issues"] || []).join("; ")
        pipeline_run.update!(
          status: :paused,
          metadata: metadata.merge(
            "paused_at" => "tier_gate_failed",
            "tier_gate_failure" => { "tier" => tier_num, "issues" => gate_result["issues"] }
          )
        )
        raise TierGateError, "Tier #{tier_num} failed gate check after #{max_retries} retries: #{issues_text}"
      end

      # Increment retry count
      tier_retries[tier_num.to_s] = retry_count + 1
      pipeline_run.update!(metadata: metadata.merge("tier_retries" => tier_retries))

      logger.info { "Tier #{tier_num} gate failed (retry #{retry_count + 1}/#{max_retries}), creating corrective tasks" }

      # Create corrective tasks at the same tier
      corrective_tasks = gate_result["corrective_tasks"] || []
      max_position = pipeline_run.tasks.maximum(:position) || 0

      created_tasks = corrective_tasks.each_with_index.map do |td, i|
        pipeline_run.tasks.create!(
          title: td["title"],
          description: td["description"],
          labels: td["labels"] || [],
          position: max_position + i + 1,
          tier: tier_num
        )
      end

      if created_tasks.any?
        titles = created_tasks.map(&:title).join(", ")
        logger.info { "Created #{created_tasks.size} corrective tasks for tier #{tier_num}: #{titles}" }
      end

      return if created_tasks.empty?

      # Execute corrective tasks
      prior_context = build_prior_context(accumulated_context)
      pipeline_run.update!(status: :executing)
      executor.call(tasks: created_tasks, pipeline_run:, prior_context:)

      pipeline_run.update!(status: :awaiting_results)
      executor.await_results(pipeline_run:, tasks: created_tasks)

      merge_tier_results!(pipeline_run, created_tasks)

      # Re-run gate check
      all_tier_tasks = pipeline_run.tasks.in_tier(tier_num).to_a
      new_gate_result = run_tier_gate!(pipeline_run, tier_num, all_tier_tasks)

      if new_gate_result && !new_gate_result["pass"]
        handle_tier_gate_failure!(pipeline_run, tier_num, all_tier_tasks, new_gate_result, accumulated_context)
      end

      # Update context if re-gate passed
      if new_gate_result && ArnoldPipeline.configuration.context_propagation_enabled
        store_tier_context!(pipeline_run, tier_num, new_gate_result["context_summary"])
      end
    end

    def store_tier_context!(pipeline_run, tier_num, summary)
      return unless summary.present?

      metadata = pipeline_run.metadata || {}
      tier_contexts = metadata["tier_contexts"] || []
      # Replace existing context for this tier if retried
      tier_contexts.reject! { |tc| tc["tier"] == tier_num }
      tier_contexts << { "tier" => tier_num, "summary" => summary }
      pipeline_run.update!(metadata: metadata.merge("tier_contexts" => tier_contexts))
    end

    def load_accumulated_context(pipeline_run)
      (pipeline_run.metadata || {})["tier_contexts"] || []
    end

    def build_prior_context(tier_contexts)
      return nil if tier_contexts.blank?

      lines = tier_contexts.sort_by { |tc| tc["tier"] }.map do |tc|
        "**Tier #{tc['tier']} completed:** #{tc['summary']}"
      end

      "## Prior Implementation Context\n\n#{lines.join("\n\n")}"
    end

    def tier_task_resolved?(task)
      task.external_id.present? && !task.workflow_active? && (
        (task.result_diff.present? && task.result_diff != "[]") ||
        task.failed? ||
        task.has_substantive_comments?
      )
    end

    def pause!(pipeline_run, checkpoint)
      pipeline_run.update!(
        status: :paused,
        metadata: (pipeline_run.metadata || {}).merge("paused_at" => checkpoint.to_s)
      )
      pipeline_run.reload
    end

    def infer_resume_stage(pipeline_run)
      tasks = pipeline_run.tasks

      return :generate_spec unless pipeline_run.specification

      return :break_tasks if tasks.empty?

      return :execute if tasks.any? { |t| t.tier.nil? }

      return :execute if tasks.any? { |t| t.external_id.blank? }

      all_resolved = tasks.select { |t| t.external_id.present? }.all? { |t|
        !t.workflow_active? && ((t.result_diff.present? && t.result_diff != "[]") || t.failed? || t.has_substantive_comments?)
      }

      return :execute unless all_resolved

      :analyze
    end
  end
end

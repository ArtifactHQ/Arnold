require "arnold_pipeline/library/manager"
require "arnold_pipeline/agents/spec_generator"
require "arnold_pipeline/agents/task_breaker"
require "arnold_pipeline/agents/executor"
require "arnold_pipeline/agents/analyzer"
require "arnold_pipeline/agents/tier_gate_check"
require "arnold_pipeline/agents/spec_iterator"
require "arnold_pipeline/tier_calculator"
require "arnold_pipeline/tier_execution_engine"
require "arnold_pipeline/analysis_loop"
require "arnold_pipeline/resume_inferrer"
require "arnold_pipeline/pipeline_event_recorder"
require "arnold_pipeline/delta_merger"
require "open3"

module ArnoldPipeline
  class Orchestrator
    STAGES = %i[generate_spec break_tasks execute analyze].freeze
    STAGE_CHECKPOINTS = { generate_spec: :spec, break_tasks: :tasks, execute: :executed }.freeze

    attr_reader :library_manager, :spec_generator, :task_breaker, :executor, :analyzer, :tier_gate_check, :logger,
                :tier_execution_engine, :spec_iterator, :delta_merger

    def initialize(
      library_manager: nil,
      spec_generator: nil,
      task_breaker: nil,
      executor: nil,
      analyzer: nil,
      tier_gate_check: nil,
      spec_iterator: nil,
      logger: nil
    )
      @logger = logger || Logger.new($stdout, level: Logger::INFO)
      @library_manager = library_manager || Library::Manager.new(library_path: ArnoldPipeline.configuration.library_path)
      @spec_generator = spec_generator || Agents::SpecGenerator.new(logger: @logger)
      @task_breaker = task_breaker || Agents::TaskBreaker.new(logger: @logger)
      @executor = executor || Agents::Executor.new(logger: @logger)
      @analyzer = analyzer || Agents::Analyzer.new(logger: @logger)
      @tier_gate_check = tier_gate_check || Agents::TierGateCheck.new(logger: @logger)
      @spec_iterator = spec_iterator || Agents::SpecIterator.new(logger: @logger)
      @delta_merger = DeltaMerger.new(logger: @logger)
      @tier_execution_engine = TierExecutionEngine.new(executor: @executor, tier_gate_check: @tier_gate_check, logger: @logger, library_manager: @library_manager)
    end

    def call(nl_input:, stop_after: nil, pipeline_run: nil)
      ArnoldPipeline.configuration.validate!(stop_after:)
      pipeline_run ||= PipelineRun.create!(nl_input:, status: :pending)
      run_pipeline!(pipeline_run, from: :generate_spec, stop_after:)
    end

    def resume(pipeline_run:, stop_after: nil)
      ArnoldPipeline.configuration.validate!(stop_after:)
      unless pipeline_run.paused? || pipeline_run.failed?
        raise ArgumentError, "Cannot resume a #{pipeline_run.status} pipeline run"
      end

      stage = ResumeInferrer.call(pipeline_run)
      run_pipeline!(pipeline_run, from: stage, stop_after:)
    end

    def iterate_spec!(pipeline_run:, change_request:)
      validate_iterable!(pipeline_run)

      spec = pipeline_run.specification
      raise ArgumentError, "Pipeline run ##{pipeline_run.id} has no specification" unless spec

      @event_recorder = PipelineEventRecorder.new(pipeline_run:)

      result = @event_recorder.timed(
        event_type: :spec_delta_merged, stage: "iteration",
        summary: ->(r) { r || {} }
      ) do
        agent_result = spec_iterator.call(
          spec_content: spec.content,
          change_request:
        )

        raw_deltas = agent_result["deltas"]
        raise ArgumentError, "No deltas generated from change request" if raw_deltas.blank?

        # Mark existing tasks as superseded
        pipeline_run.tasks.where.not(status: :superseded).update_all(status: :superseded) if pipeline_run.tasks.any?

        delta_merger.apply!(
          spec:, raw_deltas:, change_source: "user_iterate", pipeline_run:
        )
      end

      pipeline_run.reload
      { pipeline_run:, deltas: result, spec_version: pipeline_run.specification.version }
    end

    def iterate_spec_dry_run!(pipeline_run:, change_request:)
      validate_iterable!(pipeline_run)

      spec = pipeline_run.specification
      raise ArgumentError, "Pipeline run ##{pipeline_run.id} has no specification" unless spec

      agent_result = spec_iterator.call(
        spec_content: spec.content,
        change_request:
      )

      raw_deltas = agent_result["deltas"]
      raise ArgumentError, "No deltas generated from change request" if raw_deltas.blank?

      { deltas: raw_deltas, summary: agent_result["summary"], current_version: spec.version }
    end

    def fork!(pipeline_run:, change_request:)
      unless pipeline_run.completed? || pipeline_run.max_iterations_reached?
        raise ArgumentError, "Can only fork completed or max_iterations_reached runs"
      end

      spec = pipeline_run.specification
      raise ArgumentError, "Pipeline run ##{pipeline_run.id} has no specification" unless spec

      # Generate deltas against current spec
      agent_result = spec_iterator.call(
        spec_content: spec.content,
        change_request:
      )
      raw_deltas = agent_result["deltas"]
      raise ArgumentError, "No deltas generated from change request" if raw_deltas.blank?

      # Create new pipeline run
      new_run = PipelineRun.create!(
        nl_input: pipeline_run.nl_input,
        status: :pending,
        metadata: {
          "forked_from_run_id" => pipeline_run.id,
          "fork_change_request" => change_request,
          "fork_deltas" => raw_deltas
        }
      )

      # Copy spec to new run and apply deltas
      new_spec = new_run.create_specification!(
        content: spec.content,
        structured_data: spec.structured_data,
        version: spec.version
      )

      # Transition through generating_spec (spec was "generated" via fork + iteration)
      new_run.update!(status: :generating_spec)

      @event_recorder = PipelineEventRecorder.new(pipeline_run: new_run)
      delta_merger.apply!(
        spec: new_spec, raw_deltas:, change_source: "user_iterate", pipeline_run: new_run
      )

      # Pause at spec checkpoint so resume picks it up
      new_run.update!(
        status: :paused,
        metadata: new_run.metadata.merge("paused_at" => "spec")
      )

      { pipeline_run: new_run.reload, deltas: raw_deltas }
    end

    private

    ITERABLE_STATES = %w[paused failed completed].freeze

    def validate_iterable!(pipeline_run)
      unless ITERABLE_STATES.include?(pipeline_run.status)
        raise ArgumentError, "Cannot iterate a #{pipeline_run.status} pipeline run. " \
                             "Pause or wait for completion first."
      end
    end

    def run_pipeline!(pipeline_run, from:, stop_after: nil)
      @event_recorder = PipelineEventRecorder.new(pipeline_run:)
      @tier_execution_engine = TierExecutionEngine.new(
        executor: @executor, tier_gate_check: @tier_gate_check, logger: @logger,
        event_recorder: @event_recorder, library_manager: @library_manager
      )
      start_index = STAGES.index(from)
      @current_stage = nil

      begin
        STAGES[start_index..].each do |stage|
          @current_stage = stage
          if stage == :analyze
            analysis_loop!(pipeline_run)
          else
            send(:"#{stage}!", pipeline_run)
            checkpoint = STAGE_CHECKPOINTS[stage]
            if checkpoint && stop_after == checkpoint
              @event_recorder&.record(
                event_type: :pipeline_paused, stage: "lifecycle",
                summary: { status: "paused", reason: "stop_after_#{checkpoint}" }
              )
              return pause!(pipeline_run, checkpoint)
            end
          end
        end

        @event_recorder&.record(
          event_type: :pipeline_completed, stage: "lifecycle",
          summary: build_completion_summary(pipeline_run)
        )
      rescue TierGateError => e
        @event_recorder&.record(
          event_type: :pipeline_paused, stage: "lifecycle",
          summary: { status: "paused", reason: e.message }
        )
        logger.warn { "[Arnold] Pipeline paused: #{e.message}" }
        pipeline_run.reload
      rescue => e
        config = ArnoldPipeline.configuration
        summary = {
          error_class: e.class.name, error_message: e.message,
          failed_stage: @current_stage&.to_s,
          llm_provider: config.llm_provider.to_s,
          llm_model: config.llm_model,
          execution_provider: config.execution_provider.to_s,
          backtrace: e.backtrace&.first(10),
          total_tasks: pipeline_run.tasks.count,
          tasks_succeeded: pipeline_run.tasks.where(status: :completed).count,
          tasks_failed: pipeline_run.tasks.where(status: :failed).count,
          total_duration_ms: ((Time.current - pipeline_run.created_at) * 1000).round(1)
        }

        if e.respond_to?(:raw_response) && e.raw_response
          summary[:raw_response_excerpt] = e.raw_response.to_s[0, 2000]
        end

        @event_recorder&.record(
          event_type: :pipeline_failed, stage: "lifecycle",
          summary: summary
        )
        pipeline_run.update!(status: :failed, metadata: (pipeline_run.metadata || {}).merge(
          "error" => e.message, "error_class" => e.class.name, "failed_stage" => @current_stage&.to_s
        ))
        logger.error { "[Arnold] Pipeline failed: #{e.message}" }
        raise
      end

      pipeline_run.reload
    end

    def generate_spec!(pipeline_run)
      pipeline_run.update!(status: :generating_spec)
      logger.info { "[Arnold] Generating specification..." }

      persona = library_manager.find_persona(pipeline_run.nl_input)
      recipes = library_manager.find_recipes(pipeline_run.nl_input)
      recipe = recipes[:primary]
      supporting_recipes = recipes[:supporting]
      domain_type = library_manager.find_domain_type(pipeline_run.nl_input)
      logger.info { "[Arnold] Selected domain type: #{domain_type.code} — #{domain_type.name}" }

      @event_recorder&.record(
        event_type: :library_selection, stage: "spec_generation",
        summary: {
          persona: persona&.name, recipe: recipe&.name,
          domain_type: domain_type&.code,
          supporting_recipes: supporting_recipes&.map(&:name)
        }
      )

      pipeline_run.update!(metadata: (pipeline_run.metadata || {}).merge(
        "library_selections" => {
          "persona" => persona&.name,
          "recipe" => recipe&.name,
          "supporting_recipes" => supporting_recipes&.map(&:name),
          "domain_type" => domain_type&.code
        }
      ))

      @event_recorder&.timed(
        event_type: :spec_generated, stage: "spec_generation",
        summary: ->(r) { { spec_version: r ? 1 : nil, content_length: r&.dig(:content)&.length, has_structured_data: r&.dig(:structured_data).present? } },
        payload: ->(r) { { prompt_input: pipeline_run.nl_input, response: r } }
      ) do
        result = spec_generator.call(
          nl_input: pipeline_run.nl_input,
          persona:,
          recipe:,
          supporting_recipes:,
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
          spec = pipeline_run.create_specification!(
            content: result[:content],
            structured_data: result[:structured_data],
            version: 1
          )
        end

        spec.spec_revisions.create!(
          version: spec.version,
          content: spec.content,
          structured_data: spec.structured_data,
          change_source: "spec_generation"
        )

        result
      end
    end

    def break_tasks!(pipeline_run)
      pipeline_run.update!(status: :breaking_tasks)

      fork_deltas = (pipeline_run.metadata || {})["fork_deltas"]
      if fork_deltas.present?
        logger.info { "[Arnold] Breaking specification into delta-scoped tasks (#{fork_deltas.size} deltas)..." }
      else
        logger.info { "[Arnold] Breaking specification into tasks..." }
      end

      pipeline_run.tasks.destroy_all

      @event_recorder&.timed(
        event_type: :tasks_broken, stage: "task_breakdown",
        summary: ->(_) {
          tasks = pipeline_run.tasks.reload
          {
            task_count: tasks.count,
            tier_count: (tasks.map(&:tier).compact.uniq.size),
            dependency_edge_count: tasks.sum { |t| (t.depends_on || []).size },
            delta_scoped: fork_deltas.present?
          }
        },
        payload: ->(_) { { spec_content: pipeline_run.specification&.content } }
      ) do
        recipe, supporting_recipes = resolve_recipes(pipeline_run)
        task_data = task_breaker.call(spec_content: pipeline_run.specification.content, recipe:, supporting_recipes:, deltas: fork_deltas)

        task_data.each do |td|
          pipeline_run.tasks.create!(
            title: td["title"],
            description: td["description"],
            priority: td["priority"] || 0,
            labels: td["labels"] || [],
            position: td["position"],
            depends_on: td["depends_on"] || [],
            acceptance_criteria: td["acceptance_criteria"] || []
          )
        end

        TierCalculator.call(pipeline_run.tasks.reload)

        pipeline_run.update!(
          metadata: (pipeline_run.metadata || {}).merge("tasks_generated_at_spec_version" => pipeline_run.specification.version)
        )
      end
    end

    def execute!(pipeline_run)
      record_baseline_sha!(pipeline_run)
      tier_execution_engine.execute_tiers!(pipeline_run)
    end

    def analysis_loop!(pipeline_run)
      loop = AnalysisLoop.new(
        analyzer:,
        task_breaker:,
        library_manager:,
        tier_execution_engine:,
        logger:,
        event_recorder: @event_recorder
      )
      loop.run!(pipeline_run)
    end

    def pause!(pipeline_run, checkpoint)
      pipeline_run.update!(
        status: :paused,
        metadata: (pipeline_run.metadata || {}).merge("paused_at" => checkpoint.to_s)
      )
      pipeline_run.reload
    end

    def record_baseline_sha!(pipeline_run)
      repo_path = ArnoldPipeline.configuration.claude_code_repo_path
      return unless repo_path && Dir.exist?(repo_path)

      metadata = pipeline_run.metadata || {}
      return if metadata["baseline_commit_sha"].present?

      sha, status = Open3.capture2("git", "-C", repo_path, "rev-parse", "HEAD")
      return unless status.success?

      pipeline_run.update!(metadata: metadata.merge("baseline_commit_sha" => sha.strip))
    rescue => e
      logger.warn { "[Arnold] Failed to capture baseline SHA: #{e.message}" }
    end

    def build_completion_summary(pipeline_run)
      tasks = pipeline_run.tasks
      {
        total_iterations: pipeline_run.iterations.count,
        total_tasks: tasks.count,
        total_duration_ms: ((Time.current - pipeline_run.created_at) * 1000).round(1),
        tasks_succeeded: tasks.where(status: :completed).count,
        tasks_failed: tasks.where(status: :failed).count,
        tasks_superseded: tasks.where(status: :superseded).count,
        tier_count: (tasks.maximum(:tier) || -1) + 1,
        final_confidence: pipeline_run.iterations.order(:number).last&.confidence
      }
    end

    def resolve_recipes(pipeline_run)
      structured_data = pipeline_run.specification&.structured_data || {}
      recipe_type = structured_data["recipe_type"]
      supporting_types = structured_data["supporting_recipe_types"] || []

      all_recipes = library_manager.all_recipes
      recipe = all_recipes.find { |r| r.type == recipe_type }
      supporting = supporting_types.filter_map { |t| all_recipes.find { |r| r.type == t } }

      [ recipe, supporting ]
    end
  end
end

require "arnold_pipeline/openspec_bridge"
require "arnold_pipeline/diff_summarizer"
require "arnold_pipeline/delta_merger"

module ArnoldPipeline
  class AnalysisLoop
    attr_reader :analyzer, :task_breaker, :library_manager, :tier_execution_engine, :logger, :event_recorder, :delta_merger

    def initialize(analyzer:, task_breaker:, library_manager:, tier_execution_engine:, logger: Logger.new($stdout, level: Logger::INFO), event_recorder: nil)
      @analyzer = analyzer
      @task_breaker = task_breaker
      @library_manager = library_manager
      @tier_execution_engine = tier_execution_engine
      @logger = logger
      @event_recorder = event_recorder
      @delta_merger = DeltaMerger.new(logger:)
    end

    def run!(pipeline_run)
      max_iterations = ArnoldPipeline.configuration.max_iterations
      existing_iterations = pipeline_run.iterations.count
      iteration_number = existing_iterations

      loop do
        iteration_number += 1
        analysis = analyze!(pipeline_run, iteration_number)
        analysis = maybe_promote_to_done(analysis, iteration_number)
        analysis = suppress_iterate_spec_if_stale(analysis, pipeline_run, iteration_number)

        case analysis["decision"]
        when "done"
          unless analysis["promoted_from"]
            event_recorder&.record(
              event_type: :iteration_decision, stage: "iteration",
              summary: { decision: "done" }, iteration_number: iteration_number
            )
          end
          pipeline_run.update!(status: :completed)
          tier_execution_engine.merge_all_results!(pipeline_run)
          logger.info { "[Arnold] Pipeline complete." }
          break
        when "iterate_tasks"
          corrective_count = (analysis.dig("corrective_data", "tasks") || []).size
          event_recorder&.record(
            event_type: :iteration_decision, stage: "iteration",
            summary: { decision: "iterate_tasks", corrective_task_count: corrective_count },
            iteration_number: iteration_number
          )
          handle_iterate_tasks!(pipeline_run, analysis)
          tier_execution_engine.execute_tiers!(pipeline_run, iteration_number: iteration_number)
        when "iterate_spec"
          delta_count = (analysis.dig("corrective_data", "deltas") || []).size
          event_recorder&.record(
            event_type: :iteration_decision, stage: "iteration",
            summary: { decision: "iterate_spec", delta_count: delta_count },
            iteration_number: iteration_number
          )
          handle_iterate_spec!(pipeline_run, analysis)
          break_tasks!(pipeline_run)
          tier_execution_engine.execute_tiers!(pipeline_run, iteration_number: iteration_number)
        end

        if iteration_number >= max_iterations
          pipeline_run.update!(status: :analyzing)
          pipeline_run.update!(status: :max_iterations_reached)
          tier_execution_engine.merge_all_results!(pipeline_run)
          logger.info { "[Arnold] Pipeline complete (max iterations reached)." }
          break
        end
      end
    end

    private

    def analyze!(pipeline_run, iteration_number)
      pipeline_run.update!(status: :analyzing)
      logger.info { "[Arnold] Analyzing results (iteration #{iteration_number})..." }

      persona = library_manager.find_persona("testing quality review")
      tasks = pipeline_run.tasks.reload
      diffs = DiffSummarizer.call(tasks.map(&:result_diff).compact)
      comments = tier_execution_engine.format_task_comments(tasks)
      spec_test_progress_summary = build_spec_test_progress_summary(pipeline_run)
      max_iterations = ArnoldPipeline.configuration.max_iterations
      previous_decisions = build_previous_decisions(pipeline_run)

      result = if event_recorder
        event_recorder.timed(
          event_type: :analysis_completed, stage: "analysis",
          summary: ->(r) {
            {
              decision: r&.dig("decision"),
              confidence: r&.dig("confidence"),
              reasoning_excerpt: r&.dig("reasoning")&.to_s&.slice(0, 200)
            }
          },
          payload: ->(r) { { spec_content: pipeline_run.specification.content, diffs: diffs, response: r } },
          iteration_number: iteration_number
        ) do
          analyzer.call(spec_content: pipeline_run.specification.content, diffs:, iteration_number:, persona:, comments:,
                        spec_test_progress_summary:, max_iterations:, previous_decisions:)
        end
      else
        analyzer.call(spec_content: pipeline_run.specification.content, diffs:, iteration_number:, persona:, comments:,
                      spec_test_progress_summary:, max_iterations:, previous_decisions:)
      end

      pipeline_run.iterations.create!(
        number: iteration_number,
        decision: result["decision"],
        confidence: result["confidence"],
        reasoning: result["reasoning"],
        execution_results: diffs,
        corrective_data: result["corrective_data"]
      )

      logger.info { "[Arnold] Decision: #{result['decision']} (confidence: #{result['confidence']}%)" }

      result
    end

    def build_previous_decisions(pipeline_run)
      pipeline_run.iterations.order(:number).map do |iter|
        {
          iteration: iter.number,
          decision: iter.decision,
          confidence: iter.confidence,
          reasoning_excerpt: iter.reasoning&.to_s&.slice(0, 200)
        }
      end
    end

    def maybe_promote_to_done(analysis, iteration_number)
      threshold = ArnoldPipeline.configuration.analysis_done_threshold
      return analysis unless threshold
      return analysis unless analysis["decision"] == "iterate_tasks"
      return analysis unless analysis["confidence"] && analysis["confidence"] >= threshold

      logger.info { "[Arnold] Promoting iterate_tasks to done (confidence #{analysis['confidence']}% >= threshold #{threshold}%)" }
      event_recorder&.record(
        event_type: :iteration_decision, stage: "iteration",
        summary: {
          decision: "done",
          promoted_from: "iterate_tasks",
          confidence: analysis["confidence"],
          threshold: threshold
        },
        iteration_number: iteration_number
      )

      analysis.merge("decision" => "done", "promoted_from" => "iterate_tasks")
    end

    def suppress_iterate_spec_if_stale(analysis, pipeline_run, iteration_number)
      return analysis unless analysis["decision"] == "iterate_spec"

      tasks_spec_version = (pipeline_run.metadata || {})["tasks_generated_at_spec_version"]
      current_spec_version = pipeline_run.specification&.version

      return analysis unless tasks_spec_version && current_spec_version
      return analysis unless current_spec_version > tasks_spec_version

      logger.info { "[Arnold] Suppressing iterate_spec — spec v#{current_spec_version} is ahead of tasks generated at v#{tasks_spec_version}" }
      event_recorder&.record(
        event_type: :iteration_decision, stage: "iteration",
        summary: {
          decision: "done",
          suppressed_from: "iterate_spec",
          reason: "spec_version_skew",
          tasks_spec_version: tasks_spec_version,
          current_spec_version: current_spec_version
        },
        iteration_number: iteration_number
      )

      analysis.merge("decision" => "done", "suppressed_from" => "iterate_spec")
    end

    def handle_iterate_tasks!(pipeline_run, analysis)
      logger.info { "[Arnold] Iterating tasks based on analysis feedback..." }

      corrective_tasks = analysis.dig("corrective_data", "tasks") || []
      sanitize_dependencies!(corrective_tasks)
      pipeline_run.tasks.destroy_all

      corrective_tasks.each_with_index do |td, i|
        title = td["title"].presence
        unless title
          logger.warn { "[Arnold] Skipping corrective task at index #{i}: missing title" }
          next
        end

        pipeline_run.tasks.create!(
          title: title,
          description: td["description"],
          priority: td["priority"] || 0,
          labels: td["labels"] || [],
          position: i,
          depends_on: td["depends_on"] || [],
          acceptance_criteria: td["acceptance_criteria"] || []
        )
      end

      TierCalculator.call(pipeline_run.tasks.reload)
    end

    def handle_iterate_spec!(pipeline_run, analysis)
      logger.info { "[Arnold] Iterating spec based on analysis feedback..." }

      spec = pipeline_run.specification
      raw_deltas = analysis.dig("corrective_data", "deltas")

      if raw_deltas.present?
        iteration = pipeline_run.iterations.order(:number).last
        result = delta_merger.apply!(
          spec:, raw_deltas:, change_source: "iterate_spec",
          pipeline_run:, iteration:
        )
        event_recorder&.record(
          event_type: :spec_delta_merged, stage: "iteration",
          summary: result
        )
      else
        legacy_append!(spec, analysis)
        event_recorder&.record(
          event_type: :spec_delta_merged, stage: "iteration",
          summary: { merge_strategy: "legacy", delta_count: 0, new_version: spec.reload.version }
        )
      end
    end

    def legacy_append!(spec, analysis)
      spec_changes = analysis.dig("corrective_data", "spec_changes") || ""
      updated_content = "#{spec.content}\n\n## Clarifications (Iteration)\n#{spec_changes}"
      spec.update!(content: updated_content, version: spec.version + 1)
    end

    def break_tasks!(pipeline_run)
      pipeline_run.update!(status: :breaking_tasks)
      logger.info { "[Arnold] Breaking specification into tasks..." }

      pipeline_run.tasks.destroy_all

      recipe, supporting_recipes = resolve_recipes(pipeline_run)
      task_data = task_breaker.call(spec_content: pipeline_run.specification.content, recipe:, supporting_recipes:)

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

      pipeline_run.update!(
        metadata: (pipeline_run.metadata || {}).merge("tasks_generated_at_spec_version" => pipeline_run.specification.version)
      )
    end

    def build_spec_test_progress_summary(pipeline_run)
      return nil unless ArnoldPipeline.configuration.spec_test_generation_enabled

      metadata = pipeline_run.metadata || {}
      results = metadata["spec_test_results"]
      return nil unless results

      total = results["total"] || 0
      passing = results["passing_count"] || 0
      return nil if total == 0

      rate = (passing.to_f / total * 100).round(1)
      "Spec test coverage: #{passing}/#{total} passing (#{rate}%)"
    rescue => e # mutant:disable
      logger.warn { "[Arnold] Failed to build spec test progress summary: #{e.message}" }
      nil
    end

    def resolve_recipes(pipeline_run)
      structured_data = pipeline_run.specification&.structured_data || {}
      recipe_type = structured_data["recipe_type"]
      supporting_types = structured_data["supporting_recipe_types"] || []

      all_recipes = library_manager.all_recipes
      recipe = all_recipes.find { |r| r.type == recipe_type }
      supporting = supporting_types.filter_map { |t| all_recipes.find { |r| r.type == t } }

      [recipe, supporting]
    end

    # Sanitize corrective task dependencies before persisting.
    # Strips self-referential deps, references to non-existent positions,
    # and uses Kahn's algorithm to detect and strip circular dependencies.
    def sanitize_dependencies!(tasks)
      positions = Set.new(tasks.each_index.to_a)

      tasks.each_with_index do |task, i|
        deps = task["depends_on"] || []
        task["depends_on"] = deps.select { |dep| positions.include?(dep) && dep != i }
      end

      # Kahn's algorithm to detect cycles
      in_degree = Array.new(tasks.size, 0)
      tasks.each_with_index do |task, i|
        task["depends_on"].each { |_| in_degree[i] += 1 }
      end

      queue = (0...tasks.size).select { |i| in_degree[i].zero? }
      sorted_count = 0

      until queue.empty?
        pos = queue.shift
        sorted_count += 1

        tasks.each_with_index do |other, j|
          next unless other["depends_on"].include?(pos)
          in_degree[j] -= 1
          queue << j if in_degree[j].zero?
        end
      end

      if sorted_count < tasks.size
        logger.warn { "[Arnold] Dependency cycle detected in corrective tasks, stripping circular dependencies" }
        tasks.each { |task| task["depends_on"] = [] }
      end
    end
  end
end

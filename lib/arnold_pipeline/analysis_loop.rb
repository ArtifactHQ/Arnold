require "arnold_pipeline/openspec_bridge"
require "arnold_pipeline/diff_summarizer"

module ArnoldPipeline
  class AnalysisLoop
    attr_reader :analyzer, :task_breaker, :library_manager, :tier_execution_engine, :logger, :event_recorder

    def initialize(analyzer:, task_breaker:, library_manager:, tier_execution_engine:, logger: Logger.new($stdout, level: Logger::INFO), event_recorder: nil)
      @analyzer = analyzer
      @task_breaker = task_breaker
      @library_manager = library_manager
      @tier_execution_engine = tier_execution_engine
      @logger = logger
      @event_recorder = event_recorder
    end

    def run!(pipeline_run)
      max_iterations = ArnoldPipeline.configuration.max_iterations
      existing_iterations = pipeline_run.iterations.count
      iteration_number = existing_iterations

      loop do
        iteration_number += 1
        analysis = analyze!(pipeline_run, iteration_number)

        case analysis["decision"]
        when "done"
          event_recorder&.record(
            event_type: :iteration_decision, stage: "iteration",
            summary: { decision: "done" }, iteration_number: iteration_number
          )
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
          tier_execution_engine.execute_tiers!(pipeline_run)
        when "iterate_spec"
          delta_count = (analysis.dig("corrective_data", "deltas") || []).size
          event_recorder&.record(
            event_type: :iteration_decision, stage: "iteration",
            summary: { decision: "iterate_spec", delta_count: delta_count },
            iteration_number: iteration_number
          )
          handle_iterate_spec!(pipeline_run, analysis)
          break_tasks!(pipeline_run)
          tier_execution_engine.execute_tiers!(pipeline_run)
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
          analyzer.call(spec_content: pipeline_run.specification.content, diffs:, iteration_number:, persona:, comments:)
        end
      else
        analyzer.call(spec_content: pipeline_run.specification.content, diffs:, iteration_number:, persona:, comments:)
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

    def handle_iterate_tasks!(pipeline_run, analysis)
      logger.info { "[Arnold] Iterating tasks based on analysis feedback..." }

      corrective_tasks = analysis.dig("corrective_data", "tasks") || []
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
        persist_deltas!(spec, pipeline_run, raw_deltas)
        merge_deltas!(spec, raw_deltas, pipeline_run)
        snapshot_revision!(spec, raw_deltas, "iterate_spec")

        merge_strategy = if ArnoldPipeline.configuration.openspec_enabled
          "openspec"
        else
          "append"
        end
        event_recorder&.record(
          event_type: :spec_delta_merged, stage: "iteration",
          summary: {
            merge_strategy: merge_strategy,
            delta_count: raw_deltas.size,
            new_version: spec.reload.version
          }
        )
      else
        legacy_append!(spec, analysis)
        event_recorder&.record(
          event_type: :spec_delta_merged, stage: "iteration",
          summary: { merge_strategy: "legacy", delta_count: 0, new_version: spec.reload.version }
        )
      end
    end

    def merge_deltas!(spec, deltas, pipeline_run)
      if ArnoldPipeline.configuration.openspec_enabled
        merged = openspec_merge(spec, deltas, pipeline_run)
        return if merged
      end
      append_deltas!(spec, deltas)
    end

    def openspec_merge(spec, deltas, pipeline_run)
      iteration = pipeline_run.iterations.order(:number).last

      OpenspecBridge.with_workspace(logger:) do |bridge|
        bridge.write_spec!(spec)
        change_name = "iteration-#{iteration.number}"
        merged_content = bridge.write_delta_and_merge!(
          change_name:, deltas:
        )

        if merged_content
          spec.update!(content: merged_content, version: spec.version + 1)
          true
        end
      end
    rescue => e
      logger.warn { "[Arnold] OpenSpec merge error: #{e.message}" }
      nil
    end

    def append_deltas!(spec, deltas)
      additions = deltas.select { |d| d["operation"] == "added" }.map { |d| d["content"] || d["after_content"] }
      modifications = deltas.select { |d| d["operation"] == "modified" }.map { |d| d["after_content"] }
      removals = deltas.select { |d| d["operation"] == "removed" }.map { |d| "REMOVED: #{d['requirement']} — #{d['rationale']}" }

      clarifications = (additions + modifications + removals).compact.join("\n\n")
      updated_content = "#{spec.content}\n\n## Spec Iteration\n#{clarifications}"
      spec.update!(content: updated_content, version: spec.version + 1)
    end

    def legacy_append!(spec, analysis)
      spec_changes = analysis.dig("corrective_data", "spec_changes") || ""
      updated_content = "#{spec.content}\n\n## Clarifications (Iteration)\n#{spec_changes}"
      spec.update!(content: updated_content, version: spec.version + 1)
    end

    def persist_deltas!(spec, pipeline_run, raw_deltas)
      iteration = pipeline_run.iterations.order(:number).last
      raw_deltas.each do |d|
        spec.spec_deltas.create!(
          iteration:,
          operation: d["operation"],
          section: d["section"],
          requirement: d["requirement"],
          before_content: d["before_content"],
          after_content: d["after_content"] || d["content"],
          rationale: d["rationale"]
        )
      end
    end

    def snapshot_revision!(spec, raw_deltas, change_source)
      summary = raw_deltas.map do |d|
        op = d["operation"]&.upcase
        req = d["requirement"] || "new requirement"
        section = d["section"]
        "#{op}: #{section} > #{req}"
      end

      spec.spec_revisions.create!(
        version: spec.version,
        content: spec.content,
        structured_data: spec.structured_data,
        change_source:,
        delta_summary: summary
      )
    rescue => e
      logger.warn { "[Arnold] Failed to snapshot revision: #{e.message}" }
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
  end
end

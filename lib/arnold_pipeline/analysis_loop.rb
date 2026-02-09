module ArnoldPipeline
  class AnalysisLoop
    attr_reader :analyzer, :task_breaker, :library_manager, :tier_execution_engine, :logger

    def initialize(analyzer:, task_breaker:, library_manager:, tier_execution_engine:, logger: Logger.new($stdout, level: Logger::INFO))
      @analyzer = analyzer
      @task_breaker = task_breaker
      @library_manager = library_manager
      @tier_execution_engine = tier_execution_engine
      @logger = logger
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
          pipeline_run.update!(status: :completed)
          tier_execution_engine.merge_all_results!(pipeline_run)
          logger.info { "[Arnold] Pipeline complete." }
          break
        when "iterate_tasks"
          handle_iterate_tasks!(pipeline_run, analysis)
          tier_execution_engine.execute_tiers!(pipeline_run)
        when "iterate_spec"
          handle_iterate_spec!(pipeline_run, analysis)
          break_tasks!(pipeline_run)
          tier_execution_engine.execute_tiers!(pipeline_run)
        end

        if iteration_number >= max_iterations
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
      diffs = tasks.map { |t| t.result_diff }.compact.join("\n\n")
      comments = tier_execution_engine.format_task_comments(tasks)

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
          depends_on: td["depends_on"] || []
        )
      end

      TierCalculator.call(pipeline_run.tasks.reload)
    end

    def handle_iterate_spec!(pipeline_run, analysis)
      logger.info { "[Arnold] Iterating spec based on analysis feedback..." }
      spec_changes = analysis.dig("corrective_data", "spec_changes") || ""

      spec = pipeline_run.specification
      updated_content = "#{spec.content}\n\n## Clarifications (Iteration)\n#{spec_changes}"
      spec.update!(content: updated_content, version: spec.version + 1)
    end

    def break_tasks!(pipeline_run)
      pipeline_run.update!(status: :breaking_tasks)
      logger.info { "[Arnold] Breaking specification into tasks..." }

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
  end
end

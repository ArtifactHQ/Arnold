require "arnold_pipeline/library/manager"
require "arnold_pipeline/agents/spec_generator"
require "arnold_pipeline/agents/task_breaker"
require "arnold_pipeline/agents/executor"
require "arnold_pipeline/agents/analyzer"

module ArnoldPipeline
  class Orchestrator
    attr_reader :library_manager, :spec_generator, :task_breaker, :executor, :analyzer, :logger

    def initialize(
      library_manager: nil,
      spec_generator: nil,
      task_breaker: nil,
      executor: nil,
      analyzer: nil,
      logger: nil
    )
      @logger = logger || Logger.new($stdout, level: Logger::INFO)
      @library_manager = library_manager || Library::Manager.new(library_path: ArnoldPipeline.configuration.library_path)
      @spec_generator = spec_generator || Agents::SpecGenerator.new(logger: @logger)
      @task_breaker = task_breaker || Agents::TaskBreaker.new(logger: @logger)
      @executor = executor || Agents::Executor.new(logger: @logger)
      @analyzer = analyzer || Agents::Analyzer.new(logger: @logger)
    end

    def call(nl_input:)
      pipeline_run = PipelineRun.create!(nl_input:, status: :pending)
      max_iterations = ArnoldPipeline.configuration.max_iterations

      begin
        generate_spec!(pipeline_run)
        break_tasks!(pipeline_run)
        execute_tasks!(pipeline_run)

        iteration_number = 0
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
            execute_tasks!(pipeline_run)
          when "iterate_spec"
            handle_iterate_spec!(pipeline_run, analysis)
            break_tasks!(pipeline_run)
            execute_tasks!(pipeline_run)
          end

          if iteration_number >= max_iterations
            pipeline_run.update!(status: :max_iterations_reached)
            merge_results!(pipeline_run)
            break
          end
        end
      rescue => e
        pipeline_run.update!(status: :failed, metadata: { error: e.message })
        logger.error { "Pipeline failed: #{e.message}" }
        raise
      end

      pipeline_run.reload
    end

    private

    def generate_spec!(pipeline_run)
      pipeline_run.update!(status: :generating_spec)
      logger.info { "Generating spec..." }

      persona = library_manager.find_persona(pipeline_run.nl_input)
      recipe = library_manager.find_recipe(pipeline_run.nl_input)

      result = spec_generator.call(
        nl_input: pipeline_run.nl_input,
        persona:,
        recipe:
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
    end

    def execute_tasks!(pipeline_run)
      pipeline_run.update!(status: :executing)
      logger.info { "Executing tasks..." }

      executor.call(tasks: pipeline_run.tasks.reload, pipeline_run:)
      executor.fetch_results(pipeline_run:)
    end

    def analyze!(pipeline_run, iteration_number)
      pipeline_run.update!(status: :analyzing)
      logger.info { "Analyzing iteration #{iteration_number}..." }

      persona = library_manager.find_persona("testing quality review")
      diffs = pipeline_run.tasks.reload.map { |t| t.result_diff }.compact.join("\n\n")

      result = analyzer.call(
        spec_content: pipeline_run.specification.content,
        diffs:,
        iteration_number:,
        persona:
      )

      iteration = pipeline_run.iterations.create!(
        number: iteration_number,
        decision: result["decision"],
        confidence: result["confidence"],
        reasoning: result["reasoning"],
        execution_results: diffs,
        corrective_data: result["corrective_data"]
      )

      logger.info { "Decision: #{result['decision']} (confidence: #{result['confidence']}%)" }
      if iteration.needs_human_review
        logger.warn { "Low confidence (#{result['confidence']}%) — flagged for human review" }
      end

      result
    end

    def handle_iterate_tasks!(pipeline_run, analysis)
      logger.info { "Iterating tasks based on analysis feedback..." }

      corrective_tasks = analysis.dig("corrective_data", "tasks") || []
      pipeline_run.tasks.destroy_all

      corrective_tasks.each_with_index do |td, i|
        pipeline_run.tasks.create!(
          title: td["title"],
          description: td["description"],
          priority: td["priority"] || 0,
          labels: td["labels"] || [],
          position: i,
          depends_on: td["depends_on"] || []
        )
      end
    end

    def handle_iterate_spec!(pipeline_run, analysis)
      logger.info { "Iterating spec based on analysis feedback..." }
      spec_changes = analysis.dig("corrective_data", "spec_changes") || ""

      spec = pipeline_run.specification
      updated_content = "#{spec.content}\n\n## Clarifications (Iteration)\n#{spec_changes}"
      spec.update!(content: updated_content, version: spec.version + 1)
    end

    def merge_results!(pipeline_run)
      logger.info { "Merging results..." }
      executor.merge_results(pipeline_run:)
    rescue => e
      logger.warn { "Merge failed (non-fatal): #{e.message}" }
    end
  end
end

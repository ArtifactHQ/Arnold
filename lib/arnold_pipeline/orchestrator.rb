require "arnold_pipeline/library/manager"
require "arnold_pipeline/agents/spec_generator"
require "arnold_pipeline/agents/task_breaker"
require "arnold_pipeline/agents/executor"
require "arnold_pipeline/agents/analyzer"
require "arnold_pipeline/agents/tier_gate_check"
require "arnold_pipeline/tier_calculator"
require "arnold_pipeline/tier_execution_engine"
require "arnold_pipeline/resume_inferrer"

module ArnoldPipeline
  class Orchestrator
    STAGES = %i[generate_spec break_tasks execute analyze].freeze
    STAGE_CHECKPOINTS = { generate_spec: :spec, break_tasks: :tasks, execute: :executed }.freeze

    attr_reader :library_manager, :spec_generator, :task_breaker, :executor, :analyzer, :tier_gate_check, :logger,
                :tier_execution_engine

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
      @tier_execution_engine = TierExecutionEngine.new(executor: @executor, tier_gate_check: @tier_gate_check, logger: @logger)
    end

    def call(nl_input:, stop_after: nil)
      pipeline_run = PipelineRun.create!(nl_input:, status: :pending)
      run_pipeline!(pipeline_run, from: :generate_spec, stop_after:)
    end

    def resume(pipeline_run:, stop_after: nil)
      unless pipeline_run.paused? || pipeline_run.failed?
        raise ArgumentError, "Cannot resume a #{pipeline_run.status} pipeline run"
      end

      stage = ResumeInferrer.call(pipeline_run)
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
      tier_execution_engine.execute_tiers!(pipeline_run)
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
          tier_execution_engine.merge_all_results!(pipeline_run)
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
          tier_execution_engine.merge_all_results!(pipeline_run)
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

    def pause!(pipeline_run, checkpoint)
      pipeline_run.update!(
        status: :paused,
        metadata: (pipeline_run.metadata || {}).merge("paused_at" => checkpoint.to_s)
      )
      pipeline_run.reload
    end

  end
end

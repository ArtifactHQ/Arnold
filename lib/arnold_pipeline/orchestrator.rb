require "arnold_pipeline/library/manager"
require "arnold_pipeline/agents/spec_generator"
require "arnold_pipeline/agents/task_breaker"
require "arnold_pipeline/agents/executor"
require "arnold_pipeline/agents/analyzer"
require "arnold_pipeline/agents/tier_gate_check"
require "arnold_pipeline/tier_calculator"
require "arnold_pipeline/tier_execution_engine"
require "arnold_pipeline/analysis_loop"
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
        logger.warn { "[Arnold] Pipeline paused: #{e.message}" }
        pipeline_run.reload
      rescue => e
        pipeline_run.update!(status: :failed, metadata: (pipeline_run.metadata || {}).merge("error" => e.message))
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

    def execute!(pipeline_run)
      tier_execution_engine.execute_tiers!(pipeline_run)
    end

    def analysis_loop!(pipeline_run)
      loop = AnalysisLoop.new(
        analyzer:,
        task_breaker:,
        library_manager:,
        tier_execution_engine:,
        logger:
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

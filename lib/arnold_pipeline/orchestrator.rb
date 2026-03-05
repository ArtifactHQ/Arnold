require "yaml"
require "arnold_pipeline/library/manager"
require "arnold_pipeline/agents/spec_generator"
require "arnold_pipeline/agents/task_breaker"
require "arnold_pipeline/agents/executor"
require "arnold_pipeline/agents/analyzer"
require "arnold_pipeline/agents/tier_gate_check"
require "arnold_pipeline/agents/spec_iterator"
require "arnold_pipeline/brownfield/stack_detector"
require "arnold_pipeline/brownfield/artifact_discoverer"
require "arnold_pipeline/brownfield/overlay_resolver"
require "arnold_pipeline/brownfield/health_baseline_runner"
require "arnold_pipeline/brownfield/test_name_collector"
require "arnold_pipeline/brownfield/file_manifest_builder"
require "arnold_pipeline/brownfield/route_table_parser"
require "arnold_pipeline/brownfield/git_activity_analyzer"
require "arnold_pipeline/brownfield/analysis_context"
require "arnold_pipeline/brownfield/file_content_cache"
require "arnold_pipeline/brownfield/parallel_agent_runner"
require "arnold_pipeline/agents/brownfield/infrastructure_agent"
require "arnold_pipeline/agents/brownfield/data_model_agent"
require "arnold_pipeline/agents/brownfield/business_logic_agent"
require "arnold_pipeline/agents/brownfield/controller_route_agent"
require "arnold_pipeline/agents/brownfield/view_ux_agent"
require "arnold_pipeline/agents/brownfield/synthesis_agent"
require "arnold_pipeline/agents/concern_diff_analyzer"
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

    def analyze_codebase!(repo_path:, description: nil, reference_materials: [])
      config = ArnoldPipeline.configuration
      pipeline_run = PipelineRun.create!(
        nl_input: description || "Brownfield analysis of #{File.basename(repo_path)}",
        status: :pending
      )
      @event_recorder = PipelineEventRecorder.new(pipeline_run:)

      begin
        pipeline_run.update!(status: :analyzing)
        project_name = File.basename(repo_path).tr("-_", " ").split.map(&:capitalize).join(" ")
        config.target_repo_path = repo_path

        # Step 1: Stack detection
        stack_fingerprint = @event_recorder.timed(
          event_type: :stack_detection, stage: "brownfield",
          summary: ->(r) { { language: r&.dig(:language), framework: r&.dig(:framework), confidence: r&.dig(:confidence) } }
        ) do
          Brownfield::StackDetector.call(
            repo_path:,
            overrides: config.stack_detection_overrides,
            additional_rules_path: config.additional_detection_rules_path
          )
        end

        # Step 2: Artifact discovery
        artifacts = Brownfield::ArtifactDiscoverer.call(
          repo_path:,
          stack_fingerprint:,
          additional_maps_path: config.additional_artifact_maps_path
        )

        # Step 3: Overlay resolution
        overlay = Brownfield::OverlayResolver.call(
          stack_fingerprint:,
          additional_path: config.additional_artifact_maps_path
        )

        # Step 4: Enhanced deterministic layer (no LLM)
        file_manifest = @event_recorder.timed(
          event_type: :file_manifest_built, stage: "brownfield",
          summary: ->(r) { { file_count: r&.size || 0 } }
        ) do
          Brownfield::FileManifestBuilder.call(repo_path:, stack_fingerprint:)
        end

        route_table = @event_recorder.timed(
          event_type: :route_table_parsed, stage: "brownfield",
          summary: ->(r) { { route_count: r&.size || 0 } }
        ) do
          Brownfield::RouteTableParser.call(repo_path:, stack_fingerprint:)
        end

        git_activity = @event_recorder.timed(
          event_type: :git_activity_analyzed, stage: "brownfield",
          summary: ->(r) { { files_tracked: r&.size || 0 } }
        ) do
          Brownfield::GitActivityAnalyzer.call(repo_path:)
        end

        test_name_data = @event_recorder.timed(
          event_type: :test_name_collection, stage: "brownfield",
          summary: ->(r) { { test_count: r&.dig(:test_names)&.size || 0, framework: r&.dig(:framework) } }
        ) do
          Brownfield::TestNameCollector.call(repo_path:, stack_fingerprint:)
        end

        loaded_references = load_reference_materials(reference_materials)

        # Load concerns from YAML
        concerns_path = File.expand_path("brownfield/data/concerns.yml", __dir__)
        concerns = YAML.safe_load_file(concerns_path)["concerns"]

        # Step 5: Build analysis context + file cache
        context = Brownfield::AnalysisContext.new(
          repo_path:, stack_fingerprint:, artifacts:, overlay:,
          file_manifest:, route_table:, git_activity:,
          test_names: test_name_data[:grouped_by_concern] || {},
          concerns:, reference_materials: loaded_references,
          change_request: description
        )
        file_cache = Brownfield::FileContentCache.new(repo_path:)

        # Step 6: Run 5 specialized agents in parallel
        agents = build_brownfield_agents
        runner = Brownfield::ParallelAgentRunner.new(logger:)

        agent_results = @event_recorder.timed(
          event_type: :parallel_agents_completed, stage: "brownfield",
          summary: ->(r) {
            succeeded = r&.count { |ar| ar.error.nil? } || 0
            failed = r&.count { |ar| ar.error.present? } || 0
            total_tokens = r&.sum(&:tokens_used) || 0
            { agents_succeeded: succeeded, agents_failed: failed, total_tokens: }
          }
        ) do
          runner.run(agents:, context:, file_cache:)
        end

        # Step 7: Synthesis
        synthesis_agent = build_brownfield_agent(Agents::Brownfield::SynthesisAgent, :synthesis)
        spec_result = @event_recorder.timed(
          event_type: :as_built_spec_generated, stage: "brownfield",
          summary: ->(r) { { content_length: r&.dig(:content)&.length } }
        ) do
          synthesis_agent.call(
            agent_results:,
            concerns:,
            stack_fingerprint:,
            project_name:,
            reference_materials: loaded_references
          )
        end

        # Step 8: Health baseline
        infra_result = agent_results.find { |r| r.agent_name == "infrastructure" }
        conventions = infra_result&.output&.dig("conventions") || {}

        health_result = @event_recorder.timed(
          event_type: :health_baseline, stage: "brownfield",
          summary: ->(r) { { all_passed: r&.dig(:all_passed), summary: r&.dig(:summary) } }
        ) do
          Brownfield::HealthBaselineRunner.call(
            repo_path:,
            conventions:,
            artifact_map: artifacts,
            timeout: config.health_baseline_timeout
          )
        end

        # Build backward-compatible recipe_alignment from infrastructure concerns
        recipe_alignment = build_recipe_alignment(agent_results)

        # Persist as-built specification
        pipeline_run.create_specification!(
          content: spec_result[:content],
          structured_data: spec_result[:structured_data],
          version: 1,
          spec_type: "as_built"
        )

        # Persist codebase profile
        total_tokens = agent_results.sum(&:tokens_used) + (spec_result[:tokens_used] || 0)
        profile = pipeline_run.create_codebase_profile!(
          project_name:,
          stack_fingerprint:,
          recipe_alignment:,
          conventions:,
          documentation_fidelity: nil,
          health_baseline: health_result,
          change_surface: nil,
          scan_data: { artifacts_found: artifacts.count { |a| a[:path] } },
          feature_inventories: agent_results.filter_map { |r|
            next unless r.output
            { "agent" => r.agent_name, "data" => r.output }
          },
          confidence: stack_fingerprint[:confidence],
          token_budget_used: total_tokens,
          analyzed_at: Time.current
        )

        pipeline_run.update!(status: :completed)
        @event_recorder.record(
          event_type: :pipeline_completed, stage: "lifecycle",
          summary: { status: "completed", type: "brownfield_analysis" }
        )

        profile
      rescue => e
        @event_recorder&.record(
          event_type: :pipeline_failed, stage: "lifecycle",
          summary: { error_class: e.class.name, error_message: e.message }
        )
        pipeline_run.update!(status: :failed, metadata: (pipeline_run.metadata || {}).merge(
          "error" => e.message, "error_class" => e.class.name
        ))
        raise
      end
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

        finalize!(pipeline_run) if ArnoldPipeline.configuration.finalization_enabled
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

<<<<<<< HEAD
    def finalize!(pipeline_run)
      logger.info { "[Arnold] Running post-pipeline finalization..." }
      config = ArnoldPipeline.configuration
      repo_path = config.target_repo_path
      return unless repo_path && Dir.exist?(repo_path)

      cleanup_stale_worktrees!(repo_path)
      run_recipe_finalization!(pipeline_run, repo_path)
      run_finalization_hooks!(repo_path, config)
      run_final_verification!(pipeline_run, repo_path, config)

      @event_recorder&.record(
        event_type: :pipeline_finalized, stage: "lifecycle",
        summary: { status: "finalized" }
      )
    rescue => e
      logger.warn { "[Arnold] Finalization failed (non-fatal): #{e.message}" }
    end

    def cleanup_stale_worktrees!(repo_path)
      worktrees_dir = File.join(repo_path, ".worktrees")
      return unless Dir.exist?(worktrees_dir)

      system("git", "-C", repo_path, "worktree", "prune")
      FileUtils.rm_rf(worktrees_dir)
      logger.info { "[Arnold] Cleaned up stale worktrees" }
    end

    def run_recipe_finalization!(pipeline_run, repo_path)
      recipe = resolve_primary_recipe(pipeline_run)
      return unless recipe

      commands = recipe.finalization.fetch("commands", [])
      return if commands.empty?

      hooks = commands.each_with_index.map do |cmd, i|
        PostMergeHook.new(
          name: "recipe_#{recipe.type}_#{i}",
          trigger_paths: [],
          command: cmd
        )
      end

      results = PostMergeHookRunner.call(
        repo_path: repo_path, changed_files: [], hooks: hooks,
        logger: logger, force_all: true
      )

      triggered = results.select { |r| r[:triggered] }
      passed = triggered.count { |r| r[:success] }
      logger.info { "[Arnold] Recipe finalization (#{recipe.type}): #{passed}/#{triggered.size} passed" }

      @event_recorder&.record(
        event_type: :finalization_setup, stage: "lifecycle",
        summary: {
          recipe_type: recipe.type,
          commands_run: triggered.size,
          commands_passed: passed,
          details: triggered.map { |r| { name: r[:name], success: r[:success] } }
        }
      )
    end

    def resolve_primary_recipe(pipeline_run)
      recipe_type = pipeline_run.specification&.structured_data&.dig("recipe_type")
      return nil unless recipe_type

      library_manager.all_recipes.find { |r| r.type == recipe_type }
    end

    def run_finalization_hooks!(repo_path, config)
      hooks = build_finalization_hooks(config)
      return if hooks.empty?

      results = PostMergeHookRunner.call(
        repo_path: repo_path, changed_files: [], hooks: hooks,
        logger: logger, force_all: true
      )

      triggered = results.select { |r| r[:triggered] }
      passed = triggered.count { |r| r[:success] }
      logger.info { "[Arnold] Finalization hooks: #{passed}/#{triggered.size} passed" }
    end

    def run_final_verification!(pipeline_run, repo_path, config)
      checks = build_finalization_checks(config, pipeline_run)
      return if checks.empty?

      results = VerificationRunner.call(repo_path: repo_path, checks: checks, logger: logger)

      if results[:all_passed]
        logger.info { "[Arnold] Final verification: all checks passed" }
      else
        failed = results[:checks].select { |c| !c[:success] }.map { |c| c[:name] }
        logger.warn { "[Arnold] Final verification: #{failed.join(', ')} failed" }
      end

      @event_recorder&.record(
        event_type: :finalization_verification, stage: "lifecycle",
        summary: { all_passed: results[:all_passed], summary: results[:summary] }
      )
    end

    def build_finalization_hooks(config)
      return [] unless config.post_merge_hooks.present?

      config.post_merge_hooks.map do |h|
        PostMergeHook.new(
          name: h["name"] || h[:name],
          trigger_paths: h["trigger_paths"] || h[:trigger_paths],
          command: h["command"] || h[:command],
          commit_paths: h["commit_paths"] || h[:commit_paths] || [],
          commit_message: h["commit_message"] || h[:commit_message]
        )
      end
    end

    def build_finalization_checks(config, pipeline_run = nil)
      recipe_checks = resolve_recipe_finalization_checks(pipeline_run)
      config_checks = resolve_config_finalization_checks(config)

      # Merge: recipe first, config overlays by name
      merged = {}
      recipe_checks.each { |c| merged[c.name] = c }
      config_checks.each { |c| merged[c.name] = c }

      # Filter: only checks eligible for finalization
      merged.values.select(&:eligible_for_finalization?)
    end

    def resolve_recipe_finalization_checks(pipeline_run)
      recipe = resolve_primary_recipe(pipeline_run)
      return [] unless recipe

      raw_checks = recipe.finalization.fetch("checks", [])
      raw_checks.map do |c|
        VerificationCheck.new(
          name: c["name"] || c[:name],
          command: c["command"] || c[:command],
          type: c["type"] || c[:type] || :custom,
          required: c["required"] || c[:required] || false
        )
      end
    end

    def resolve_config_finalization_checks(config)
      return [] unless config.verification_checks.present?

      config.verification_checks.map do |c|
        VerificationCheck.new(
          name: c["name"] || c[:name],
          command: c["command"] || c[:command],
          type: c["type"] || c[:type] || :custom,
          required: c["required"] || c[:required] || false
        )
      end
    end

    BROWNFIELD_AGENT_CLASSES = {
      infrastructure: Agents::Brownfield::InfrastructureAgent,
      data_model: Agents::Brownfield::DataModelAgent,
      business_logic: Agents::Brownfield::BusinessLogicAgent,
      controller_route: Agents::Brownfield::ControllerRouteAgent,
      view_ux: Agents::Brownfield::ViewUxAgent
    }.freeze

    def build_brownfield_agents
      BROWNFIELD_AGENT_CLASSES.each_with_object({}) do |(agent_key, agent_class), agents|
        agents[agent_key] = build_brownfield_agent(agent_class, agent_key)
      end
    end

    def build_brownfield_agent(agent_class, agent_key)
      model = ArnoldPipeline.configuration.brownfield_model_for(agent_key)
      llm = Providers::Llm.build(model: model)
      agent_class.new(llm:, logger:)
    end

    def build_recipe_alignment(agent_results)
      infra = agent_results.find { |r| r.agent_name == "infrastructure" }
      concerns_array = infra&.output&.dig("concerns") || []

      concerns_hash = concerns_array.each_with_object({}) do |entry, hash|
        hash[entry["concern_id"]] = entry.except("concern_id")
      end

      { "concerns" => concerns_hash }
    end

    def load_reference_materials(paths)
      return [] if paths.nil? || paths.empty?

      paths.filter_map do |path|
        next unless File.exist?(path)
        content = File.read(path, encoding: "utf-8")
        content = content[0, 10_000] if content.length > 10_000
        next unless content

        { path: path, content: content }
      rescue => e
        logger.warn { "[Arnold] Failed to read reference material #{path}: #{e.message}" }
        nil
      end
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

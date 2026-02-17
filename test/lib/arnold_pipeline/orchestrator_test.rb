require "test_helper"
require "arnold_pipeline/orchestrator"

module ArnoldPipeline
  class OrchestratorTest < ActiveSupport::TestCase
    setup do
      @library_manager = Library::Manager.new
      @spec_generator = stub("spec_generator")
      @task_breaker = stub("task_breaker")
      @executor = stub("executor")
      @executor.stubs(:provider).returns(stub(recoverable_errors: [], async?: true))
      @analyzer = stub("analyzer")

      @tier_gate_check = stub("tier_gate_check")
      @tier_gate_check.stubs(:call).returns({
        "pass" => true,
        "issues" => [],
        "context_summary" => "Tier complete.",
        "corrective_tasks" => []
      })

      @spec_iterator = stub("spec_iterator")

      @orchestrator = Orchestrator.new(
        library_manager: @library_manager,
        spec_generator: @spec_generator,
        task_breaker: @task_breaker,
        executor: @executor,
        analyzer: @analyzer,
        tier_gate_check: @tier_gate_check,
        spec_iterator: @spec_iterator,
        logger: Logger.new(File::NULL)
      )

      ArnoldPipeline.configure do |c|
        c.max_iterations = 3
        c.llm_api_key = "test"
        c.github_token = "test"
        c.github_repo = "owner/repo"
      end
    end

    teardown do
      ArnoldPipeline.reset_configuration!
    end

    test "completes pipeline on first iteration with done decision" do
      stub_spec_generation!
      stub_task_breakdown!(times: 1)
      @executor.stubs(:call).returns([])
      @executor.stubs(:await_results).returns(nil)
      @executor.stubs(:merge_results).returns([])

      @analyzer.expects(:call).once.returns(analysis_result("done", 95))

      result = @orchestrator.call(nl_input: "Build a todo app")

      assert_equal "completed", result.status
      assert_equal 1, result.iterations.count
      assert_equal "done", result.iterations.first.decision
    end

    test "iterates tasks when iterate_tasks decision" do
      stub_spec_generation!
      stub_task_breakdown!(times: 1)
      @executor.stubs(:call).returns([])
      @executor.stubs(:await_results).returns(nil)
      @executor.stubs(:merge_results).returns([])

      corrective = {
        "tasks" => [
          { "title" => "Fix error handling", "description" => "Add try/catch", "position" => 0 }
        ]
      }

      call_count = sequence("analysis_calls")
      @analyzer.expects(:call).in_sequence(call_count)
        .returns(analysis_result("iterate_tasks", 80, corrective))
      @analyzer.expects(:call).in_sequence(call_count)
        .returns(analysis_result("done", 92))

      result = @orchestrator.call(nl_input: "Build a todo app")

      assert_equal "completed", result.status
      assert_equal 2, result.iterations.count
    end

    test "iterates spec when iterate_spec decision" do
      stub_spec_generation!
      @task_breaker.stubs(:call).returns(sample_tasks)
      @executor.stubs(:call).returns([])
      @executor.stubs(:await_results).returns(nil)
      @executor.stubs(:merge_results).returns([])

      call_count = sequence("analysis_calls")
      @analyzer.expects(:call).in_sequence(call_count)
        .returns(analysis_result("iterate_spec", 60, { "spec_changes" => "Clarify auth flow" }))
      @analyzer.expects(:call).in_sequence(call_count)
        .returns(analysis_result("done", 90))

      result = @orchestrator.call(nl_input: "Build a todo app")

      assert_equal "completed", result.status
      assert_equal 2, result.iterations.count
      assert result.iterations.order(:number).first.needs_human_review, "Low confidence should flag for review"
    end

    test "stops after max iterations" do
      stub_spec_generation!
      @task_breaker.stubs(:call).returns(sample_tasks)
      @executor.stubs(:call).returns([])
      @executor.stubs(:await_results).returns(nil)
      @executor.stubs(:merge_results).returns([])

      corrective = {
        "tasks" => [{ "title" => "Fix", "description" => "Fix it", "position" => 0 }]
      }

      @analyzer.stubs(:call).returns(analysis_result("iterate_tasks", 75, corrective))

      result = @orchestrator.call(nl_input: "Build a todo app")

      assert_equal "max_iterations_reached", result.status
      assert_equal 3, result.iterations.count
    end

    test "marks as failed on error" do
      @spec_generator.expects(:call).raises(StandardError, "LLM is down")

      assert_raises(StandardError) do
        @orchestrator.call(nl_input: "Build a todo app")
      end

      run_record = PipelineRun.last
      assert_equal "failed", run_record.status
      assert_equal "LLM is down", run_record.metadata["error"]
      assert_equal "StandardError", run_record.metadata["error_class"]
      assert_equal "generate_spec", run_record.metadata["failed_stage"]
    end

    test "pipeline_failed event includes provider and stage context" do
      @spec_generator.expects(:call).raises(StandardError, "Net::ReadTimeout")

      assert_raises(StandardError) do
        @orchestrator.call(nl_input: "Build a todo app")
      end

      event = PipelineRun.last.pipeline_events.find_by(event_type: :pipeline_failed)
      assert_not_nil event
      assert_equal "generate_spec", event.summary["failed_stage"]
      assert_equal ArnoldPipeline.configuration.llm_provider.to_s, event.summary["llm_provider"]
      assert_equal ArnoldPipeline.configuration.llm_model, event.summary["llm_model"]
      assert_equal ArnoldPipeline.configuration.execution_provider.to_s, event.summary["execution_provider"]
      assert event.summary["backtrace"].is_a?(Array)
    end

    test "pipeline_completed event includes aggregate health summary" do
      stub_spec_generation!
      stub_task_breakdown!(times: 1)
      @executor.stubs(:call).returns([])
      @executor.stubs(:await_results).returns(nil)
      @executor.stubs(:merge_results).returns([])
      @analyzer.expects(:call).once.returns(analysis_result("done", 95))

      result = @orchestrator.call(nl_input: "Build a todo app")

      event = result.pipeline_events.find_by(event_type: :pipeline_completed)
      assert_not_nil event
      summary = event.summary
      assert_includes summary.keys, "total_iterations"
      assert_includes summary.keys, "total_tasks"
      assert_includes summary.keys, "total_duration_ms"
      assert_includes summary.keys, "tasks_succeeded"
      assert_includes summary.keys, "tasks_failed"
      assert_includes summary.keys, "tasks_superseded"
      assert_includes summary.keys, "tier_count"
      assert_includes summary.keys, "final_confidence"
      assert_equal 95, summary["final_confidence"]
      assert summary["total_duration_ms"].is_a?(Numeric), "total_duration_ms should be numeric"
      assert_equal 5, summary["total_tasks"]
      assert_equal 1, summary["total_iterations"]
    end

    test "pipeline_failed event includes task counts and duration" do
      stub_spec_generation!
      stub_task_breakdown!(times: 1)
      @executor.stubs(:call).raises(StandardError, "GitHub API timeout")

      assert_raises(StandardError) do
        @orchestrator.call(nl_input: "Build a todo app")
      end

      event = PipelineRun.last.pipeline_events.find_by(event_type: :pipeline_failed)
      assert_not_nil event
      summary = event.summary
      assert_includes summary.keys, "total_tasks"
      assert_includes summary.keys, "tasks_succeeded"
      assert_includes summary.keys, "tasks_failed"
      assert_includes summary.keys, "total_duration_ms"
      assert summary["total_duration_ms"].is_a?(Numeric), "total_duration_ms should be numeric"
      assert_equal 5, summary["total_tasks"]
    end

    test "call validates configuration before running" do
      ArnoldPipeline.configure { |c| c.llm_provider = :invalid }
      assert_raises(ArnoldPipeline::ConfigurationError) do
        @orchestrator.call(nl_input: "test")
      end
    ensure
      ArnoldPipeline.reset_configuration!
    end

    test "resume validates configuration before running" do
      run = PipelineRun.create!(nl_input: "test", status: :paused)
      ArnoldPipeline.configure { |c| c.llm_provider = :invalid }
      assert_raises(ArnoldPipeline::ConfigurationError) do
        @orchestrator.resume(pipeline_run: run)
      end
    ensure
      ArnoldPipeline.reset_configuration!
    end

    test "analyze passes task comments to analyzer" do
      stub_spec_generation!
      stub_task_breakdown!(times: 1)
      @executor.stubs(:call).returns([])
      @executor.stubs(:await_results).returns(nil)
      @executor.stubs(:merge_results).returns([])

      # After task creation, add comments to the first task
      @executor.stubs(:call).with { |kwargs|
        pipeline_run = kwargs[:pipeline_run]
        task = pipeline_run.tasks.first
        task.update!(result_comments: [{ "source" => "issue", "author" => "copilot", "body" => "Missing Gemfile" }])
        true
      }.returns([])

      @analyzer.expects(:call).with { |kwargs|
        kwargs[:comments].include?("Missing Gemfile") &&
          kwargs[:comments].include?("copilot")
      }.returns(analysis_result("done", 95))

      result = @orchestrator.call(nl_input: "Build a todo app")

      assert_equal "completed", result.status
    end

    test "flags low confidence iterations for human review" do
      stub_spec_generation!
      stub_task_breakdown!(times: 1)
      @executor.stubs(:call).returns([])
      @executor.stubs(:await_results).returns(nil)
      @executor.stubs(:merge_results).returns([])

      @analyzer.expects(:call).once.returns(analysis_result("done", 50))

      result = @orchestrator.call(nl_input: "Build a todo app")

      assert result.iterations.first.needs_human_review
    end

    test "tier_task_resolved? returns false when workflow_active is true" do
      pipeline_run = PipelineRun.create!(nl_input: "Build an app")
      task = pipeline_run.tasks.create!(
        title: "Setup DB", position: 0, external_id: "42",
        result_diff: '[{"filename":"schema.rb"}]',
        workflow_active: true
      )

      refute @orchestrator.tier_execution_engine.tier_task_resolved?(task),
        "tier_task_resolved? should return false when workflow_active"
    end

    test "tier_task_resolved? returns true when workflow_active is false with diffs" do
      pipeline_run = PipelineRun.create!(nl_input: "Build an app")
      task = pipeline_run.tasks.create!(
        title: "Setup DB", position: 0, external_id: "42",
        result_diff: '[{"filename":"schema.rb"}]',
        workflow_active: false
      )

      assert @orchestrator.tier_execution_engine.tier_task_resolved?(task),
        "tier_task_resolved? should return true when workflow inactive and diffs present"
    end

    test "infer_resume_stage returns execute when tasks have workflow_active" do
      pipeline_run = PipelineRun.create!(nl_input: "Build an app", status: :paused)
      pipeline_run.create_specification!(content: "Spec content", version: 1)
      task = pipeline_run.tasks.create!(
        title: "Setup DB", position: 0, tier: 0, external_id: "42",
        result_diff: '[{"filename":"schema.rb"}]',
        workflow_active: true
      )

      stage = ResumeInferrer.call(pipeline_run)
      assert_equal :execute, stage, "Should infer execute stage when tasks have active workflows"
    end

    test "break_tasks passes recipe context from structured_data" do
      stub_spec_generation!(recipe_type: "web_app", supporting_recipe_types: ["api_service"])

      @task_breaker.expects(:call).with { |kwargs|
        kwargs[:spec_content].is_a?(String) &&
          kwargs[:recipe]&.type == "web_app" &&
          kwargs[:supporting_recipes].any? { |r| r.type == "api_service" }
      }.returns(sample_tasks)

      @orchestrator.call(nl_input: "Build a todo app", stop_after: :tasks)
    end

    test "execute! records baseline_commit_sha in metadata" do
      ArnoldPipeline.configure do |c|
        c.llm_api_key = "test"
        c.github_token = "test"
        c.github_repo = "owner/repo"
        c.claude_code_repo_path = File.expand_path("../../..", __dir__)
      end

      stub_spec_generation!
      stub_task_breakdown!(times: 1)
      @executor.stubs(:call).returns([])
      @executor.stubs(:await_results).returns(nil)
      @executor.stubs(:merge_results).returns([])
      @analyzer.expects(:call).once.returns(analysis_result("done", 95))

      result = @orchestrator.call(nl_input: "Build a todo app")

      result.reload
      assert result.metadata["baseline_commit_sha"].present?,
        "Expected baseline_commit_sha to be recorded"
      assert_match(/\A[0-9a-f]{40}\z/, result.metadata["baseline_commit_sha"],
        "Expected a valid 40-char git SHA")
    end

    test "execute! does not overwrite baseline_commit_sha on resume" do
      ArnoldPipeline.configure do |c|
        c.llm_api_key = "test"
        c.github_token = "test"
        c.github_repo = "owner/repo"
        c.claude_code_repo_path = File.expand_path("../../..", __dir__)
      end

      existing_sha = "a" * 40
      pipeline_run = PipelineRun.create!(
        nl_input: "Build a todo app",
        status: :paused,
        metadata: { "paused_at" => "executed", "baseline_commit_sha" => existing_sha }
      )
      pipeline_run.create_specification!(content: "Spec", version: 1)
      pipeline_run.tasks.create!(
        title: "Setup DB", position: 0, tier: 0,
        external_id: "42", result_diff: '[{"filename":"schema.rb"}]'
      )

      @executor.stubs(:call).returns([])
      @executor.stubs(:await_results).returns(nil)
      @executor.stubs(:merge_results).returns([])
      @analyzer.expects(:call).once.returns(analysis_result("done", 95))

      @orchestrator.resume(pipeline_run:)

      pipeline_run.reload
      assert_equal existing_sha, pipeline_run.metadata["baseline_commit_sha"],
        "Should not overwrite existing baseline SHA on resume"
    end

    test "execute! handles missing repo_path gracefully for baseline SHA" do
      ArnoldPipeline.configure do |c|
        c.llm_api_key = "test"
        c.github_token = "test"
        c.github_repo = "owner/repo"
        c.claude_code_repo_path = nil
      end

      stub_spec_generation!
      stub_task_breakdown!(times: 1)
      @executor.stubs(:call).returns([])
      @executor.stubs(:await_results).returns(nil)
      @executor.stubs(:merge_results).returns([])
      @analyzer.expects(:call).once.returns(analysis_result("done", 95))

      result = @orchestrator.call(nl_input: "Build a todo app")

      result.reload
      assert_nil result.metadata["baseline_commit_sha"],
        "Should not record SHA when no repo_path configured"
    end

    test "break_tasks works without recipe in structured_data" do
      stub_spec_generation!

      @task_breaker.expects(:call).with { |kwargs|
        kwargs[:recipe].nil? && kwargs[:supporting_recipes] == []
      }.returns(sample_tasks)

      @orchestrator.call(nl_input: "Build a todo app", stop_after: :tasks)
    end

    # --- iterate_spec! tests ---

    test "iterate_spec! calls agent and applies deltas on paused run" do
      run = create_paused_run_with_spec_and_tasks

      spec_iterator = stub("spec_iterator")
      delta_merger = stub("delta_merger")
      orchestrator = build_iterate_orchestrator(spec_iterator:)

      spec_iterator.expects(:call).with(
        spec_content: "# Original Spec",
        change_request: "Add dark mode"
      ).returns(sample_agent_result)

      # DeltaMerger is created internally, so stub via the orchestrator's delta_merger
      orchestrator.delta_merger.expects(:apply!).with(
        spec: run.specification,
        raw_deltas: sample_deltas,
        change_source: "user_iterate",
        pipeline_run: run
      ).returns({ merge_strategy: "append", delta_count: 1, new_version: 2 })

      result = orchestrator.iterate_spec!(pipeline_run: run, change_request: "Add dark mode")

      assert_equal run, result[:pipeline_run]
      assert_equal 1, result[:deltas][:delta_count]
    end

    test "iterate_spec! marks existing tasks as superseded" do
      run = create_paused_run_with_spec_and_tasks

      spec_iterator = stub("spec_iterator")
      spec_iterator.stubs(:call).returns(sample_agent_result)

      orchestrator = build_iterate_orchestrator(spec_iterator:)
      orchestrator.delta_merger.stubs(:apply!).returns({ merge_strategy: "append", delta_count: 1, new_version: 2 })

      orchestrator.iterate_spec!(pipeline_run: run, change_request: "Add dark mode")

      run.tasks.reload.each do |task|
        assert_equal "superseded", task.status, "Task '#{task.title}' should be superseded"
      end
    end

    test "iterate_spec! creates spec_delta_merged event" do
      run = create_paused_run_with_spec_and_tasks

      spec_iterator = stub("spec_iterator")
      spec_iterator.stubs(:call).returns(sample_agent_result)

      orchestrator = build_iterate_orchestrator(spec_iterator:)
      orchestrator.delta_merger.stubs(:apply!).returns({ merge_strategy: "append", delta_count: 1, new_version: 2 })

      orchestrator.iterate_spec!(pipeline_run: run, change_request: "Add dark mode")

      event = run.pipeline_events.find_by(event_type: :spec_delta_merged)
      assert_not_nil event, "Expected spec_delta_merged event to be recorded"
    end

    test "iterate_spec! raises when no deltas generated" do
      run = create_paused_run_with_spec_and_tasks

      spec_iterator = stub("spec_iterator")
      spec_iterator.stubs(:call).returns({ "summary" => "No changes", "deltas" => [] })

      orchestrator = build_iterate_orchestrator(spec_iterator:)

      error = assert_raises(ArgumentError) do
        orchestrator.iterate_spec!(pipeline_run: run, change_request: "Nothing")
      end
      assert_match(/No deltas generated/, error.message)
    end

    test "iterate_spec! raises for executing pipeline run" do
      run = PipelineRun.create!(nl_input: "test", status: :executing)

      orchestrator = build_iterate_orchestrator

      error = assert_raises(ArgumentError) do
        orchestrator.iterate_spec!(pipeline_run: run, change_request: "Change something")
      end
      assert_match(/Cannot iterate a executing pipeline run/, error.message)
    end

    test "iterate_spec! raises for pending pipeline run" do
      run = PipelineRun.create!(nl_input: "test", status: :pending)

      orchestrator = build_iterate_orchestrator

      error = assert_raises(ArgumentError) do
        orchestrator.iterate_spec!(pipeline_run: run, change_request: "Change something")
      end
      assert_match(/Cannot iterate a pending pipeline run/, error.message)
    end

    test "iterate_spec! allows failed pipeline run" do
      run = PipelineRun.create!(nl_input: "test", status: :failed)
      run.create_specification!(content: "# Spec", version: 1)

      spec_iterator = stub("spec_iterator")
      spec_iterator.stubs(:call).returns(sample_agent_result)

      orchestrator = build_iterate_orchestrator(spec_iterator:)
      orchestrator.delta_merger.stubs(:apply!).returns({ merge_strategy: "append", delta_count: 1, new_version: 2 })

      result = orchestrator.iterate_spec!(pipeline_run: run, change_request: "Fix it")
      assert_equal run.id, result[:pipeline_run].id
    end

    test "iterate_spec! allows completed pipeline run" do
      run = PipelineRun.create!(nl_input: "test", status: :completed)
      run.create_specification!(content: "# Spec", version: 1)

      spec_iterator = stub("spec_iterator")
      spec_iterator.stubs(:call).returns(sample_agent_result)

      orchestrator = build_iterate_orchestrator(spec_iterator:)
      orchestrator.delta_merger.stubs(:apply!).returns({ merge_strategy: "append", delta_count: 1, new_version: 2 })

      result = orchestrator.iterate_spec!(pipeline_run: run, change_request: "Improve it")
      assert_equal run.id, result[:pipeline_run].id
    end

    test "iterate_spec! raises when pipeline run has no specification" do
      run = PipelineRun.create!(nl_input: "test", status: :paused)

      orchestrator = build_iterate_orchestrator

      error = assert_raises(ArgumentError) do
        orchestrator.iterate_spec!(pipeline_run: run, change_request: "Change something")
      end
      assert_match(/has no specification/, error.message)
    end

    # --- iterate_spec_dry_run! tests ---

    test "iterate_spec_dry_run! returns deltas without modifying DB" do
      run = create_paused_run_with_spec_and_tasks
      original_task_count = run.tasks.where.not(status: :superseded).count

      spec_iterator = stub("spec_iterator")
      spec_iterator.expects(:call).returns(sample_agent_result)

      orchestrator = build_iterate_orchestrator(spec_iterator:)

      result = orchestrator.iterate_spec_dry_run!(pipeline_run: run, change_request: "Add dark mode")

      assert_equal sample_deltas, result[:deltas]
      assert_equal "Added dark mode support", result[:summary]
      assert_equal 1, result[:current_version]

      # Verify nothing changed in DB
      assert_equal original_task_count, run.tasks.reload.where.not(status: :superseded).count
      assert_equal 1, run.specification.reload.version
    end

    test "iterate_spec_dry_run! raises for invalid state" do
      run = PipelineRun.create!(nl_input: "test", status: :analyzing)

      orchestrator = build_iterate_orchestrator

      error = assert_raises(ArgumentError) do
        orchestrator.iterate_spec_dry_run!(pipeline_run: run, change_request: "Change")
      end
      assert_match(/Cannot iterate/, error.message)
    end

    test "iterate_spec_dry_run! raises when no deltas generated" do
      run = PipelineRun.create!(nl_input: "test", status: :paused)
      run.create_specification!(content: "# Spec", version: 1)

      spec_iterator = stub("spec_iterator")
      spec_iterator.stubs(:call).returns({ "summary" => "No changes", "deltas" => [] })

      orchestrator = build_iterate_orchestrator(spec_iterator:)

      error = assert_raises(ArgumentError) do
        orchestrator.iterate_spec_dry_run!(pipeline_run: run, change_request: "Nothing")
      end
      assert_match(/No deltas generated/, error.message)
    end

    # --- fork! tests ---

    test "fork! creates new PipelineRun with forked_from_run_id in metadata" do
      run = PipelineRun.create!(nl_input: "Build a todo app", status: :completed)
      run.create_specification!(content: "# Original Spec", structured_data: { "features" => ["crud"] }, version: 2)

      spec_iterator = stub("spec_iterator")
      spec_iterator.stubs(:call).returns(sample_agent_result)

      orchestrator = build_iterate_orchestrator(spec_iterator:)
      orchestrator.delta_merger.stubs(:apply!).returns({ merge_strategy: "append", delta_count: 1, new_version: 3 })

      result = orchestrator.fork!(pipeline_run: run, change_request: "Add dark mode")

      new_run = result[:pipeline_run]
      assert_not_equal run.id, new_run.id
      assert_equal run.id, new_run.metadata["forked_from_run_id"]
      assert_equal "Add dark mode", new_run.metadata["fork_change_request"]
      assert_equal run.nl_input, new_run.nl_input
    end

    test "fork! copies spec content to new run" do
      run = PipelineRun.create!(nl_input: "Build a todo app", status: :completed)
      run.create_specification!(content: "# Original Spec", structured_data: { "features" => ["crud"] }, version: 2)

      spec_iterator = stub("spec_iterator")
      spec_iterator.stubs(:call).returns(sample_agent_result)

      orchestrator = build_iterate_orchestrator(spec_iterator:)
      orchestrator.delta_merger.stubs(:apply!).returns({ merge_strategy: "append", delta_count: 1, new_version: 3 })

      result = orchestrator.fork!(pipeline_run: run, change_request: "Add dark mode")

      new_spec = result[:pipeline_run].specification
      assert_not_nil new_spec
      assert_equal run.specification.structured_data, new_spec.structured_data
    end

    test "fork! applies deltas via delta_merger with user_iterate change source" do
      run = PipelineRun.create!(nl_input: "Build a todo app", status: :completed)
      run.create_specification!(content: "# Original Spec", version: 1)

      spec_iterator = stub("spec_iterator")
      spec_iterator.stubs(:call).returns(sample_agent_result)

      orchestrator = build_iterate_orchestrator(spec_iterator:)
      orchestrator.delta_merger.expects(:apply!).with { |kwargs|
        kwargs[:change_source] == "user_iterate" &&
          kwargs[:raw_deltas] == sample_deltas &&
          kwargs[:spec].pipeline_run_id != run.id
      }.returns({ merge_strategy: "append", delta_count: 1, new_version: 2 })

      orchestrator.fork!(pipeline_run: run, change_request: "Add dark mode")
    end

    test "fork! sets new run to paused status at spec checkpoint" do
      run = PipelineRun.create!(nl_input: "Build a todo app", status: :completed)
      run.create_specification!(content: "# Original Spec", version: 1)

      spec_iterator = stub("spec_iterator")
      spec_iterator.stubs(:call).returns(sample_agent_result)

      orchestrator = build_iterate_orchestrator(spec_iterator:)
      orchestrator.delta_merger.stubs(:apply!).returns({ merge_strategy: "append", delta_count: 1, new_version: 2 })

      result = orchestrator.fork!(pipeline_run: run, change_request: "Add dark mode")

      new_run = result[:pipeline_run]
      assert new_run.paused?, "New run should be paused"
      assert_equal "spec", new_run.metadata["paused_at"]
    end

    test "fork! returns deltas array" do
      run = PipelineRun.create!(nl_input: "Build a todo app", status: :completed)
      run.create_specification!(content: "# Original Spec", version: 1)

      spec_iterator = stub("spec_iterator")
      spec_iterator.stubs(:call).returns(sample_agent_result)

      orchestrator = build_iterate_orchestrator(spec_iterator:)
      orchestrator.delta_merger.stubs(:apply!).returns({ merge_strategy: "append", delta_count: 1, new_version: 2 })

      result = orchestrator.fork!(pipeline_run: run, change_request: "Add dark mode")

      assert_equal sample_deltas, result[:deltas]
    end

    test "fork! raises for paused pipeline run" do
      run = PipelineRun.create!(nl_input: "test", status: :paused)

      orchestrator = build_iterate_orchestrator

      error = assert_raises(ArgumentError) do
        orchestrator.fork!(pipeline_run: run, change_request: "Change")
      end
      assert_match(/Can only fork completed or max_iterations_reached/, error.message)
    end

    test "fork! raises for failed pipeline run" do
      run = PipelineRun.create!(nl_input: "test", status: :failed)

      orchestrator = build_iterate_orchestrator

      error = assert_raises(ArgumentError) do
        orchestrator.fork!(pipeline_run: run, change_request: "Change")
      end
      assert_match(/Can only fork completed or max_iterations_reached/, error.message)
    end

    test "fork! raises for executing pipeline run" do
      run = PipelineRun.create!(nl_input: "test", status: :executing)

      orchestrator = build_iterate_orchestrator

      error = assert_raises(ArgumentError) do
        orchestrator.fork!(pipeline_run: run, change_request: "Change")
      end
      assert_match(/Can only fork completed or max_iterations_reached/, error.message)
    end

    test "fork! allows max_iterations_reached pipeline run" do
      run = PipelineRun.create!(nl_input: "Build a todo app", status: :max_iterations_reached)
      run.create_specification!(content: "# Spec", version: 3)

      spec_iterator = stub("spec_iterator")
      spec_iterator.stubs(:call).returns(sample_agent_result)

      orchestrator = build_iterate_orchestrator(spec_iterator:)
      orchestrator.delta_merger.stubs(:apply!).returns({ merge_strategy: "append", delta_count: 1, new_version: 4 })

      result = orchestrator.fork!(pipeline_run: run, change_request: "Add dark mode")

      assert result[:pipeline_run].paused?
      assert_equal run.id, result[:pipeline_run].metadata["forked_from_run_id"]
    end

    test "fork! raises when pipeline run has no specification" do
      run = PipelineRun.create!(nl_input: "test", status: :completed)

      orchestrator = build_iterate_orchestrator

      error = assert_raises(ArgumentError) do
        orchestrator.fork!(pipeline_run: run, change_request: "Change")
      end
      assert_match(/has no specification/, error.message)
    end

    test "fork! raises when no deltas generated" do
      run = PipelineRun.create!(nl_input: "test", status: :completed)
      run.create_specification!(content: "# Spec", version: 1)

      spec_iterator = stub("spec_iterator")
      spec_iterator.stubs(:call).returns({ "summary" => "No changes", "deltas" => [] })

      orchestrator = build_iterate_orchestrator(spec_iterator:)

      error = assert_raises(ArgumentError) do
        orchestrator.fork!(pipeline_run: run, change_request: "Nothing")
      end
      assert_match(/No deltas generated/, error.message)
    end

    private

    def stub_spec_generation!(recipe_type: nil, supporting_recipe_types: nil)
      structured_data = { "features" => ["create", "read", "update", "delete"] }
      structured_data["recipe_type"] = recipe_type if recipe_type
      structured_data["supporting_recipe_types"] = supporting_recipe_types if supporting_recipe_types

      @spec_generator.stubs(:call).returns({
        content: "# Todo App Spec\n\nA todo app with CRUD operations",
        structured_data: structured_data
      })
    end

    def stub_task_breakdown!(times: 1)
      @task_breaker.stubs(:call).returns(sample_tasks)
    end

    def sample_tasks
      [
        { "title" => "Setup database", "description" => "Create schema", "priority" => 0, "labels" => ["database"], "position" => 0, "depends_on" => [] },
        { "title" => "Create models", "description" => "Define models", "priority" => 0, "labels" => ["backend"], "position" => 1, "depends_on" => [0] },
        { "title" => "Build API", "description" => "REST endpoints", "priority" => 1, "labels" => ["backend"], "position" => 2, "depends_on" => [1] },
        { "title" => "Add auth", "description" => "Auth system", "priority" => 1, "labels" => ["backend"], "position" => 3, "depends_on" => [1] },
        { "title" => "Write tests", "description" => "Test suite", "priority" => 2, "labels" => ["testing"], "position" => 4, "depends_on" => [2, 3] }
      ]
    end

    def analysis_result(decision, confidence, corrective_data = {})
      {
        "decision" => decision,
        "confidence" => confidence,
        "reasoning" => "Analysis reasoning for #{decision}",
        "corrective_data" => corrective_data
      }
    end

    def build_iterate_orchestrator(spec_iterator: nil)
      Orchestrator.new(
        library_manager: @library_manager,
        spec_generator: @spec_generator,
        task_breaker: @task_breaker,
        executor: @executor,
        analyzer: @analyzer,
        tier_gate_check: @tier_gate_check,
        spec_iterator: spec_iterator || stub("spec_iterator"),
        logger: Logger.new(File::NULL)
      )
    end

    def create_paused_run_with_spec_and_tasks
      run = PipelineRun.create!(nl_input: "Build a todo app", status: :paused)
      run.create_specification!(content: "# Original Spec", version: 1)
      run.tasks.create!(title: "Setup DB", description: "Create schema", position: 0, status: :pending)
      run.tasks.create!(title: "Build API", description: "REST endpoints", position: 1, status: :completed)
      run
    end

    def sample_deltas
      [
        {
          "operation" => "added",
          "section" => "Features",
          "requirement" => "Dark Mode",
          "content" => "### Requirement: Dark Mode [REQ-UI-001]\nApp SHALL support dark mode.\n\n#### Scenario: Toggle Dark Mode\n- GIVEN a user in settings\n- WHEN they toggle dark mode\n- THEN the UI switches to dark theme",
          "rationale" => "User requested dark mode support"
        }
      ]
    end

    def sample_agent_result
      {
        "summary" => "Added dark mode support",
        "deltas" => sample_deltas
      }
    end
  end
end

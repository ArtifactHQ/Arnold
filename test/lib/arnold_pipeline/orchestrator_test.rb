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
        "tasks" => [ { "title" => "Fix", "description" => "Fix it", "position" => 0 } ]
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

    test "pipeline_failed event includes raw_response_excerpt for LLM parse errors" do
      stub_spec_generation!

      error = ArnoldPipeline::Agents::LlmParseError.new(
        "unexpected token", raw_response: "bad json " * 300
      )
      @task_breaker.stubs(:call).raises(error)

      assert_raises(ArnoldPipeline::Agents::LlmParseError) do
        @orchestrator.call(nl_input: "Build an app")
      end

      run_record = PipelineRun.last
      event = run_record.pipeline_events.find_by(event_type: :pipeline_failed)
      assert_not_nil event
      assert_includes event.summary.keys, "raw_response_excerpt"
      assert event.summary["raw_response_excerpt"].length <= 2000
    end

    test "pipeline_failed event excludes raw_response_excerpt for non-LLM errors" do
      stub_spec_generation!
      @task_breaker.stubs(:call).raises(StandardError, "some other error")

      assert_raises(StandardError) do
        @orchestrator.call(nl_input: "Build an app")
      end

      run_record = PipelineRun.last
      event = run_record.pipeline_events.find_by(event_type: :pipeline_failed)
      assert_not_nil event
      refute_includes event.summary.keys, "raw_response_excerpt"
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
        task.update!(result_comments: [ { "source" => "issue", "author" => "copilot", "body" => "Missing Gemfile" } ])
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

    test "generate_spec! stores library_selections in pipeline_run metadata" do
      stub_spec_generation!

      result = @orchestrator.call(nl_input: "Build a todo app", stop_after: :spec)

      result.reload
      selections = result.metadata["library_selections"]
      assert_not_nil selections, "Expected library_selections to be stored in metadata"
      assert_includes selections.keys, "persona"
      assert_includes selections.keys, "recipe"
      assert_includes selections.keys, "supporting_recipes"
      assert_includes selections.keys, "domain_type"
      assert selections["persona"].is_a?(String), "persona should be a string"
      assert selections["domain_type"].is_a?(String), "domain_type should be a string"
    end

    test "break_tasks passes recipe context from structured_data" do
      stub_spec_generation!(recipe_type: "web_app", supporting_recipe_types: [ "api_service" ])

      @task_breaker.expects(:call).with { |kwargs|
        kwargs[:spec_content].is_a?(String) &&
          kwargs[:recipe]&.type == "web_app" &&
          kwargs[:supporting_recipes].any? { |r| r.type == "api_service" }
      }.returns(sample_tasks)

      @orchestrator.call(nl_input: "Build a todo app", stop_after: :tasks)
    end

    test "break_tasks passes fork_deltas to task_breaker for forked runs" do
      run = PipelineRun.create!(
        nl_input: "Build a todo app",
        status: :paused,
        metadata: {
          "paused_at" => "spec",
          "forked_from_run_id" => 1,
          "fork_deltas" => sample_deltas
        }
      )
      run.create_specification!(
        content: "# Spec with dark mode",
        structured_data: { "features" => [ "crud" ] },
        version: 2
      )

      @task_breaker.expects(:call).with { |kwargs|
        kwargs[:deltas] == sample_deltas &&
          kwargs[:spec_content] == "# Spec with dark mode"
      }.returns([
        { "title" => "Add dark mode", "description" => "Implement dark mode", "priority" => 0, "labels" => [ "frontend" ], "position" => 0, "depends_on" => [] }
      ])

      @orchestrator.resume(pipeline_run: run, stop_after: :tasks)
      assert_equal 1, run.tasks.reload.count
    end

    test "break_tasks passes nil deltas for non-forked runs" do
      stub_spec_generation!

      @task_breaker.expects(:call).with { |kwargs|
        kwargs[:deltas].nil?
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

    test "break_tasks infers recipe from NL input when structured_data has no recipe_type" do
      stub_spec_generation!

      @task_breaker.expects(:call).with { |kwargs|
        # With the fallback, a recipe is inferred from NL input even without recipe_type
        kwargs[:spec_content].is_a?(String)
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
      run.create_specification!(content: "# Original Spec", structured_data: { "features" => [ "crud" ] }, version: 2)

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
      run.create_specification!(content: "# Original Spec", structured_data: { "features" => [ "crud" ] }, version: 2)

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

    test "fork! stores fork_deltas in metadata" do
      run = PipelineRun.create!(nl_input: "Build a todo app", status: :completed)
      run.create_specification!(content: "# Original Spec", version: 1)

      spec_iterator = stub("spec_iterator")
      spec_iterator.stubs(:call).returns(sample_agent_result)

      orchestrator = build_iterate_orchestrator(spec_iterator:)
      orchestrator.delta_merger.stubs(:apply!).returns({ merge_strategy: "append", delta_count: 1, new_version: 2 })

      result = orchestrator.fork!(pipeline_run: run, change_request: "Add dark mode")

      new_run = result[:pipeline_run]
      assert_equal sample_deltas, new_run.metadata["fork_deltas"]
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

    # --- call_with_spec tests ---

    test "call_with_spec skips spec generation and starts at break_tasks" do
      spec_file = Tempfile.new([ "spec", ".md" ])
      spec_file.write(<<~SPEC)
        # My App — As-Built Specification

        ## 2. Features

        ### Requirement: User Login [REQ-AUTH-001]
        Users SHALL be able to log in with email and password.

        ```json
        {"application_type": "GENERIC", "features": ["auth"], "tech_stack": {}, "data_models": [{"name": "User", "attributes": ["email", "password"]}], "recipe_type": "web_app", "supporting_recipe_types": []}
        ```
      SPEC
      spec_file.flush

      @spec_generator.expects(:call).never
      @task_breaker.expects(:call).with { |kwargs|
        kwargs[:spec_content].include?("User Login") &&
          kwargs[:recipe]&.type == "web_app"
      }.returns(sample_tasks)
      @executor.stubs(:call).returns([])
      @executor.stubs(:await_results).returns(nil)
      @executor.stubs(:merge_results).returns([])
      @analyzer.expects(:call).once.returns(analysis_result("done", 95))

      result = @orchestrator.call_with_spec(
        spec_file: spec_file.path,
        nl_input: "Build from spec"
      )

      assert_equal "completed", result.status
      assert_equal "target", result.specification.spec_type
      assert_equal "web_app", result.specification.structured_data["recipe_type"]
      assert_equal spec_file.path, result.metadata["imported_from_spec_file"]
    ensure
      spec_file&.close
      spec_file&.unlink
    end

    test "call_with_spec applies recipe_override to structured_data" do
      spec_file = Tempfile.new([ "spec", ".md" ])
      spec_file.write("# Spec\n\n```json\n{\"recipe_type\": null}\n```\n")
      spec_file.flush

      @task_breaker.expects(:call).with { |kwargs|
        kwargs[:recipe]&.type == "api_service"
      }.returns(sample_tasks)
      @executor.stubs(:call).returns([])
      @executor.stubs(:await_results).returns(nil)
      @executor.stubs(:merge_results).returns([])
      @analyzer.expects(:call).once.returns(analysis_result("done", 95))

      result = @orchestrator.call_with_spec(
        spec_file: spec_file.path,
        nl_input: "Build an API",
        recipe_override: "api_service"
      )

      assert_equal "api_service", result.specification.structured_data["recipe_type"]
    ensure
      spec_file&.close
      spec_file&.unlink
    end

    test "call_with_spec strips review section before storing spec" do
      spec_file = Tempfile.new([ "spec", ".md" ])
      spec_file.write(<<~SPEC)
        # Spec

        ## 2. Features

        ### Requirement: Login [REQ-AUTH-001]
        Users SHALL log in.

        ```json
        {"application_type": "GENERIC", "features": ["auth"], "tech_stack": {}, "data_models": [], "recipe_type": null, "supporting_recipe_types": []}
        ```

        ## 11. Review
        <!-- REVIEW_SECTION_START -->

        ### Open Questions
        - **[OQ-001]** Which auth provider?

        <!-- REVIEW_SECTION_END -->
      SPEC
      spec_file.flush

      @task_breaker.stubs(:call).returns(sample_tasks)
      @executor.stubs(:call).returns([])
      @executor.stubs(:await_results).returns(nil)
      @executor.stubs(:merge_results).returns([])
      @analyzer.expects(:call).once.returns(analysis_result("done", 95))

      result = @orchestrator.call_with_spec(
        spec_file: spec_file.path,
        nl_input: "Build from spec"
      )

      refute result.specification.content.include?("Review"),
        "Review section should be stripped from stored spec"
      refute result.specification.content.include?("OQ-001"),
        "Open questions should be stripped"
      assert result.specification.content.include?("Login"),
        "Feature content should be preserved"
    ensure
      spec_file&.close
      spec_file&.unlink
    end

    test "call_with_spec records spec_imported event" do
      spec_file = Tempfile.new([ "spec", ".md" ])
      spec_file.write("# Spec\n\n```json\n{\"recipe_type\": \"web_app\"}\n```\n")
      spec_file.flush

      @task_breaker.stubs(:call).returns(sample_tasks)
      @executor.stubs(:call).returns([])
      @executor.stubs(:await_results).returns(nil)
      @executor.stubs(:merge_results).returns([])
      @analyzer.expects(:call).once.returns(analysis_result("done", 95))

      result = @orchestrator.call_with_spec(
        spec_file: spec_file.path,
        nl_input: "Build from spec"
      )

      event = result.pipeline_events.find_by(event_type: :spec_imported)
      assert_not_nil event, "Expected spec_imported event"
      assert_equal spec_file.path, event.summary["source"]
      assert_equal "web_app", event.summary["recipe_type"]
    ensure
      spec_file&.close
      spec_file&.unlink
    end

    test "call_with_spec with stop_after tasks pauses after task breakdown" do
      spec_file = Tempfile.new([ "spec", ".md" ])
      spec_file.write("# Spec\n\n```json\n{}\n```\n")
      spec_file.flush

      @task_breaker.stubs(:call).returns(sample_tasks)

      result = @orchestrator.call_with_spec(
        spec_file: spec_file.path,
        nl_input: "Build from spec",
        stop_after: :tasks
      )

      assert_equal "paused", result.status
      assert result.tasks.count > 0
    ensure
      spec_file&.close
      spec_file&.unlink
    end

    test "call_with_spec with stop_after spec pauses immediately" do
      spec_file = Tempfile.new([ "spec", ".md" ])
      spec_file.write("# Spec\n\n```json\n{\"recipe_type\": \"web_app\"}\n```\n")
      spec_file.flush

      @spec_generator.expects(:call).never
      @task_breaker.expects(:call).never

      result = @orchestrator.call_with_spec(
        spec_file: spec_file.path,
        nl_input: "Build from spec",
        stop_after: :spec
      )

      assert_equal "paused", result.status
      assert result.specification.present?, "Spec should be persisted"
      assert_equal 0, result.tasks.count, "No tasks should be generated"
    ensure
      spec_file&.close
      spec_file&.unlink
    end

    test "call_with_spec raises on invalid recipe override" do
      spec_file = Tempfile.new([ "spec", ".md" ])
      spec_file.write("# Spec\n")
      spec_file.flush

      error = assert_raises(ArgumentError) do
        @orchestrator.call_with_spec(
          spec_file: spec_file.path,
          nl_input: "Build",
          recipe_override: "moblie_app"
        )
      end
      assert_match(/Unknown recipe type 'moblie_app'/, error.message)
      assert_match(/Valid types:/, error.message)
    ensure
      spec_file&.close
      spec_file&.unlink
    end

    test "extract_spec_json uses last JSON block not first" do
      content = <<~SPEC
        # Spec

        Example API response:
        ```json
        {"status": "ok", "data": [1, 2, 3]}
        ```

        ## Metadata
        ```json
        {"recipe_type": "web_app", "application_type": "GENERIC"}
        ```
      SPEC

      result = @orchestrator.send(:extract_spec_json, content)
      assert_equal "web_app", result["recipe_type"]
      assert_nil result["status"], "Should not pick up the example JSON block"
    end

    test "extract_spec_json handles CRLF line endings" do
      content = "# Spec\r\n\r\n```json\r\n{\"recipe_type\": \"api_service\"}\r\n```\r\n"

      result = @orchestrator.send(:extract_spec_json, content)
      assert_equal "api_service", result["recipe_type"]
    end

    # --- strip_review_section tests ---

    test "strip_review_section removes section with markers" do
      content = "# Spec\n\nContent here.\n\n## 11. Review\n<!-- REVIEW_SECTION_START -->\nReview stuff\n<!-- REVIEW_SECTION_END -->\n"
      result = @orchestrator.send(:strip_review_section, content)

      refute result.include?("Review"), "Review section should be removed"
      assert result.include?("Content here"), "Other content should be preserved"
    end

    test "strip_review_section removes section without markers (fallback)" do
      content = "# Spec\n\nContent here.\n\n## 11. Review\n\n### Open Questions\n- Question 1\n"
      result = @orchestrator.send(:strip_review_section, content)

      refute result.include?("Review"), "Review section should be removed"
      assert result.include?("Content here"), "Other content should be preserved"
    end

    test "strip_review_section is a no-op when no review section" do
      content = "# Spec\n\nContent here.\n"
      result = @orchestrator.send(:strip_review_section, content)

      assert_equal "# Spec\n\nContent here.\n", result
    end

    # --- resolve_recipes fallback tests ---

    test "resolve_recipes falls back to NL input when recipe_type is null" do
      run = PipelineRun.create!(nl_input: "Build a web application with user auth")
      run.create_specification!(
        content: "# Spec",
        structured_data: { "recipe_type" => nil },
        version: 1
      )

      recipe, _supporting = @orchestrator.send(:resolve_recipes, run)
      assert_not_nil recipe, "Should infer recipe from NL input"
    end

    test "resolve_recipes uses recipe_type when present" do
      run = PipelineRun.create!(nl_input: "whatever")
      run.create_specification!(
        content: "# Spec",
        structured_data: { "recipe_type" => "web_app" },
        version: 1
      )

      recipe, _supporting = @orchestrator.send(:resolve_recipes, run)
      assert_equal "web_app", recipe&.type
    end

    # --- finalize! tests ---

    test "finalize! runs recipe finalization commands from primary recipe" do
      repo_path = Dir.mktmpdir
      ArnoldPipeline.configure do |c|
        c.llm_api_key = "test"
        c.github_token = "test"
        c.github_repo = "owner/repo"
        c.target_repo_path = repo_path
        c.finalization_enabled = true
      end

      stub_spec_generation!(recipe_type: "web_app")
      stub_task_breakdown!(times: 1)
      @executor.stubs(:call).returns([])
      @executor.stubs(:await_results).returns(nil)
      @executor.stubs(:merge_results).returns([])
      @analyzer.expects(:call).once.returns(analysis_result("done", 95))

      call_seq = sequence("finalize_calls")
      PostMergeHookRunner.expects(:call).with { |kwargs|
        kwargs[:force_all] == true &&
          kwargs[:hooks].size == 2 &&
          kwargs[:hooks].first.name == "recipe_web_app_0" &&
          kwargs[:hooks].first.command == "bundle install" &&
          kwargs[:hooks].last.command == "bin/rails db:prepare"
      }.in_sequence(call_seq).returns([
        { name: "recipe_web_app_0", triggered: true, success: true },
        { name: "recipe_web_app_1", triggered: true, success: true }
      ])

      result = @orchestrator.call(nl_input: "Build a todo app")
      assert_equal "completed", result.status

      event = result.pipeline_events.find_by(event_type: :finalization_setup)
      assert_not_nil event
      assert_equal "web_app", event.summary["recipe_type"]
      assert_equal 2, event.summary["commands_run"]
      assert_equal 2, event.summary["commands_passed"]
    ensure
      FileUtils.rm_rf(repo_path) if repo_path
    end

    test "finalize! skips recipe finalization when no recipe_type in structured_data" do
      repo_path = Dir.mktmpdir
      ArnoldPipeline.configure do |c|
        c.llm_api_key = "test"
        c.github_token = "test"
        c.github_repo = "owner/repo"
        c.target_repo_path = repo_path
        c.finalization_enabled = true
      end

      stub_spec_generation!  # no recipe_type
      stub_task_breakdown!(times: 1)
      @executor.stubs(:call).returns([])
      @executor.stubs(:await_results).returns(nil)
      @executor.stubs(:merge_results).returns([])
      @analyzer.expects(:call).once.returns(analysis_result("done", 95))

      PostMergeHookRunner.expects(:call).never

      result = @orchestrator.call(nl_input: "Build a todo app")
      assert_equal "completed", result.status
      assert_nil result.pipeline_events.find_by(event_type: :finalization_setup)
    ensure
      FileUtils.rm_rf(repo_path) if repo_path
    end

    test "finalize! runs recipe commands before user-configured hooks" do
      repo_path = Dir.mktmpdir
      ArnoldPipeline.configure do |c|
        c.llm_api_key = "test"
        c.github_token = "test"
        c.github_repo = "owner/repo"
        c.target_repo_path = repo_path
        c.finalization_enabled = true
        c.post_merge_hooks = [
          { "name" => "user_hook", "trigger_paths" => [ "Gemfile" ], "command" => "echo user" }
        ]
      end

      stub_spec_generation!(recipe_type: "cli_tool")
      stub_task_breakdown!(times: 1)
      @executor.stubs(:call).returns([])
      @executor.stubs(:await_results).returns(nil)
      @executor.stubs(:merge_results).returns([])
      @analyzer.expects(:call).once.returns(analysis_result("done", 95))

      call_seq = sequence("ordering")
      # Recipe finalization first
      PostMergeHookRunner.expects(:call).with { |kwargs|
        kwargs[:hooks].any? { |h| h.name.start_with?("recipe_cli_tool") }
      }.in_sequence(call_seq).returns([
        { name: "recipe_cli_tool_0", triggered: true, success: true }
      ])
      # User hooks second
      PostMergeHookRunner.expects(:call).with { |kwargs|
        kwargs[:hooks].any? { |h| h.name == "user_hook" }
      }.in_sequence(call_seq).returns([
        { name: "user_hook", triggered: true, success: true }
      ])

      result = @orchestrator.call(nl_input: "Build a todo app")
      assert_equal "completed", result.status
    ensure
      FileUtils.rm_rf(repo_path) if repo_path
    end

    test "finalize! runs hooks with force_all after pipeline completion" do
      repo_path = Dir.mktmpdir
      ArnoldPipeline.configure do |c|
        c.llm_api_key = "test"
        c.github_token = "test"
        c.github_repo = "owner/repo"
        c.target_repo_path = repo_path
        c.finalization_enabled = true
        c.post_merge_hooks = [
          { "name" => "bundle_install", "trigger_paths" => [ "Gemfile" ], "command" => "echo ok" }
        ]
      end

      stub_spec_generation!
      stub_task_breakdown!(times: 1)
      @executor.stubs(:call).returns([])
      @executor.stubs(:await_results).returns(nil)
      @executor.stubs(:merge_results).returns([])
      @analyzer.expects(:call).once.returns(analysis_result("done", 95))

      PostMergeHookRunner.expects(:call).with { |kwargs|
        kwargs[:force_all] == true &&
          kwargs[:repo_path] == repo_path &&
          kwargs[:hooks].size == 1 &&
          kwargs[:hooks].first.name == "bundle_install"
      }.returns([ { name: "bundle_install", triggered: true, success: true } ])

      result = @orchestrator.call(nl_input: "Build a todo app")
      assert_equal "completed", result.status

      event = result.pipeline_events.find_by(event_type: :pipeline_finalized)
      assert_not_nil event
      assert_equal "finalized", event.summary["status"]
    ensure
      FileUtils.rm_rf(repo_path) if repo_path
    end

    test "finalize! cleans up stale worktrees" do
      repo_path = Dir.mktmpdir
      worktrees_dir = File.join(repo_path, ".worktrees")
      FileUtils.mkdir_p(worktrees_dir)
      FileUtils.mkdir_p(File.join(worktrees_dir, "task-1"))

      ArnoldPipeline.configure do |c|
        c.llm_api_key = "test"
        c.github_token = "test"
        c.github_repo = "owner/repo"
        c.target_repo_path = repo_path
        c.finalization_enabled = true
      end

      stub_spec_generation!
      stub_task_breakdown!(times: 1)
      @executor.stubs(:call).returns([])
      @executor.stubs(:await_results).returns(nil)
      @executor.stubs(:merge_results).returns([])
      @analyzer.expects(:call).once.returns(analysis_result("done", 95))

      @orchestrator.call(nl_input: "Build a todo app")

      refute Dir.exist?(worktrees_dir), "Expected .worktrees directory to be removed"
    ensure
      FileUtils.rm_rf(repo_path) if repo_path
    end

    test "finalize! runs final verification and records event" do
      repo_path = Dir.mktmpdir
      ArnoldPipeline.configure do |c|
        c.llm_api_key = "test"
        c.github_token = "test"
        c.github_repo = "owner/repo"
        c.target_repo_path = repo_path
        c.finalization_enabled = true
        c.verification_checks = [
          { "name" => "boot_check", "command" => "echo ok", "type" => "custom", "required" => true }
        ]
      end

      stub_spec_generation!
      stub_task_breakdown!(times: 1)
      @executor.stubs(:call).returns([])
      @executor.stubs(:await_results).returns(nil)
      @executor.stubs(:merge_results).returns([])
      @analyzer.expects(:call).once.returns(analysis_result("done", 95))

      VerificationRunner.expects(:call).with { |kwargs|
        kwargs[:repo_path] == repo_path &&
          kwargs[:checks].size == 1 &&
          kwargs[:checks].first.name == "boot_check"
      }.returns({ checks: [ { name: "boot_check", success: true } ], all_passed: true, summary: "1 passed, 0 failed: boot_check=OK" })

      result = @orchestrator.call(nl_input: "Build a todo app")

      event = result.pipeline_events.find_by(event_type: :finalization_verification)
      assert_not_nil event
      assert event.summary["all_passed"]
    ensure
      FileUtils.rm_rf(repo_path) if repo_path
    end

    test "finalize! skipped when finalization_enabled is false" do
      ArnoldPipeline.configure do |c|
        c.llm_api_key = "test"
        c.github_token = "test"
        c.github_repo = "owner/repo"
        c.finalization_enabled = false
      end

      stub_spec_generation!
      stub_task_breakdown!(times: 1)
      @executor.stubs(:call).returns([])
      @executor.stubs(:await_results).returns(nil)
      @executor.stubs(:merge_results).returns([])
      @analyzer.expects(:call).once.returns(analysis_result("done", 95))

      PostMergeHookRunner.expects(:call).never
      VerificationRunner.expects(:call).never

      result = @orchestrator.call(nl_input: "Build a todo app")
      assert_equal "completed", result.status
      assert_nil result.pipeline_events.find_by(event_type: :pipeline_finalized)
    end

    test "finalize! skipped when target_repo_path is nil" do
      ArnoldPipeline.configure do |c|
        c.llm_api_key = "test"
        c.github_token = "test"
        c.github_repo = "owner/repo"
        c.finalization_enabled = true
        c.claude_code_repo_path = nil
        c.post_merge_hooks = [
          { "name" => "bundle_install", "trigger_paths" => [ "Gemfile" ], "command" => "bundle install" }
        ]
      end

      stub_spec_generation!
      stub_task_breakdown!(times: 1)
      @executor.stubs(:call).returns([])
      @executor.stubs(:await_results).returns(nil)
      @executor.stubs(:merge_results).returns([])
      @analyzer.expects(:call).once.returns(analysis_result("done", 95))

      PostMergeHookRunner.expects(:call).never

      result = @orchestrator.call(nl_input: "Build a todo app")
      assert_equal "completed", result.status
      assert_nil result.pipeline_events.find_by(event_type: :pipeline_finalized)
    end

    test "finalize! failure is non-fatal and does not change pipeline status" do
      repo_path = Dir.mktmpdir
      ArnoldPipeline.configure do |c|
        c.llm_api_key = "test"
        c.github_token = "test"
        c.github_repo = "owner/repo"
        c.target_repo_path = repo_path
        c.finalization_enabled = true
        c.post_merge_hooks = [
          { "name" => "broken", "trigger_paths" => [ "*" ], "command" => "false" }
        ]
      end

      stub_spec_generation!
      stub_task_breakdown!(times: 1)
      @executor.stubs(:call).returns([])
      @executor.stubs(:await_results).returns(nil)
      @executor.stubs(:merge_results).returns([])
      @analyzer.expects(:call).once.returns(analysis_result("done", 95))

      PostMergeHookRunner.expects(:call).raises(RuntimeError, "something broke")

      result = @orchestrator.call(nl_input: "Build a todo app")
      assert_equal "completed", result.status
    ensure
      FileUtils.rm_rf(repo_path) if repo_path
    end

    # --- build_finalization_checks (recipe merge) ---

    test "build_finalization_checks includes recipe finalization checks" do
      pipeline_run = PipelineRun.create!(nl_input: "Build a web app")
      pipeline_run.create_specification!(
        content: "# Spec", version: 1,
        structured_data: { "recipe_type" => "web_app" }
      )

      config = ArnoldPipeline.configuration
      config.verification_checks = []

      checks = @orchestrator.send(:build_finalization_checks, config, pipeline_run)
      boot = checks.find { |c| c.name == "Boot check" }
      assert_not_nil boot, "Should include Boot check from web_app recipe finalization"
      assert_equal :custom, boot.type
    end

    test "build_finalization_checks merges recipe and config checks" do
      pipeline_run = PipelineRun.create!(nl_input: "Build a web app")
      pipeline_run.create_specification!(
        content: "# Spec", version: 1,
        structured_data: { "recipe_type" => "web_app" }
      )

      config = ArnoldPipeline.configuration
      config.verification_checks = [
        { "name" => "Custom final", "command" => "echo custom", "type" => "custom" }
      ]

      checks = @orchestrator.send(:build_finalization_checks, config, pipeline_run)
      names = checks.map(&:name)
      assert_includes names, "Boot check"
      assert_includes names, "Custom final"
    end

    test "build_finalization_checks user config overrides recipe check by name" do
      pipeline_run = PipelineRun.create!(nl_input: "Build a web app")
      pipeline_run.create_specification!(
        content: "# Spec", version: 1,
        structured_data: { "recipe_type" => "web_app" }
      )

      config = ArnoldPipeline.configuration
      config.verification_checks = [
        { "name" => "Boot check", "command" => "echo override", "type" => "custom", "required" => false }
      ]

      checks = @orchestrator.send(:build_finalization_checks, config, pipeline_run)
      boot_checks = checks.select { |c| c.name == "Boot check" }
      assert_equal 1, boot_checks.size, "Should deduplicate by name"
      assert_equal "echo override", boot_checks.first.command, "User override should win"
    end

    test "build_finalization_checks excludes test_suite type" do
      pipeline_run = PipelineRun.create!(nl_input: "Build a web app")
      pipeline_run.create_specification!(
        content: "# Spec", version: 1,
        structured_data: { "recipe_type" => "web_app" }
      )

      config = ArnoldPipeline.configuration
      config.verification_checks = [
        { "name" => "Tests", "command" => "bin/rails test", "type" => "test_suite" }
      ]

      checks = @orchestrator.send(:build_finalization_checks, config, pipeline_run)
      refute checks.any? { |c| c.type == :test_suite }, "test_suite should be excluded from finalization"
    end

    test "build_finalization_checks works without recipe" do
      pipeline_run = PipelineRun.create!(nl_input: "Build something")
      pipeline_run.create_specification!(
        content: "# Spec", version: 1,
        structured_data: {}
      )

      config = ArnoldPipeline.configuration
      config.verification_checks = [
        { "name" => "Custom", "command" => "echo ok", "type" => "custom" }
      ]

      checks = @orchestrator.send(:build_finalization_checks, config, pipeline_run)
      assert_equal 1, checks.size
      assert_equal "Custom", checks.first.name
    end

    private

    def stub_spec_generation!(recipe_type: nil, supporting_recipe_types: nil)
      structured_data = { "features" => [ "create", "read", "update", "delete" ] }
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
        { "title" => "Setup database", "description" => "Create schema", "priority" => 0, "labels" => [ "database" ], "position" => 0, "depends_on" => [] },
        { "title" => "Create models", "description" => "Define models", "priority" => 0, "labels" => [ "backend" ], "position" => 1, "depends_on" => [ 0 ] },
        { "title" => "Build API", "description" => "REST endpoints", "priority" => 1, "labels" => [ "backend" ], "position" => 2, "depends_on" => [ 1 ] },
        { "title" => "Add auth", "description" => "Auth system", "priority" => 1, "labels" => [ "backend" ], "position" => 3, "depends_on" => [ 1 ] },
        { "title" => "Write tests", "description" => "Test suite", "priority" => 2, "labels" => [ "testing" ], "position" => 4, "depends_on" => [ 2, 3 ] }
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

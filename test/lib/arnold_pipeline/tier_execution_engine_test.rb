require "test_helper"
require "octokit"
require "faraday"
require "arnold_pipeline/tier_execution_engine"

module ArnoldPipeline
  class TierExecutionEngineTest < ActiveSupport::TestCase
    setup do
      @executor = stub("executor")
      @tier_gate_check = stub("tier_gate_check")
      @tier_gate_check.stubs(:call).returns({
        "pass" => true,
        "issues" => [],
        "context_summary" => "Tier complete.",
        "corrective_tasks" => []
      })

      @provider = stub("execution_provider")
      @provider.stubs(:recoverable_errors).returns([Octokit::Error, Faraday::Error])
      @provider.stubs(:async?).returns(true)
      @executor.stubs(:provider).returns(@provider)

      @engine = TierExecutionEngine.new(
        executor: @executor,
        tier_gate_check: @tier_gate_check,
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

    # --- tier_task_resolved? ---

    test "tier_task_resolved? returns false when workflow_active is true" do
      pipeline_run = PipelineRun.create!(nl_input: "Build an app")
      task = pipeline_run.tasks.create!(
        title: "Setup DB", position: 0, external_id: "42",
        result_diff: '[{"filename":"schema.rb"}]',
        workflow_active: true
      )

      refute @engine.tier_task_resolved?(task),
        "tier_task_resolved? should return false when workflow_active"
    end

    test "tier_task_resolved? returns true when workflow_active is false with diffs" do
      pipeline_run = PipelineRun.create!(nl_input: "Build an app")
      task = pipeline_run.tasks.create!(
        title: "Setup DB", position: 0, external_id: "42",
        result_diff: '[{"filename":"schema.rb"}]',
        workflow_active: false
      )

      assert @engine.tier_task_resolved?(task),
        "tier_task_resolved? should return true when workflow inactive and diffs present"
    end

    test "tier_task_resolved? returns false without external_id" do
      pipeline_run = PipelineRun.create!(nl_input: "Build an app")
      task = pipeline_run.tasks.create!(
        title: "Setup DB", position: 0,
        result_diff: '[{"filename":"schema.rb"}]'
      )

      refute @engine.tier_task_resolved?(task)
    end

    test "tier_task_resolved? returns true for failed task" do
      pipeline_run = PipelineRun.create!(nl_input: "Build an app")
      task = pipeline_run.tasks.create!(
        title: "Setup DB", position: 0, external_id: "42",
        status: :failed
      )

      assert @engine.tier_task_resolved?(task)
    end

    # --- format_task_comments ---

    test "format_task_comments returns empty string for tasks without comments" do
      pipeline_run = PipelineRun.create!(nl_input: "Build an app")
      task = pipeline_run.tasks.create!(title: "Setup DB", position: 0)

      assert_equal "", @engine.format_task_comments([task])
    end

    test "format_task_comments formats comments with source and author" do
      pipeline_run = PipelineRun.create!(nl_input: "Build an app")
      task = pipeline_run.tasks.create!(
        title: "Setup DB", position: 0,
        result_comments: [{ "source" => "issue", "author" => "copilot", "body" => "Missing Gemfile" }]
      )

      result = @engine.format_task_comments([task])
      assert_includes result, "Setup DB"
      assert_includes result, "[issue] copilot: Missing Gemfile"
    end

    # --- merge_all_results! (narrow rescue) ---

    test "merge_all_results! swallows Faraday::Error" do
      pipeline_run = PipelineRun.create!(nl_input: "test")
      @executor.stubs(:merge_results).raises(Faraday::Error, "connection refused")

      assert_nothing_raised do
        @engine.merge_all_results!(pipeline_run)
      end
    end

    test "merge_all_results! lets NoMethodError bubble up" do
      pipeline_run = PipelineRun.create!(nl_input: "test")
      @executor.stubs(:merge_results).raises(NoMethodError, "undefined method 'foo'")

      assert_raises(NoMethodError) do
        @engine.merge_all_results!(pipeline_run)
      end
    end

    # --- merge_tier_results! (narrow rescue) ---

    test "merge_tier_results! swallows Octokit::ServerError" do
      pipeline_run = PipelineRun.create!(nl_input: "test")
      @executor.stubs(:merge_results).raises(Octokit::ServerError)

      assert_nothing_raised do
        @engine.send(:merge_tier_results!, pipeline_run, [])
      end
    end

    test "merge_tier_results! lets NoMethodError bubble up" do
      pipeline_run = PipelineRun.create!(nl_input: "test")
      @executor.stubs(:merge_results).raises(NoMethodError, "undefined method 'bar'")

      assert_raises(NoMethodError) do
        @engine.send(:merge_tier_results!, pipeline_run, [])
      end
    end

    # --- run_tier_gate! ---

    test "run_tier_gate! logs warning with backtrace on error" do
      log_output = StringIO.new
      test_logger = Logger.new(log_output)

      engine = TierExecutionEngine.new(
        executor: @executor,
        tier_gate_check: @tier_gate_check,
        logger: test_logger
      )

      pipeline_run = PipelineRun.create!(nl_input: "test")
      task = pipeline_run.tasks.create!(title: "Setup DB", position: 0, tier: 0)

      @tier_gate_check.stubs(:call).raises(RuntimeError, "unexpected gate error")

      result = engine.send(:run_tier_gate!, pipeline_run, 0, [task])

      assert_nil result
      log_content = log_output.string
      assert_match(/Tier gate check failed \(non-fatal\)/, log_content)
      assert_match(/RuntimeError/, log_content)
      assert_match(/unexpected gate error/, log_content)
    end

    # --- execute_tiers! ---

    test "execute_tiers! runs tier-by-tier execution" do
      pipeline_run = PipelineRun.create!(nl_input: "Build an app")
      pipeline_run.tasks.create!(title: "Setup DB", position: 0, tier: 0)
      pipeline_run.tasks.create!(title: "Build API", position: 1, tier: 1)

      @executor.stubs(:call).returns([])
      @executor.stubs(:await_results).returns(nil)
      @executor.stubs(:merge_results).returns([])

      @engine.execute_tiers!(pipeline_run)

      assert_equal "awaiting_results", pipeline_run.reload.status
    end

    test "execute_tiers! skips fully resolved tiers" do
      pipeline_run = PipelineRun.create!(nl_input: "Build an app")
      pipeline_run.tasks.create!(
        title: "Setup DB", position: 0, tier: 0, external_id: "42",
        result_diff: '[{"filename":"schema.rb"}]'
      )
      pipeline_run.tasks.create!(title: "Build API", position: 1, tier: 1)

      @executor.expects(:call).once.returns([])
      @executor.stubs(:await_results).returns(nil)
      @executor.stubs(:merge_results).returns([])

      @engine.execute_tiers!(pipeline_run)
    end

    # --- handle_tier_gate_failure! iterative (not recursive) ---

    test "merge_all_results! re-raises non-recoverable errors" do
      pipeline_run = PipelineRun.create!(nl_input: "test")
      @provider.stubs(:recoverable_errors).returns([])
      @executor.stubs(:merge_results).raises(Faraday::Error, "connection refused")

      assert_raises(Faraday::Error) do
        @engine.merge_all_results!(pipeline_run)
      end
    end

    test "execute_tiers! calls fetch_results instead of await_results for sync provider" do
      pipeline_run = PipelineRun.create!(nl_input: "Build an app")
      pipeline_run.tasks.create!(title: "Setup DB", position: 0, tier: 0)

      @provider.stubs(:async?).returns(false)
      @executor.stubs(:call).returns([])
      @executor.expects(:fetch_results).once
      @executor.expects(:await_results).never
      @executor.stubs(:merge_results).returns([])

      @engine.execute_tiers!(pipeline_run)
    end

    test "execute_tiers! reloads tasks after publish for sync providers" do
      pipeline_run = PipelineRun.create!(nl_input: "Build an app")
      task = pipeline_run.tasks.create!(title: "Setup DB", position: 0, tier: 0)

      @provider.stubs(:async?).returns(false)

      # Simulate what executor.call does: sets external_id in DB via find_by,
      # but the in-memory task object still has nil external_id.
      @executor.stubs(:call).with { |tasks:, **|
        Task.find(tasks.first.id).update!(external_id: "ext-1", status: :in_progress)
        true
      }.returns([])

      # Capture the tasks passed to fetch_results to verify they were reloaded
      fetched_tasks = nil
      @executor.stubs(:fetch_results).with { |pipeline_run:, tasks:|
        fetched_tasks = tasks
        true
      }.returns([])
      @executor.stubs(:merge_results).returns([])

      @engine.execute_tiers!(pipeline_run)

      assert_not_nil fetched_tasks, "fetch_results should have been called with tasks"
      assert_equal "ext-1", fetched_tasks.first.external_id,
        "Engine should reload tasks before fetch_results so external_id is present"
    end

    # --- Sequential corrective task execution ---

    test "handle_tier_gate_failure! executes corrective tasks sequentially with merge between each" do
      ArnoldPipeline.configure do |c|
        c.max_iterations = 3
        c.max_tier_retries = 1
        c.tier_gate_enabled = true
        c.llm_api_key = "test"
        c.github_token = "test"
        c.github_repo = "owner/repo"
      end

      pipeline_run = PipelineRun.create!(nl_input: "Build an app")
      pipeline_run.tasks.create!(title: "Setup DB", position: 0, tier: 0)

      # Gate fails first, then passes on re-check
      gate_fail = {
        "pass" => false,
        "issues" => ["missing files"],
        "corrective_tasks" => [
          { "title" => "Fix A", "description" => "fix a" },
          { "title" => "Fix B", "description" => "fix b" }
        ],
        "context_summary" => "context"
      }
      gate_pass = {
        "pass" => true,
        "issues" => [],
        "context_summary" => "All good.",
        "corrective_tasks" => []
      }

      call_order = sequence("sequential_execution")

      # Task 1: call → await → merge
      @executor.expects(:call).with { |tasks:, **| tasks.size == 1 && tasks.first.title == "Fix A" }
        .in_sequence(call_order).returns([])
      @executor.expects(:await_results).in_sequence(call_order).returns(nil)
      @executor.expects(:merge_results).in_sequence(call_order).returns([])

      # Task 2: call → await → merge
      @executor.expects(:call).with { |tasks:, **| tasks.size == 1 && tasks.first.title == "Fix B" }
        .in_sequence(call_order).returns([])
      @executor.expects(:await_results).in_sequence(call_order).returns(nil)
      @executor.expects(:merge_results).in_sequence(call_order).returns([])

      # Re-check gate passes
      @tier_gate_check.stubs(:call).returns(gate_pass)

      @engine.send(:handle_tier_gate_failure!, pipeline_run, 0, [], gate_fail, [])

      # Verify 2 corrective tasks were created
      corrective = pipeline_run.tasks.where(tier: 0).where.not(title: "Setup DB")
      assert_equal 2, corrective.count
    end

    test "handle_tier_gate_failure! sequential execution works with sync provider" do
      ArnoldPipeline.configure do |c|
        c.max_iterations = 3
        c.max_tier_retries = 1
        c.tier_gate_enabled = true
        c.llm_api_key = "test"
        c.github_token = "test"
        c.github_repo = "owner/repo"
      end

      @provider.stubs(:async?).returns(false)

      pipeline_run = PipelineRun.create!(nl_input: "Build an app")
      pipeline_run.tasks.create!(title: "Setup DB", position: 0, tier: 0)

      gate_fail = {
        "pass" => false,
        "issues" => ["broken build"],
        "corrective_tasks" => [
          { "title" => "Fix build", "description" => "fix the build" }
        ],
        "context_summary" => "context"
      }
      gate_pass = {
        "pass" => true,
        "issues" => [],
        "context_summary" => "Fixed.",
        "corrective_tasks" => []
      }

      call_order = sequence("sync_execution")

      # Sync: call → fetch_results → merge (no await)
      @executor.expects(:call).in_sequence(call_order).returns([])
      @executor.expects(:fetch_results).in_sequence(call_order).returns([])
      @executor.expects(:await_results).never
      @executor.expects(:merge_results).in_sequence(call_order).returns([])

      @tier_gate_check.stubs(:call).returns(gate_pass)

      @engine.send(:handle_tier_gate_failure!, pipeline_run, 0, [], gate_fail, [])
    end

    # --- Task annotation in tier gate ---

    test "run_tier_gate! annotates empty-diff failed tasks" do
      pipeline_run = PipelineRun.create!(nl_input: "Build an app")
      task = pipeline_run.tasks.create!(
        title: "Admin Interface", position: 0, tier: 0,
        external_id: "42", status: :failed, result_diff: "[]"
      )

      captured_summaries = nil
      @tier_gate_check.stubs(:call).with { |**kwargs|
        captured_summaries = kwargs[:task_summaries]
        true
      }.returns({ "pass" => true, "issues" => [], "context_summary" => "Done.", "corrective_tasks" => [] })

      @engine.send(:run_tier_gate!, pipeline_run, 0, [task])

      assert_includes captured_summaries, "[FAILED - EMPTY DIFF]"
    end

    test "run_tier_gate! annotates failed tasks with diffs" do
      pipeline_run = PipelineRun.create!(nl_input: "Build an app")
      task = pipeline_run.tasks.create!(
        title: "Setup DB", position: 0, tier: 0,
        external_id: "42", status: :failed,
        result_diff: '[{"filename":"schema.rb","patch":"+ create_table"}]'
      )

      captured_summaries = nil
      @tier_gate_check.stubs(:call).with { |**kwargs|
        captured_summaries = kwargs[:task_summaries]
        true
      }.returns({ "pass" => true, "issues" => [], "context_summary" => "Done.", "corrective_tasks" => [] })

      @engine.send(:run_tier_gate!, pipeline_run, 0, [task])

      assert_includes captured_summaries, "**[FAILED]**"
      refute_includes captured_summaries, "EMPTY DIFF"
    end

    test "run_tier_gate! does not annotate successful tasks" do
      pipeline_run = PipelineRun.create!(nl_input: "Build an app")
      task = pipeline_run.tasks.create!(
        title: "Setup DB", position: 0, tier: 0,
        external_id: "42", status: :completed,
        result_diff: '[{"filename":"schema.rb"}]'
      )

      captured_summaries = nil
      @tier_gate_check.stubs(:call).with { |**kwargs|
        captured_summaries = kwargs[:task_summaries]
        true
      }.returns({ "pass" => true, "issues" => [], "context_summary" => "Done.", "corrective_tasks" => [] })

      @engine.send(:run_tier_gate!, pipeline_run, 0, [task])

      refute_includes captured_summaries, "[FAILED"
    end

    # --- Repo context in tier gate ---

    test "run_tier_gate! passes repo_context when claude_code_repo_path is set" do
      ArnoldPipeline.configure do |c|
        c.llm_api_key = "test"
        c.github_token = "test"
        c.github_repo = "owner/repo"
        c.claude_code_repo_path = File.expand_path("../../..", __dir__)
      end

      pipeline_run = PipelineRun.create!(nl_input: "Build an app")
      task = pipeline_run.tasks.create!(
        title: "Setup DB", position: 0, tier: 0,
        external_id: "42", status: :completed,
        result_diff: '[{"filename":"schema.rb"}]'
      )

      captured_context = nil
      @tier_gate_check.stubs(:call).with { |**kwargs|
        captured_context = kwargs[:repo_context]
        true
      }.returns({ "pass" => true, "issues" => [], "context_summary" => "Done.", "corrective_tasks" => [] })

      @engine.send(:run_tier_gate!, pipeline_run, 0, [task])

      assert_not_nil captured_context, "repo_context should be passed to tier gate check"
      assert_includes captured_context, "lib/", "Should include files from the repo"
    end

    test "run_tier_gate! passes nil repo_context when no repo_path configured" do
      ArnoldPipeline.configure do |c|
        c.llm_api_key = "test"
        c.github_token = "test"
        c.github_repo = "owner/repo"
        c.claude_code_repo_path = nil
      end

      pipeline_run = PipelineRun.create!(nl_input: "Build an app")
      task = pipeline_run.tasks.create!(
        title: "Setup DB", position: 0, tier: 0,
        external_id: "42", status: :completed,
        result_diff: '[{"filename":"schema.rb"}]'
      )

      captured_context = :not_set
      @tier_gate_check.stubs(:call).with { |**kwargs|
        captured_context = kwargs[:repo_context]
        true
      }.returns({ "pass" => true, "issues" => [], "context_summary" => "Done.", "corrective_tasks" => [] })

      @engine.send(:run_tier_gate!, pipeline_run, 0, [task])

      assert_nil captured_context, "repo_context should be nil when no repo_path configured"
    end

    # --- format_repo_context ---

    test "format_repo_context groups files by directory" do
      file_list = %w[
        app/models/user.rb
        app/models/post.rb
        config/routes.rb
        db/migrate/001_create_users.rb
      ]
      result = @engine.send(:format_repo_context, file_list)

      assert_includes result, "app/models/ (2 files): post.rb, user.rb"
      assert_includes result, "config/ (1 files): routes.rb"
      assert_includes result, "db/migrate/ (1 files): 001_create_users.rb"
    end

    test "format_repo_context caps long directories" do
      file_list = (1..30).map { |i| "db/migrate/#{format('%03d', i)}_migration.rb" }
      result = @engine.send(:format_repo_context, file_list)

      assert_includes result, "db/migrate/ (30 files):"
      assert_includes result, "... and 10 more"
    end

    # --- Verbose logging tests ---

    test "handle_tier_gate_failure! logs gate issues at debug level" do
      ArnoldPipeline.configure do |c|
        c.max_iterations = 3
        c.max_tier_retries = 1
        c.tier_gate_enabled = true
        c.llm_api_key = "test"
        c.github_token = "test"
        c.github_repo = "owner/repo"
      end

      log_output = StringIO.new
      debug_logger = Logger.new(log_output, level: Logger::DEBUG)
      engine = TierExecutionEngine.new(
        executor: @executor, tier_gate_check: @tier_gate_check, logger: debug_logger
      )

      pipeline_run = PipelineRun.create!(nl_input: "Build an app")
      pipeline_run.tasks.create!(title: "Setup DB", position: 0, tier: 0)

      gate_fail = {
        "pass" => false,
        "issues" => ["Missing routes file", "No database migration"],
        "corrective_tasks" => [
          { "title" => "Add routes", "description" => "Create config/routes.rb", "labels" => ["routing", "corrective"] }
        ],
        "context_summary" => "context"
      }
      gate_pass = { "pass" => true, "issues" => [], "context_summary" => "Done.", "corrective_tasks" => [] }

      @executor.stubs(:call).returns([])
      @executor.stubs(:await_results).returns(nil)
      @executor.stubs(:merge_results).returns([])
      @tier_gate_check.stubs(:call).returns(gate_pass)

      engine.send(:handle_tier_gate_failure!, pipeline_run, 0, [], gate_fail, [])

      log_content = log_output.string
      assert_match(/Gate issues triggering correction:/, log_content)
      assert_match(/1\. Missing routes file/, log_content)
      assert_match(/2\. No database migration/, log_content)
      assert_match(/Task: Add routes/, log_content)
      assert_match(/Description: Create config\/routes.rb/, log_content)
      assert_match(/Labels: routing, corrective/, log_content)
    end

    test "run_criteria_check! logs per-criterion details at debug level" do
      ArnoldPipeline.configure do |c|
        c.llm_api_key = "test"
        c.github_token = "test"
        c.github_repo = "owner/repo"
        c.claude_code_repo_path = File.expand_path("../../..", __dir__)
      end

      log_output = StringIO.new
      debug_logger = Logger.new(log_output, level: Logger::DEBUG)
      engine = TierExecutionEngine.new(
        executor: @executor, tier_gate_check: @tier_gate_check, logger: debug_logger
      )

      pipeline_run = PipelineRun.create!(nl_input: "Build an app")
      task = pipeline_run.tasks.create!(
        title: "Setup DB", position: 0, tier: 0,
        acceptance_criteria: [
          { "type" => "file_exists", "description" => "Gemfile exists", "path" => "Gemfile" }
        ]
      )

      verified_criterion = ArnoldPipeline::AcceptanceCriterion.new(
        type: "file_exists", description: "Gemfile exists", params: { "path" => "Gemfile" }
      )
      ArnoldPipeline::CriteriaChecker.stubs(:call).returns({
        verified: [verified_criterion], failed: [], unverified: []
      })

      engine.send(:run_criteria_check!, pipeline_run, [task])

      log_content = log_output.string
      assert_match(/\[file_exists\] Gemfile exists/, log_content)
      assert_match(/Criteria results: 1 verified, 0 failed, 0 unverified/, log_content)
      assert_match(/PASS: Gemfile exists \(file_exists\)/, log_content)
    end

    test "run_criteria_check! enriches event summary with criteria array" do
      ArnoldPipeline.configure do |c|
        c.llm_api_key = "test"
        c.github_token = "test"
        c.github_repo = "owner/repo"
        c.claude_code_repo_path = File.expand_path("../../..", __dir__)
      end

      # Use a real object to avoid Mocha block/kwargs issues
      event_recorder = build_recording_event_recorder

      engine = TierExecutionEngine.new(
        executor: @executor, tier_gate_check: @tier_gate_check,
        logger: Logger.new(File::NULL), event_recorder: event_recorder
      )

      pipeline_run = PipelineRun.create!(nl_input: "Build an app")
      task = pipeline_run.tasks.create!(
        title: "Setup DB", position: 0, tier: 0,
        acceptance_criteria: [
          { "type" => "file_exists", "description" => "Gemfile exists", "path" => "Gemfile" },
          { "type" => "route_exists", "description" => "Health check route", "path" => "config/routes.rb", "pattern" => "up" }
        ]
      )

      verified = ArnoldPipeline::AcceptanceCriterion.new(type: "file_exists", description: "Gemfile exists", params: {})
      failed = ArnoldPipeline::AcceptanceCriterion.new(type: "route_exists", description: "Health check route", params: {})
      ArnoldPipeline::CriteriaChecker.stubs(:call).returns({
        verified: [verified], failed: [failed], unverified: []
      })

      engine.send(:run_criteria_check!, pipeline_run, [task])

      criteria_event = event_recorder.events.find { |e| e[:event_type] == :criteria_check }
      assert_not_nil criteria_event, "Expected a criteria_check event to be recorded"
      summary = criteria_event[:summary]
      assert_equal 1, summary[:verified_count]
      assert_equal 1, summary[:failed_count]
      assert_equal 0, summary[:unverified_count]

      criteria = summary[:criteria]
      assert_equal 2, criteria.size
      assert_equal({ type: "file_exists", description: "Gemfile exists", result: "verified" }, criteria[0])
      assert_equal({ type: "route_exists", description: "Health check route", result: "failed" }, criteria[1])
    end

    test "run_tier_gate! enriches event summary with corrective_tasks" do
      ArnoldPipeline.configure do |c|
        c.llm_api_key = "test"
        c.github_token = "test"
        c.github_repo = "owner/repo"
      end

      event_recorder = build_recording_event_recorder

      engine = TierExecutionEngine.new(
        executor: @executor, tier_gate_check: @tier_gate_check,
        logger: Logger.new(File::NULL), event_recorder: event_recorder
      )

      pipeline_run = PipelineRun.create!(nl_input: "Build an app")
      task = pipeline_run.tasks.create!(
        title: "Setup DB", position: 0, tier: 0, description: "Set up the database",
        external_id: "42", result_diff: '[{"filename":"schema.rb"}]'
      )

      @tier_gate_check.stubs(:call).returns({
        "pass" => false,
        "issues" => ["Missing route"],
        "corrective_tasks" => [
          { "title" => "Add route", "description" => "Add GET /up to routes.rb" }
        ],
        "context_summary" => "Issues found."
      })

      engine.send(:run_tier_gate!, pipeline_run, 0, [task])

      timed_event = event_recorder.events.find { |e| e[:event_type] == :tier_gate_evaluated }
      assert_not_nil timed_event, "Expected a tier_gate_evaluated event to be recorded"

      summary = timed_event[:summary]
      assert_equal false, summary[:pass]
      assert_equal 1, summary[:corrective_task_count]
      assert_equal [{ title: "Add route", description: "Add GET /up to routes.rb" }], summary[:corrective_tasks]

      payload = timed_event[:payload]
      assert payload.key?(:task_summaries)
      assert payload.key?(:diffs)
      assert payload.key?(:gate_response)
    end

    # --- Config flag independence: tier_gate_enabled vs context_propagation_enabled ---

    test "tier_gate disabled + context_propagation enabled: skips criteria check, runs LLM gate, does not block on failure" do
      ArnoldPipeline.configure do |c|
        c.tier_gate_enabled = false
        c.context_propagation_enabled = true
        c.llm_api_key = "test"
        c.github_token = "test"
        c.github_repo = "owner/repo"
        c.claude_code_repo_path = File.expand_path("../../..", __dir__)
      end

      pipeline_run = PipelineRun.create!(nl_input: "Build an app")
      pipeline_run.tasks.create!(
        title: "Setup DB", position: 0, tier: 0,
        acceptance_criteria: [
          { "type" => "file_exists", "description" => "Gemfile exists", "path" => "Gemfile" }
        ]
      )

      @executor.stubs(:call).returns([])
      @executor.stubs(:await_results).returns(nil)
      @executor.stubs(:merge_results).returns([])

      # Gate returns failure — should NOT block since tier_gate_enabled is false
      @tier_gate_check.stubs(:call).returns({
        "pass" => false,
        "issues" => ["something wrong"],
        "context_summary" => "Tier 0 context for propagation.",
        "corrective_tasks" => []
      })

      # Criteria check should NOT be called
      ArnoldPipeline::CriteriaChecker.expects(:call).never

      assert_nothing_raised do
        @engine.execute_tiers!(pipeline_run)
      end

      # Context should still be propagated
      pipeline_run.reload
      tier_contexts = pipeline_run.metadata["tier_contexts"]
      assert_not_nil tier_contexts, "Context should be propagated even with tier_gate disabled"
      assert_equal "Tier 0 context for propagation.", tier_contexts.first["summary"]
    end

    test "tier_gate disabled + context_propagation disabled: skips criteria check and LLM gate entirely" do
      ArnoldPipeline.configure do |c|
        c.tier_gate_enabled = false
        c.context_propagation_enabled = false
        c.llm_api_key = "test"
        c.github_token = "test"
        c.github_repo = "owner/repo"
        c.claude_code_repo_path = File.expand_path("../../..", __dir__)
      end

      pipeline_run = PipelineRun.create!(nl_input: "Build an app")
      pipeline_run.tasks.create!(
        title: "Setup DB", position: 0, tier: 0,
        acceptance_criteria: [
          { "type" => "file_exists", "description" => "Gemfile exists", "path" => "Gemfile" }
        ]
      )

      @executor.stubs(:call).returns([])
      @executor.stubs(:await_results).returns(nil)
      @executor.stubs(:merge_results).returns([])

      # Neither criteria check nor LLM gate should be called
      ArnoldPipeline::CriteriaChecker.expects(:call).never
      @tier_gate_check.expects(:call).never

      @engine.execute_tiers!(pipeline_run)
    end

    test "tier_gate enabled + context_propagation enabled: runs criteria check, LLM gate, and propagates context" do
      ArnoldPipeline.configure do |c|
        c.tier_gate_enabled = true
        c.context_propagation_enabled = true
        c.llm_api_key = "test"
        c.github_token = "test"
        c.github_repo = "owner/repo"
        c.claude_code_repo_path = File.expand_path("../../..", __dir__)
      end

      pipeline_run = PipelineRun.create!(nl_input: "Build an app")
      pipeline_run.tasks.create!(
        title: "Setup DB", position: 0, tier: 0,
        acceptance_criteria: [
          { "type" => "file_exists", "description" => "Gemfile exists", "path" => "Gemfile" }
        ]
      )

      @executor.stubs(:call).returns([])
      @executor.stubs(:await_results).returns(nil)
      @executor.stubs(:merge_results).returns([])

      verified = ArnoldPipeline::AcceptanceCriterion.new(type: "file_exists", description: "Gemfile exists", params: {})
      ArnoldPipeline::CriteriaChecker.stubs(:call).returns({ verified: [verified], failed: [], unverified: [] })

      @tier_gate_check.stubs(:call).returns({
        "pass" => true,
        "issues" => [],
        "context_summary" => "All good.",
        "corrective_tasks" => []
      })

      @engine.execute_tiers!(pipeline_run)

      # Both criteria check and context propagation should have happened
      pipeline_run.reload
      tier_contexts = pipeline_run.metadata["tier_contexts"]
      assert_not_nil tier_contexts
      assert_equal "All good.", tier_contexts.first["summary"]
    end

    # --- Existing gate failure tests ---

    test "handle_tier_gate_failure! retries up to max_tier_retries then pauses" do
      ArnoldPipeline.configure do |c|
        c.max_iterations = 3
        c.max_tier_retries = 2
        c.tier_gate_enabled = true
        c.llm_api_key = "test"
        c.github_token = "test"
        c.github_repo = "owner/repo"
      end

      pipeline_run = PipelineRun.create!(nl_input: "Build an app")
      pipeline_run.tasks.create!(title: "Setup DB", position: 0, tier: 0)

      @executor.stubs(:call).returns([])
      @executor.stubs(:await_results).returns(nil)
      @executor.stubs(:merge_results).returns([])

      gate_result = {
        "pass" => false,
        "issues" => ["test failure"],
        "corrective_tasks" => [{ "title" => "Fix test", "description" => "fix" }],
        "context_summary" => "context"
      }

      # Gate always fails
      @tier_gate_check.stubs(:call).returns(gate_result)

      assert_raises(TierGateError) do
        @engine.send(:handle_tier_gate_failure!, pipeline_run, 0, [], gate_result, [])
      end

      pipeline_run.reload
      assert_equal "paused", pipeline_run.status
      assert_equal 2, (pipeline_run.metadata["tier_retries"] || {})["0"]
    end

    # --- Post-merge hooks and verification checks ---

    test "runs post-merge hooks after merge and before gate check" do
      ArnoldPipeline.configure do |c|
        c.llm_api_key = "test"
        c.github_token = "test"
        c.github_repo = "owner/repo"
        c.claude_code_repo_path = "/tmp/test_repo"
        c.post_merge_hooks = [
          { name: "lint", trigger_paths: ["*.rb"], command: "rubocop" }
        ]
      end

      pipeline_run = PipelineRun.create!(nl_input: "Build an app")
      pipeline_run.tasks.create!(title: "Setup DB", position: 0, tier: 0)

      @executor.stubs(:call).returns([])
      @executor.stubs(:await_results).returns(nil)
      @executor.stubs(:merge_results).returns([])

      ArnoldPipeline::PostMergeHookRunner.stubs(:call).returns([
        { name: "lint", triggered: true, success: true, stdout: "ok", stderr: "", exit_code: 0 }
      ])

      @engine.execute_tiers!(pipeline_run)
    end

    test "skips hooks when post_merge_hooks config is empty" do
      ArnoldPipeline.configure do |c|
        c.llm_api_key = "test"
        c.github_token = "test"
        c.github_repo = "owner/repo"
        c.post_merge_hooks = []
      end

      pipeline_run = PipelineRun.create!(nl_input: "Build an app")
      pipeline_run.tasks.create!(title: "Setup DB", position: 0, tier: 0)

      @executor.stubs(:call).returns([])
      @executor.stubs(:await_results).returns(nil)
      @executor.stubs(:merge_results).returns([])

      ArnoldPipeline::PostMergeHookRunner.expects(:call).never

      @engine.execute_tiers!(pipeline_run)
    end

    test "runs verification checks after hooks and before gate check" do
      ArnoldPipeline.configure do |c|
        c.llm_api_key = "test"
        c.github_token = "test"
        c.github_repo = "owner/repo"
        c.claude_code_repo_path = "/tmp/test_repo"
        c.verification_checks = [
          { name: "boot", command: "bin/rails runner 'true'", type: :boot, required: true }
        ]
      end

      pipeline_run = PipelineRun.create!(nl_input: "Build an app")
      pipeline_run.tasks.create!(title: "Setup DB", position: 0, tier: 0)

      @executor.stubs(:call).returns([])
      @executor.stubs(:await_results).returns(nil)
      @executor.stubs(:merge_results).returns([])

      ArnoldPipeline::VerificationRunner.stubs(:call).returns({
        checks: [{ name: "boot", type: :boot, success: true }],
        all_passed: true,
        summary: "1 passed, 0 failed: boot=OK"
      })

      @engine.execute_tiers!(pipeline_run)
    end

    test "skips verification when verification_checks config is empty" do
      ArnoldPipeline.configure do |c|
        c.llm_api_key = "test"
        c.github_token = "test"
        c.github_repo = "owner/repo"
        c.verification_checks = []
      end

      pipeline_run = PipelineRun.create!(nl_input: "Build an app")
      pipeline_run.tasks.create!(title: "Setup DB", position: 0, tier: 0)

      @executor.stubs(:call).returns([])
      @executor.stubs(:await_results).returns(nil)
      @executor.stubs(:merge_results).returns([])

      ArnoldPipeline::VerificationRunner.expects(:call).never

      @engine.execute_tiers!(pipeline_run)
    end

    test "passes verification_results to tier gate check" do
      ArnoldPipeline.configure do |c|
        c.llm_api_key = "test"
        c.github_token = "test"
        c.github_repo = "owner/repo"
        c.claude_code_repo_path = "/tmp/test_repo"
        c.verification_checks = [
          { name: "boot", command: "bin/rails runner 'true'", type: :boot }
        ]
      end

      pipeline_run = PipelineRun.create!(nl_input: "Build an app")
      pipeline_run.tasks.create!(title: "Setup DB", position: 0, tier: 0)

      @executor.stubs(:call).returns([])
      @executor.stubs(:await_results).returns(nil)
      @executor.stubs(:merge_results).returns([])

      verification_results = {
        checks: [{ name: "boot", type: :boot, success: true }],
        all_passed: true,
        summary: "1 passed, 0 failed: boot=OK"
      }
      ArnoldPipeline::VerificationRunner.stubs(:call).returns(verification_results)

      captured_kwargs = nil
      @tier_gate_check.stubs(:call).with { |**kwargs|
        captured_kwargs = kwargs
        true
      }.returns({
        "pass" => true,
        "issues" => [],
        "context_summary" => "Done.",
        "corrective_tasks" => []
      })

      @engine.execute_tiers!(pipeline_run)

      assert_not_nil captured_kwargs
      assert_equal verification_results, captured_kwargs[:verification_results]
    end

    test "records post_merge_hooks PipelineEvent" do
      ArnoldPipeline.configure do |c|
        c.llm_api_key = "test"
        c.github_token = "test"
        c.github_repo = "owner/repo"
        c.claude_code_repo_path = "/tmp/test_repo"
        c.post_merge_hooks = [
          { name: "lint", trigger_paths: ["*.rb"], command: "rubocop" }
        ]
      end

      event_recorder = build_recording_event_recorder

      engine = TierExecutionEngine.new(
        executor: @executor, tier_gate_check: @tier_gate_check,
        logger: Logger.new(File::NULL), event_recorder: event_recorder
      )

      pipeline_run = PipelineRun.create!(nl_input: "Build an app")
      pipeline_run.tasks.create!(title: "Setup DB", position: 0, tier: 0)

      @executor.stubs(:call).returns([])
      @executor.stubs(:await_results).returns(nil)
      @executor.stubs(:merge_results).returns([])

      ArnoldPipeline::PostMergeHookRunner.stubs(:call).returns([
        { name: "lint", triggered: true, success: true, stdout: "ok", stderr: "", exit_code: 0 }
      ])

      engine.execute_tiers!(pipeline_run)

      hook_event = event_recorder.events.find { |e| e[:event_type] == :post_merge_hooks }
      assert_not_nil hook_event, "Expected a post_merge_hooks event to be recorded"
      assert_equal "execution", hook_event[:stage]

      summary = hook_event[:summary]
      assert_equal 1, summary[:hook_count]
      assert_equal 1, summary[:triggered_count]
      assert_equal 1, summary[:success_count]
      assert_equal 0, summary[:results].first[:exit_code]
      assert_equal true, summary[:results].first[:triggered]

      payload = hook_event[:payload]
      assert_not_nil payload[:changed_files]
      assert_equal "ok", payload[:results].first[:stdout]
    end

    test "records verification_checks PipelineEvent" do
      ArnoldPipeline.configure do |c|
        c.llm_api_key = "test"
        c.github_token = "test"
        c.github_repo = "owner/repo"
        c.claude_code_repo_path = "/tmp/test_repo"
        c.verification_checks = [
          { name: "boot", command: "bin/rails runner 'true'", type: :boot }
        ]
      end

      event_recorder = build_recording_event_recorder

      engine = TierExecutionEngine.new(
        executor: @executor, tier_gate_check: @tier_gate_check,
        logger: Logger.new(File::NULL), event_recorder: event_recorder
      )

      pipeline_run = PipelineRun.create!(nl_input: "Build an app")
      pipeline_run.tasks.create!(title: "Setup DB", position: 0, tier: 0)

      @executor.stubs(:call).returns([])
      @executor.stubs(:await_results).returns(nil)
      @executor.stubs(:merge_results).returns([])

      ArnoldPipeline::VerificationRunner.stubs(:call).returns({
        checks: [{ name: "boot", type: :boot, success: true }],
        all_passed: true,
        summary: "1 passed, 0 failed: boot=OK"
      })

      engine.execute_tiers!(pipeline_run)

      check_event = event_recorder.events.find { |e| e[:event_type] == :verification_checks }
      assert_not_nil check_event, "Expected a verification_checks event to be recorded"
      assert_equal "execution", check_event[:stage]
      assert_equal true, check_event[:summary][:all_passed]
    end

    test "non-fatal: hook runner failure does not crash pipeline" do
      ArnoldPipeline.configure do |c|
        c.llm_api_key = "test"
        c.github_token = "test"
        c.github_repo = "owner/repo"
        c.claude_code_repo_path = "/tmp/test_repo"
        c.post_merge_hooks = [
          { name: "lint", trigger_paths: ["*.rb"], command: "rubocop" }
        ]
      end

      pipeline_run = PipelineRun.create!(nl_input: "Build an app")
      pipeline_run.tasks.create!(title: "Setup DB", position: 0, tier: 0)

      @executor.stubs(:call).returns([])
      @executor.stubs(:await_results).returns(nil)
      @executor.stubs(:merge_results).returns([])

      ArnoldPipeline::PostMergeHookRunner.stubs(:call).raises(RuntimeError, "hook explosion")

      assert_nothing_raised do
        @engine.execute_tiers!(pipeline_run)
      end
    end

    test "non-fatal: verification runner failure does not crash pipeline" do
      ArnoldPipeline.configure do |c|
        c.llm_api_key = "test"
        c.github_token = "test"
        c.github_repo = "owner/repo"
        c.claude_code_repo_path = "/tmp/test_repo"
        c.verification_checks = [
          { name: "boot", command: "bin/rails runner 'true'", type: :boot }
        ]
      end

      pipeline_run = PipelineRun.create!(nl_input: "Build an app")
      pipeline_run.tasks.create!(title: "Setup DB", position: 0, tier: 0)

      @executor.stubs(:call).returns([])
      @executor.stubs(:await_results).returns(nil)
      @executor.stubs(:merge_results).returns([])

      ArnoldPipeline::VerificationRunner.stubs(:call).raises(RuntimeError, "check explosion")

      assert_nothing_raised do
        @engine.execute_tiers!(pipeline_run)
      end
    end

    # --- collect_changed_files ---

    test "collect_changed_files extracts filenames from JSON result_diff" do
      pipeline_run = PipelineRun.create!(nl_input: "Build an app")
      task = pipeline_run.tasks.create!(
        title: "Setup DB", position: 0, tier: 0,
        result_diff: '[{"filename":"Gemfile","patch":"+ gem rails","status":"modified"},{"filename":"app/models/user.rb","patch":"+ class User","status":"added"}]'
      )

      files = @engine.send(:collect_changed_files, [task])
      assert_includes files, "Gemfile"
      assert_includes files, "app/models/user.rb"
      assert_equal 2, files.size
    end

    test "collect_changed_files returns empty array for empty diff" do
      pipeline_run = PipelineRun.create!(nl_input: "Build an app")
      task = pipeline_run.tasks.create!(
        title: "Setup DB", position: 0, tier: 0,
        result_diff: "[]"
      )

      files = @engine.send(:collect_changed_files, [task])
      assert_equal [], files
    end

    test "collect_changed_files deduplicates across tasks" do
      pipeline_run = PipelineRun.create!(nl_input: "Build an app")
      task1 = pipeline_run.tasks.create!(
        title: "Setup DB", position: 0, tier: 0,
        result_diff: '[{"filename":"Gemfile","patch":"+","status":"modified"}]'
      )
      task2 = pipeline_run.tasks.create!(
        title: "Add routes", position: 1, tier: 0,
        result_diff: '[{"filename":"Gemfile","patch":"+","status":"modified"},{"filename":"config/routes.rb","patch":"+","status":"added"}]'
      )

      files = @engine.send(:collect_changed_files, [task1, task2])
      assert_equal 2, files.size
      assert_includes files, "Gemfile"
      assert_includes files, "config/routes.rb"
    end

    # --- build_corrective_description ---

    test "build_corrective_description includes gate issues" do
      desc = @engine.send(:build_corrective_description,
        base_description: "Fix the routes",
        gate_issues: ["Missing root route", "No health check endpoint"],
        original_tier_tasks: [],
        acceptance_criteria_summary: nil
      )

      assert_includes desc, "Fix the routes"
      assert_includes desc, "## Gate Issues"
      assert_includes desc, "1. Missing root route"
      assert_includes desc, "2. No health check endpoint"
    end

    test "build_corrective_description includes original task context with diff annotations" do
      pipeline_run = PipelineRun.create!(nl_input: "Build an app")
      task_with_diffs = pipeline_run.tasks.create!(
        title: "Setup DB", description: "Create database schema", position: 0, tier: 0,
        result_diff: '[{"filename":"schema.rb","patch":"+ create_table"}]'
      )
      task_without_diffs = pipeline_run.tasks.create!(
        title: "Add Routes", description: "Configure routing", position: 1, tier: 0,
        result_diff: "[]"
      )

      desc = @engine.send(:build_corrective_description,
        base_description: "Fix routing",
        gate_issues: [],
        original_tier_tasks: [task_with_diffs, task_without_diffs],
        acceptance_criteria_summary: nil
      )

      assert_includes desc, "## Original Tier Tasks"
      assert_includes desc, "Setup DB: Create database schema [produced diffs]"
      assert_includes desc, "Add Routes: Configure routing [NO DIFFS]"
    end

    test "build_corrective_description includes acceptance criteria summary" do
      criteria_summary = "**Failed (programmatic — these are NOT satisfied):**\n- [FAIL] Health check route (route_exists)"

      desc = @engine.send(:build_corrective_description,
        base_description: "Fix health check",
        gate_issues: [],
        original_tier_tasks: [],
        acceptance_criteria_summary: criteria_summary
      )

      assert_includes desc, "## Acceptance Criteria Status"
      assert_includes desc, "[FAIL] Health check route (route_exists)"
    end

    test "build_corrective_description returns base description only when no context" do
      desc = @engine.send(:build_corrective_description,
        base_description: "Fix the routes",
        gate_issues: [],
        original_tier_tasks: [],
        acceptance_criteria_summary: nil
      )

      assert_equal "Fix the routes", desc
    end

    test "handle_tier_gate_failure! creates tasks with enriched descriptions" do
      ArnoldPipeline.configure do |c|
        c.max_iterations = 3
        c.max_tier_retries = 1
        c.tier_gate_enabled = true
        c.llm_api_key = "test"
        c.github_token = "test"
        c.github_repo = "owner/repo"
      end

      pipeline_run = PipelineRun.create!(nl_input: "Build an app")
      original_task = pipeline_run.tasks.create!(
        title: "Setup DB", description: "Create schema", position: 0, tier: 0,
        result_diff: '[{"filename":"schema.rb"}]'
      )

      gate_fail = {
        "pass" => false,
        "issues" => ["Missing root route redirect"],
        "corrective_tasks" => [
          { "title" => "Add root route", "description" => "Add root route redirect" }
        ],
        "context_summary" => "DB schema created, routes missing"
      }
      gate_pass = { "pass" => true, "issues" => [], "context_summary" => "All good.", "corrective_tasks" => [] }

      @executor.stubs(:call).returns([])
      @executor.stubs(:await_results).returns(nil)
      @executor.stubs(:merge_results).returns([])
      @tier_gate_check.stubs(:call).returns(gate_pass)

      criteria_summary = "**Failed:**\n- [FAIL] Root route (route_exists)"

      @engine.send(:handle_tier_gate_failure!, pipeline_run, 0, [original_task], gate_fail, [],
                   acceptance_criteria_summary: criteria_summary)

      corrective = pipeline_run.tasks.where(title: "Add root route").first
      assert_not_nil corrective
      assert_includes corrective.description, "Add root route redirect"
      assert_includes corrective.description, "## Gate Issues"
      assert_includes corrective.description, "Missing root route redirect"
      assert_includes corrective.description, "## Original Tier Tasks"
      assert_includes corrective.description, "Setup DB: Create schema [produced diffs]"
      assert_includes corrective.description, "## Acceptance Criteria Status"
      assert_includes corrective.description, "[FAIL] Root route (route_exists)"
    end

    test "handle_tier_gate_failure! includes current tier context in prior_context" do
      ArnoldPipeline.configure do |c|
        c.max_iterations = 3
        c.max_tier_retries = 1
        c.tier_gate_enabled = true
        c.llm_api_key = "test"
        c.github_token = "test"
        c.github_repo = "owner/repo"
      end

      pipeline_run = PipelineRun.create!(nl_input: "Build an app")
      pipeline_run.tasks.create!(title: "Setup DB", position: 0, tier: 0)

      gate_fail = {
        "pass" => false,
        "issues" => ["missing files"],
        "corrective_tasks" => [
          { "title" => "Fix files", "description" => "add missing files" }
        ],
        "context_summary" => "DB schema and models created, routes file exists"
      }
      gate_pass = { "pass" => true, "issues" => [], "context_summary" => "All good.", "corrective_tasks" => [] }

      # Capture prior_context passed to executor.call for the corrective task
      captured_prior_context = nil
      @executor.stubs(:call).with { |prior_context:, **|
        captured_prior_context = prior_context
        true
      }.returns([])
      @executor.stubs(:await_results).returns(nil)
      @executor.stubs(:merge_results).returns([])
      @tier_gate_check.stubs(:call).returns(gate_pass)

      # Pass empty accumulated_context — current tier context should still be included
      @engine.send(:handle_tier_gate_failure!, pipeline_run, 0, [], gate_fail, [])

      assert_not_nil captured_prior_context, "prior_context should be passed to executor"
      assert_includes captured_prior_context, "DB schema and models created, routes file exists"
      assert_includes captured_prior_context, "Tier 0 completed:"
    end

    test "handle_tier_gate_failure! pauses from executing with sync provider" do
      ArnoldPipeline.configure do |c|
        c.max_iterations = 3
        c.max_tier_retries = 1
        c.tier_gate_enabled = true
        c.llm_api_key = "test"
        c.github_token = "test"
        c.github_repo = "owner/repo"
      end

      @provider.stubs(:async?).returns(false)

      pipeline_run = PipelineRun.create!(nl_input: "Build an app")
      pipeline_run.tasks.create!(title: "Setup DB", position: 0, tier: 0)

      @executor.stubs(:call).returns([])
      @executor.stubs(:fetch_results).returns([])
      @executor.stubs(:merge_results).returns([])

      gate_result = {
        "pass" => false,
        "issues" => ["compile error"],
        "corrective_tasks" => [{ "title" => "Fix compile", "description" => "fix" }],
        "context_summary" => "context"
      }
      @tier_gate_check.stubs(:call).returns(gate_result)

      assert_raises(TierGateError) do
        @engine.send(:handle_tier_gate_failure!, pipeline_run, 0, [], gate_result, [])
      end

      pipeline_run.reload
      assert_equal "paused", pipeline_run.status
    end

    private

    def build_recording_event_recorder
      recorder = Object.new
      recorder.instance_variable_set(:@events, [])

      def recorder.events
        @events
      end

      def recorder.record(**kwargs)
        @events << kwargs
      end

      def recorder.timed(**kwargs, &block)
        result = block.call
        summary_val = kwargs[:summary]
        resolved_summary = summary_val.is_a?(Proc) ? summary_val.call(result) : summary_val
        payload_val = kwargs[:payload]
        resolved_payload = payload_val.is_a?(Proc) ? payload_val.call(result) : payload_val
        @events << kwargs.merge(summary: resolved_summary, payload: resolved_payload)
        result
      end

      recorder
    end
  end
end

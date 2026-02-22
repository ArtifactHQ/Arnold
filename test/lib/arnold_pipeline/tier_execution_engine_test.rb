require "test_helper"
require "octokit"
require "faraday"
require "arnold_pipeline/tier_execution_engine"
require "arnold_pipeline/corrective_task_generator"
require "arnold_pipeline/pipeline_event_recorder"

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

    test "handle_tier_gate_failure! runs post-merge hooks after each corrective task merge" do
      ArnoldPipeline.configure do |c|
        c.max_iterations = 3
        c.max_tier_retries = 1
        c.tier_gate_enabled = true
        c.llm_api_key = "test"
        c.github_token = "test"
        c.github_repo = "owner/repo"
        c.claude_code_repo_path = "/tmp/test-repo"
        c.post_merge_hooks = [
          { name: "schema", trigger_paths: ["db/migrate/**"], command: "bin/rails db:prepare" }
        ]
      end

      pipeline_run = PipelineRun.create!(nl_input: "Build an app")
      pipeline_run.tasks.create!(title: "Setup DB", position: 0, tier: 0)

      gate_fail = {
        "pass" => false,
        "issues" => ["migration conflict"],
        "corrective_tasks" => [
          { "title" => "Fix migration", "description" => "remove duplicate migration" }
        ],
        "context_summary" => "context"
      }
      gate_pass = { "pass" => true, "issues" => [], "context_summary" => "Fixed.", "corrective_tasks" => [] }

      @executor.stubs(:call).returns([])
      @executor.stubs(:await_results).returns(nil)
      @executor.stubs(:merge_results).returns([])
      @tier_gate_check.stubs(:call).returns(gate_pass)

      # Expect post-merge hooks to be called after corrective task merge
      hook_call_count = 0
      ArnoldPipeline::PostMergeHookRunner.stubs(:call).with { |**kwargs|
        hook_call_count += 1
        true
      }.returns([])

      @engine.send(:handle_tier_gate_failure!, pipeline_run, 0, [], gate_fail, [])

      assert_equal 1, hook_call_count, "Post-merge hooks should run once per corrective task merge"
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

    # --- Empirical verification path tests ---

    test "empirical path: passes gate when test suite passes" do
      pipeline_run = PipelineRun.create!(nl_input: "Build an app")
      task = pipeline_run.tasks.create!(
        title: "Setup DB", position: 0, tier: 0, description: "Create database",
        external_id: "42", result_diff: '[{"filename":"schema.rb"}]'
      )

      verification_results = {
        checks: [
          { name: "tests", type: :test_suite, success: true, stdout: "5 runs, 5 assertions, 0 failures, 0 errors", stderr: "", exit_code: 0 }
        ],
        all_passed: true,
        summary: "1 passed"
      }

      result = @engine.send(:run_tier_gate!, pipeline_run, 0, [task],
                            verification_results: verification_results)

      assert result["pass"], "Gate should pass when test suite passes"
      assert_empty result["issues"]
      assert_empty result["corrective_tasks"]
      assert_includes result["context_summary"], "Verification checks all passed"
    end

    test "empirical path: passes gate despite criteria_check failures when tests pass" do
      pipeline_run = PipelineRun.create!(nl_input: "Build an app")
      task = pipeline_run.tasks.create!(
        title: "Setup DB", position: 0, tier: 0, description: "Create database",
        external_id: "42", result_diff: '[{"filename":"schema.rb"}]'
      )

      verification_results = {
        checks: [
          { name: "tests", type: :test_suite, success: true, stdout: "5 runs, 5 assertions, 0 failures, 0 errors", stderr: "", exit_code: 0 }
        ],
        all_passed: true,
        summary: "1 passed"
      }

      criteria_summary = "**Failed:**\n- [FAIL] Missing route (route_exists)"

      result = @engine.send(:run_tier_gate!, pipeline_run, 0, [task],
                            verification_results: verification_results,
                            acceptance_criteria_summary: criteria_summary)

      assert result["pass"], "Gate should pass even with criteria failures when tests pass"
      assert_includes result["context_summary"], "Criteria check (advisory)"
      assert_includes result["context_summary"], "Missing route"
    end

    test "empirical path: fails gate when test suite fails" do
      pipeline_run = PipelineRun.create!(nl_input: "Build an app")
      task = pipeline_run.tasks.create!(
        title: "Setup DB", position: 0, tier: 0, description: "Create database",
        external_id: "42", result_diff: '[{"filename":"schema.rb"}]'
      )

      verification_results = {
        checks: [
          { name: "tests", type: :test_suite, success: false,
            stdout: "3 runs, 3 assertions, 2 failures, 0 errors\n\n1) Failure:\nUserTest#test_valid [test/models/user_test.rb:10]:\nExpected true, got false",
            stderr: "", exit_code: 1 }
        ],
        all_passed: false,
        summary: "0 passed, 1 failed"
      }

      ArnoldPipeline::CorrectiveTaskGenerator.stubs(:call).returns([
        { "title" => "Fix user validation", "description" => "Fix the user model", "labels" => ["unit-fix"] }
      ])

      result = @engine.send(:run_tier_gate!, pipeline_run, 0, [task],
                            verification_results: verification_results)

      refute result["pass"], "Gate should fail when test suite fails"
      assert result["issues"].any?, "Should have issues"
      assert result["corrective_tasks"].any?, "Should have corrective tasks"
      assert_equal "Fix user validation", result["corrective_tasks"].first["title"]
    end

    test "empirical path: generates corrective tasks from test failures" do
      pipeline_run = PipelineRun.create!(nl_input: "Build an app")
      task = pipeline_run.tasks.create!(
        title: "Setup DB", position: 0, tier: 0, description: "Create database",
        external_id: "42", result_diff: '[{"filename":"schema.rb"}]'
      )

      verification_results = {
        checks: [
          { name: "tests", type: :test_suite, success: false,
            stdout: "3 runs, 3 assertions, 1 failures, 0 errors",
            stderr: "", exit_code: 1 }
        ],
        all_passed: false,
        summary: "0 passed, 1 failed"
      }

      # Verify CorrectiveTaskGenerator is called with parsed test_result
      captured_test_result = nil
      ArnoldPipeline::CorrectiveTaskGenerator.stubs(:call).with { |test_result:, **|
        captured_test_result = test_result
        true
      }.returns([{ "title" => "Fix test", "description" => "Fix it", "labels" => ["bugfix"] }])

      @engine.send(:run_tier_gate!, pipeline_run, 0, [task],
                   verification_results: verification_results)

      assert_not_nil captured_test_result, "CorrectiveTaskGenerator should be called with a test_result"
      assert_kind_of ArnoldPipeline::TestExecution::TestResult, captured_test_result
    end

    test "empirical path: fails gate when required boot check fails" do
      pipeline_run = PipelineRun.create!(nl_input: "Build an app")
      task = pipeline_run.tasks.create!(
        title: "Setup DB", position: 0, tier: 0, description: "Create database",
        external_id: "42", result_diff: '[{"filename":"schema.rb"}]'
      )

      verification_results = {
        checks: [
          { name: "boot", type: :boot, success: false, required: true,
            stdout: "", stderr: "LoadError: cannot load such file", exit_code: 1 },
          { name: "tests", type: :test_suite, success: false,
            stdout: "", stderr: "", exit_code: 1 }
        ],
        all_passed: false,
        summary: "0 passed, 2 failed"
      }

      result = @engine.send(:run_tier_gate!, pipeline_run, 0, [task],
                            verification_results: verification_results)

      refute result["pass"], "Gate should fail when required check fails"
      assert result["issues"].any? { |i| i.include?("boot") }, "Issues should mention the failed check"
    end

    test "empirical path: generates boot fix task when boot check fails" do
      pipeline_run = PipelineRun.create!(nl_input: "Build an app")
      task = pipeline_run.tasks.create!(
        title: "Setup DB", position: 0, tier: 0, description: "Create database",
        external_id: "42", result_diff: '[{"filename":"schema.rb"}]'
      )

      verification_results = {
        checks: [
          { name: "boot", type: :boot, success: false, required: true,
            stdout: "", stderr: "LoadError: cannot load file", exit_code: 1 },
          { name: "tests", type: :test_suite, success: false,
            stdout: "", stderr: "", exit_code: 1 }
        ],
        all_passed: false,
        summary: "0 passed, 2 failed"
      }

      result = @engine.send(:run_tier_gate!, pipeline_run, 0, [task],
                            verification_results: verification_results)

      boot_task = result["corrective_tasks"].first
      assert_not_nil boot_task, "Should have a corrective task"
      assert_equal "Fix application boot failure", boot_task["title"]
      assert_includes boot_task["labels"], "boot-fix"
      assert_includes boot_task["description"], "cannot load file"
    end

    # --- Fallback LLM path tests ---

    test "fallback path: falls back to LLM judgment when no verification results" do
      pipeline_run = PipelineRun.create!(nl_input: "Build an app")
      task = pipeline_run.tasks.create!(
        title: "Setup DB", position: 0, tier: 0, description: "Create database",
        external_id: "42", result_diff: '[{"filename":"schema.rb"}]'
      )

      @tier_gate_check.expects(:call).once.returns({
        "pass" => true, "issues" => [], "context_summary" => "Done.", "corrective_tasks" => []
      })

      result = @engine.send(:run_tier_gate!, pipeline_run, 0, [task],
                            verification_results: nil)

      assert result["pass"]
    end

    test "fallback path: falls back to LLM judgment when no test_suite type check present" do
      pipeline_run = PipelineRun.create!(nl_input: "Build an app")
      task = pipeline_run.tasks.create!(
        title: "Setup DB", position: 0, tier: 0, description: "Create database",
        external_id: "42", result_diff: '[{"filename":"schema.rb"}]'
      )

      # Verification results with only a boot check (no test_suite)
      verification_results = {
        checks: [
          { name: "boot", type: :boot, success: true, required: true }
        ],
        all_passed: true,
        summary: "1 passed"
      }

      @tier_gate_check.expects(:call).once.returns({
        "pass" => true, "issues" => [], "context_summary" => "Done.", "corrective_tasks" => []
      })

      result = @engine.send(:run_tier_gate!, pipeline_run, 0, [task],
                            verification_results: verification_results)

      assert result["pass"]
    end

    # --- Decision source tracking ---

    test "records decision_source verification_tests_passed in event" do
      event_recorder = build_recording_event_recorder

      engine = TierExecutionEngine.new(
        executor: @executor, tier_gate_check: @tier_gate_check,
        logger: Logger.new(File::NULL), event_recorder: event_recorder
      )

      pipeline_run = PipelineRun.create!(nl_input: "Build an app")
      task = pipeline_run.tasks.create!(
        title: "Setup DB", position: 0, tier: 0, description: "Create database",
        external_id: "42", result_diff: '[{"filename":"schema.rb"}]'
      )

      verification_results = {
        checks: [
          { name: "tests", type: :test_suite, success: true,
            stdout: "5 runs, 5 assertions, 0 failures, 0 errors", stderr: "", exit_code: 0 }
        ],
        all_passed: true,
        summary: "1 passed"
      }

      engine.send(:run_tier_gate!, pipeline_run, 0, [task],
                  verification_results: verification_results)

      gate_event = event_recorder.events.find { |e| e[:event_type] == :tier_gate_evaluated }
      assert_not_nil gate_event
      assert_equal "verification_tests_passed", gate_event[:summary][:decision_source]
    end

    test "records decision_source verification_tests_failed in event" do
      event_recorder = build_recording_event_recorder

      engine = TierExecutionEngine.new(
        executor: @executor, tier_gate_check: @tier_gate_check,
        logger: Logger.new(File::NULL), event_recorder: event_recorder
      )

      pipeline_run = PipelineRun.create!(nl_input: "Build an app")
      task = pipeline_run.tasks.create!(
        title: "Setup DB", position: 0, tier: 0, description: "Create database",
        external_id: "42", result_diff: '[{"filename":"schema.rb"}]'
      )

      verification_results = {
        checks: [
          { name: "tests", type: :test_suite, success: false,
            stdout: "3 runs, 3 assertions, 1 failures, 0 errors", stderr: "", exit_code: 1 }
        ],
        all_passed: false,
        summary: "0 passed, 1 failed"
      }

      ArnoldPipeline::CorrectiveTaskGenerator.stubs(:call).returns([])

      engine.send(:run_tier_gate!, pipeline_run, 0, [task],
                  verification_results: verification_results)

      gate_event = event_recorder.events.find { |e| e[:event_type] == :tier_gate_evaluated }
      assert_not_nil gate_event
      assert_equal "verification_tests_failed", gate_event[:summary][:decision_source]
    end

    test "hollow test suite (0 runs) fails gate with verification_tests_hollow" do
      event_recorder = build_recording_event_recorder

      engine = TierExecutionEngine.new(
        executor: @executor, tier_gate_check: @tier_gate_check,
        logger: Logger.new(File::NULL), event_recorder: event_recorder
      )

      pipeline_run = PipelineRun.create!(nl_input: "Build an app")
      task = pipeline_run.tasks.create!(
        title: "Setup DB", position: 0, tier: 0, description: "Create database",
        external_id: "42", result_diff: '[{"filename":"schema.rb"}]'
      )

      verification_results = {
        checks: [
          { name: "tests", type: :test_suite, success: true,
            stdout: "0 runs, 0 assertions, 0 failures, 0 errors, 0 skips", stderr: "", exit_code: 0 }
        ],
        all_passed: true,
        summary: "1 passed"
      }

      result = engine.send(:run_tier_gate!, pipeline_run, 0, [task],
                  verification_results: verification_results)

      refute result["pass"], "Hollow test suite should fail the gate"
      assert result["issues"].any? { |i| i.include?("0 runs") }
      assert result["corrective_tasks"].any? { |t| t["title"].include?("0 tests loaded") }

      gate_event = event_recorder.events.find { |e| e[:event_type] == :tier_gate_evaluated }
      assert_not_nil gate_event
      assert_equal "verification_tests_hollow", gate_event[:summary][:decision_source]
    end

    test "records decision_source verification_required_failed in event" do
      event_recorder = build_recording_event_recorder

      engine = TierExecutionEngine.new(
        executor: @executor, tier_gate_check: @tier_gate_check,
        logger: Logger.new(File::NULL), event_recorder: event_recorder
      )

      pipeline_run = PipelineRun.create!(nl_input: "Build an app")
      task = pipeline_run.tasks.create!(
        title: "Setup DB", position: 0, tier: 0, description: "Create database",
        external_id: "42", result_diff: '[{"filename":"schema.rb"}]'
      )

      verification_results = {
        checks: [
          { name: "boot", type: :boot, success: false, required: true,
            stdout: "", stderr: "boot failed", exit_code: 1 },
          { name: "tests", type: :test_suite, success: false,
            stdout: "", stderr: "", exit_code: 1 }
        ],
        all_passed: false,
        summary: "0 passed, 2 failed"
      }

      engine.send(:run_tier_gate!, pipeline_run, 0, [task],
                  verification_results: verification_results)

      gate_event = event_recorder.events.find { |e| e[:event_type] == :tier_gate_evaluated }
      assert_not_nil gate_event
      assert_equal "verification_required_failed", gate_event[:summary][:decision_source]
    end

    test "records decision_source llm_judgment when no verification" do
      event_recorder = build_recording_event_recorder

      engine = TierExecutionEngine.new(
        executor: @executor, tier_gate_check: @tier_gate_check,
        logger: Logger.new(File::NULL), event_recorder: event_recorder
      )

      pipeline_run = PipelineRun.create!(nl_input: "Build an app")
      task = pipeline_run.tasks.create!(
        title: "Setup DB", position: 0, tier: 0, description: "Create database",
        external_id: "42", result_diff: '[{"filename":"schema.rb"}]'
      )

      @tier_gate_check.stubs(:call).returns({
        "pass" => true, "issues" => [], "context_summary" => "Done.", "corrective_tasks" => []
      })

      engine.send(:run_tier_gate!, pipeline_run, 0, [task],
                  verification_results: nil)

      gate_event = event_recorder.events.find { |e| e[:event_type] == :tier_gate_evaluated }
      assert_not_nil gate_event
      assert_equal "llm_judgment", gate_event[:summary][:decision_source]
    end

    # --- Criteria check mode ---

    test "skips criteria check when criteria_check_mode is disabled" do
      ArnoldPipeline.configure do |c|
        c.llm_api_key = "test"
        c.github_token = "test"
        c.github_repo = "owner/repo"
        c.claude_code_repo_path = File.expand_path("../../..", __dir__)
        c.criteria_check_mode = :disabled
      end

      pipeline_run = PipelineRun.create!(nl_input: "Build an app")
      task = pipeline_run.tasks.create!(
        title: "Setup DB", position: 0, tier: 0,
        acceptance_criteria: [
          { "type" => "file_exists", "description" => "Gemfile exists", "path" => "Gemfile" }
        ]
      )

      ArnoldPipeline::CriteriaChecker.expects(:call).never

      result = @engine.send(:run_criteria_check!, pipeline_run, [task])
      assert_nil result
    end

    test "runs criteria check in advisory mode" do
      ArnoldPipeline.configure do |c|
        c.llm_api_key = "test"
        c.github_token = "test"
        c.github_repo = "owner/repo"
        c.claude_code_repo_path = File.expand_path("../../..", __dir__)
        c.criteria_check_mode = :advisory
      end

      pipeline_run = PipelineRun.create!(nl_input: "Build an app")
      task = pipeline_run.tasks.create!(
        title: "Setup DB", position: 0, tier: 0,
        acceptance_criteria: [
          { "type" => "file_exists", "description" => "Gemfile exists", "path" => "Gemfile" }
        ]
      )

      verified = ArnoldPipeline::AcceptanceCriterion.new(type: "file_exists", description: "Gemfile exists", params: {})
      ArnoldPipeline::CriteriaChecker.expects(:call).once.returns({
        verified: [verified], failed: [], unverified: []
      })

      result = @engine.send(:run_criteria_check!, pipeline_run, [task])
      assert_not_nil result
    end

    # --- tier_number on validation events ---

    test "post_merge_hooks event includes tier_number" do
      pipeline_run = PipelineRun.create!(nl_input: "Build an app", status: :pending)
      task = pipeline_run.tasks.create!(title: "Setup", position: 0, tier: 0, external_id: "1",
        result_diff: '[{"filename":"Gemfile"}]')

      event_recorder = build_recording_event_recorder
      engine = TierExecutionEngine.new(
        executor: @executor, tier_gate_check: @tier_gate_check,
        logger: Logger.new(File::NULL), event_recorder: event_recorder
      )

      ArnoldPipeline.configure do |c|
        c.claude_code_repo_path = "/tmp/test-repo"
        c.post_merge_hooks = [{ "name" => "test", "trigger_paths" => ["Gemfile"], "command" => "echo ok" }]
      end

      ArnoldPipeline::PostMergeHookRunner.stubs(:call).returns([
        { name: "test", triggered: true, success: true, exit_code: 0 }
      ])

      engine.send(:run_post_merge_hooks, [task], 2)
      event = event_recorder.events.find { |e| e[:event_type] == :post_merge_hooks }
      assert_not_nil event, "Expected a post_merge_hooks event"
      assert_equal 2, event[:tier_number]
    end

    test "verification_checks event includes tier_number" do
      ArnoldPipeline.configure do |c|
        c.claude_code_repo_path = "/tmp/test-repo"
        c.verification_checks = [
          { name: "boot", command: "bin/rails runner 'true'", type: :boot }
        ]
      end

      event_recorder = build_recording_event_recorder
      engine = TierExecutionEngine.new(
        executor: @executor, tier_gate_check: @tier_gate_check,
        logger: Logger.new(File::NULL), event_recorder: event_recorder
      )

      ArnoldPipeline::VerificationRunner.stubs(:call).returns({
        checks: [{ name: "boot", type: :boot, success: true }],
        all_passed: true,
        summary: "1 passed, 0 failed: boot=OK"
      })

      engine.send(:run_verification_checks, 3)
      event = event_recorder.events.find { |e| e[:event_type] == :verification_checks }
      assert_not_nil event, "Expected a verification_checks event"
      assert_equal 3, event[:tier_number]
    end

    test "criteria_check event includes tier_number" do
      ArnoldPipeline.configure do |c|
        c.llm_api_key = "test"
        c.github_token = "test"
        c.github_repo = "owner/repo"
        c.claude_code_repo_path = File.expand_path("../../..", __dir__)
        c.tier_gate_enabled = true
        c.criteria_check_mode = :advisory
      end

      event_recorder = build_recording_event_recorder
      engine = TierExecutionEngine.new(
        executor: @executor, tier_gate_check: @tier_gate_check,
        logger: Logger.new(File::NULL), event_recorder: event_recorder
      )

      pipeline_run = PipelineRun.create!(nl_input: "Build an app")
      task = pipeline_run.tasks.create!(
        title: "Setup DB", position: 0, tier: 0,
        acceptance_criteria: [
          { "type" => "file_exists", "description" => "Gemfile exists", "path" => "Gemfile" }
        ]
      )

      verified = ArnoldPipeline::AcceptanceCriterion.new(type: "file_exists", description: "Gemfile exists", params: {})
      ArnoldPipeline::CriteriaChecker.stubs(:call).returns({
        verified: [verified], failed: [], unverified: []
      })

      engine.send(:run_criteria_check!, pipeline_run, [task], 5)
      event = event_recorder.events.find { |e| e[:event_type] == :criteria_check }
      assert_not_nil event, "Expected a criteria_check event"
      assert_equal 5, event[:tier_number]
    end

    test "repo_context_scanned event includes tier_number" do
      ArnoldPipeline.configure do |c|
        c.claude_code_repo_path = File.expand_path("../../..", __dir__)
      end

      event_recorder = build_recording_event_recorder
      engine = TierExecutionEngine.new(
        executor: @executor, tier_gate_check: @tier_gate_check,
        logger: Logger.new(File::NULL), event_recorder: event_recorder
      )

      pipeline_run = PipelineRun.create!(nl_input: "Build an app")

      engine.send(:build_repo_context, pipeline_run, 4)
      event = event_recorder.events.find { |e| e[:event_type] == :repo_context_scanned }
      assert_not_nil event, "Expected a repo_context_scanned event"
      assert_equal 4, event[:tier_number]
    end

    test "spec_test_execution generation event includes tier_number" do
      ArnoldPipeline.configure do |c|
        c.claude_code_repo_path = Dir.mktmpdir
        c.spec_test_generation_enabled = true
        c.spec_test_directory = "test/spec_scenarios"
      end

      event_recorder = build_recording_event_recorder
      engine = TierExecutionEngine.new(
        executor: @executor, tier_gate_check: @tier_gate_check,
        logger: Logger.new(File::NULL), event_recorder: event_recorder
      )

      pipeline_run = PipelineRun.create!(nl_input: "Build an app")
      pipeline_run.create_specification!(content: "# Test Spec\n## Purpose\nTest app")

      require "arnold_pipeline/agents/spec_test_generator"
      ArnoldPipeline::Agents::SpecTestGenerator.any_instance.stubs(:call).returns({
        "test_files" => [{ "path" => "test/spec_scenarios/test_basic.rb", "content" => "# test" }]
      })
      progress_stub = Data.define(:total_tests, :total_passing, :pass_rate, :still_failing, :newly_passing, :regressions)
      ArnoldPipeline::SpecTestProgressTracker.stubs(:call).returns(
        progress_stub.new(total_tests: 1, total_passing: 0, pass_rate: 0, still_failing: ["test_basic"], newly_passing: [], regressions: [])
      )

      engine.send(:run_spec_test_generation!, pipeline_run, 0)
      event = event_recorder.events.find { |e| e[:event_type] == :spec_test_execution && e[:summary][:phase] == "generation" }
      assert_not_nil event, "Expected a spec_test_execution generation event"
      assert_equal 0, event[:tier_number]
    ensure
      FileUtils.rm_rf(ArnoldPipeline.configuration.claude_code_repo_path)
    end

    test "spec_test_execution progress event includes tier_number" do
      tmpdir = Dir.mktmpdir
      test_dir = File.join(tmpdir, "test/spec_scenarios")
      FileUtils.mkdir_p(test_dir)
      File.write(File.join(test_dir, "test_basic.rb"), "# test")

      ArnoldPipeline.configure do |c|
        c.claude_code_repo_path = tmpdir
        c.spec_test_generation_enabled = true
        c.spec_test_directory = "test/spec_scenarios"
      end

      event_recorder = build_recording_event_recorder
      engine = TierExecutionEngine.new(
        executor: @executor, tier_gate_check: @tier_gate_check,
        logger: Logger.new(File::NULL), event_recorder: event_recorder
      )

      pipeline_run = PipelineRun.create!(nl_input: "Build an app")

      progress_stub = Data.define(:total_tests, :total_passing, :pass_rate, :still_failing, :newly_passing, :regressions, :to_gate_summary)
      ArnoldPipeline::SpecTestProgressTracker.stubs(:call).returns(
        progress_stub.new(
          total_tests: 2, total_passing: 1, pass_rate: 50,
          still_failing: ["test_a"], newly_passing: ["test_b"], regressions: [],
          to_gate_summary: "1/2 passing (50%)"
        )
      )

      engine.send(:run_spec_test_progress!, pipeline_run, 3)
      event = event_recorder.events.find { |e| e[:event_type] == :spec_test_execution && e[:summary][:phase] == "progress_check" }
      assert_not_nil event, "Expected a spec_test_execution progress event"
      assert_equal 3, event[:tier_number]
    ensure
      FileUtils.rm_rf(tmpdir)
    end

    # --- Per-task outcomes in tier_execution_completed ---

    test "tier_execution_completed includes per-task outcomes with failure reasons" do
      pipeline_run = PipelineRun.create!(nl_input: "Build an app", status: :pending)
      task1 = pipeline_run.tasks.create!(title: "Setup DB", position: 0, tier: 0, external_id: "1",
        result_diff: '[{"filename":"schema.rb"}]', status: :completed)
      task2 = pipeline_run.tasks.create!(title: "Add API", position: 1, tier: 0, external_id: "2",
        result_diff: "[]", status: :failed)
      task3 = pipeline_run.tasks.create!(title: "Bad Task", position: 2, tier: 0, external_id: "3",
        result_diff: '[{"filename":"app.rb"}]', status: :failed)

      event_recorder = build_recording_event_recorder
      engine = TierExecutionEngine.new(
        executor: @executor, tier_gate_check: @tier_gate_check,
        logger: Logger.new(File::NULL), event_recorder: event_recorder
      )

      tier_tasks = [task1, task2, task3]
      resolved = tier_tasks.count { |t| engine.tier_task_resolved?(t) }
      failed = tier_tasks.count(&:failed?)

      event_recorder.record(
        event_type: :tier_execution_completed, stage: "execution",
        summary: {
          tier_number: 0,
          resolved_count: resolved,
          failed_count: failed,
          task_outcomes: tier_tasks.map { |t|
            outcome = { title: t.title, status: t.status }
            outcome[:failure_reason] = engine.send(:task_failure_reason, t) if t.failed?
            outcome
          }
        },
        tier_number: 0
      )

      event = event_recorder.events.find { |e| e[:event_type] == :tier_execution_completed }
      outcomes = event[:summary][:task_outcomes]
      assert_equal 3, outcomes.size

      setup_outcome = outcomes.find { |o| o[:title] == "Setup DB" }
      assert_equal "completed", setup_outcome[:status]
      assert_nil setup_outcome[:failure_reason]

      api_outcome = outcomes.find { |o| o[:title] == "Add API" }
      assert_equal "failed", api_outcome[:status]
      assert_equal "empty_diff", api_outcome[:failure_reason]

      bad_outcome = outcomes.find { |o| o[:title] == "Bad Task" }
      assert_equal "failed", bad_outcome[:status]
      assert_equal "execution_error", bad_outcome[:failure_reason]
    end

    test "task_failure_reason returns nil for non-failed tasks" do
      pipeline_run = PipelineRun.create!(nl_input: "Build an app")
      task = pipeline_run.tasks.create!(title: "Setup", position: 0, status: :completed)

      assert_nil @engine.send(:task_failure_reason, task)
    end

    test "task_failure_reason returns empty_diff for failed task with no diff" do
      pipeline_run = PipelineRun.create!(nl_input: "Build an app")
      task = pipeline_run.tasks.create!(title: "Fail", position: 0, status: :failed, result_diff: nil)

      assert_equal "empty_diff", @engine.send(:task_failure_reason, task)
    end

    test "task_failure_reason returns empty_diff for failed task with empty array diff" do
      pipeline_run = PipelineRun.create!(nl_input: "Build an app")
      task = pipeline_run.tasks.create!(title: "Fail", position: 0, status: :failed, result_diff: "[]")

      assert_equal "empty_diff", @engine.send(:task_failure_reason, task)
    end

    test "task_failure_reason returns execution_error for failed task with diffs" do
      pipeline_run = PipelineRun.create!(nl_input: "Build an app")
      task = pipeline_run.tasks.create!(title: "Fail", position: 0, status: :failed,
        result_diff: '[{"filename":"app.rb"}]')

      assert_equal "execution_error", @engine.send(:task_failure_reason, task)
    end

    test "task_failure_reason returns merge_failed for failed task with merge error comment" do
      pipeline_run = PipelineRun.create!(nl_input: "Build an app")
      task = pipeline_run.tasks.create!(
        title: "Merge Fail", position: 0, status: :failed, result_diff: "[]",
        result_comments: [{ "source" => "arnold", "author" => "system", "body" => "Merge failed: Your local changes would be overwritten" }]
      )

      assert_equal "merge_failed", @engine.send(:task_failure_reason, task)
    end

    test "task_failure_reason returns empty_diff for failed task with non-merge comments" do
      pipeline_run = PipelineRun.create!(nl_input: "Build an app")
      task = pipeline_run.tasks.create!(
        title: "Empty", position: 0, status: :failed, result_diff: "[]",
        result_comments: [{ "source" => "arnold", "author" => "system", "body" => "Some other error" }]
      )

      assert_equal "empty_diff", @engine.send(:task_failure_reason, task)
    end

    test "task_failure_reason returns merge_failed even when result_diff is nil" do
      pipeline_run = PipelineRun.create!(nl_input: "Build an app")
      task = pipeline_run.tasks.create!(
        title: "Merge Nil", position: 0, status: :failed, result_diff: nil,
        result_comments: [{ "source" => "arnold", "author" => "system", "body" => "Merge failed: conflict" }]
      )

      assert_equal "merge_failed", @engine.send(:task_failure_reason, task)
    end

    # --- iteration_number propagation ---

    test "execute_tiers! propagates iteration_number to all events" do
      pipeline_run = PipelineRun.create!(nl_input: "Build an app", status: :pending)
      task = pipeline_run.tasks.create!(title: "Fix bug", position: 0, tier: 0, status: :pending)

      event_recorder = PipelineEventRecorder.new(pipeline_run:)
      engine = TierExecutionEngine.new(
        executor: @executor, tier_gate_check: @tier_gate_check,
        logger: Logger.new(File::NULL), event_recorder: event_recorder
      )

      # Simulate task resolution during executor.call
      @executor.stubs(:call).with { |tasks:, **|
        tasks.first.update!(external_id: "1", result_diff: '[{"filename":"fix.rb"}]', status: :completed)
        true
      }
      @executor.stubs(:await_results)
      @executor.stubs(:merge_results)

      engine.execute_tiers!(pipeline_run, iteration_number: 2)

      started = pipeline_run.pipeline_events.find_by(event_type: :tier_execution_started)
      completed = pipeline_run.pipeline_events.find_by(event_type: :tier_execution_completed)

      assert_not_nil started, "Expected a tier_execution_started event"
      assert_not_nil completed, "Expected a tier_execution_completed event"
      assert_equal 2, started.iteration_number
      assert_equal 2, completed.iteration_number
    end

    test "execute_tiers! without iteration_number leaves it nil" do
      pipeline_run = PipelineRun.create!(nl_input: "Build an app", status: :pending)
      task = pipeline_run.tasks.create!(title: "Fix bug", position: 0, tier: 0, status: :pending)

      event_recorder = PipelineEventRecorder.new(pipeline_run:)
      engine = TierExecutionEngine.new(
        executor: @executor, tier_gate_check: @tier_gate_check,
        logger: Logger.new(File::NULL), event_recorder: event_recorder
      )

      # Simulate task resolution during executor.call
      @executor.stubs(:call).with { |tasks:, **|
        tasks.first.update!(external_id: "1", result_diff: '[{"filename":"fix.rb"}]', status: :completed)
        true
      }
      @executor.stubs(:await_results)
      @executor.stubs(:merge_results)

      engine.execute_tiers!(pipeline_run)

      started = pipeline_run.pipeline_events.find_by(event_type: :tier_execution_started)
      assert_not_nil started, "Expected a tier_execution_started event"
      assert_nil started.iteration_number
    end

    # --- duration_ms on validation events ---

    test "verification_checks event includes duration_ms" do
      pipeline_run = PipelineRun.create!(nl_input: "Build an app", status: :pending)

      event_recorder = PipelineEventRecorder.new(pipeline_run:)
      engine = TierExecutionEngine.new(
        executor: @executor, tier_gate_check: @tier_gate_check,
        logger: Logger.new(File::NULL), event_recorder: event_recorder
      )

      ArnoldPipeline.configure do |c|
        c.claude_code_repo_path = "/tmp/test-repo"
        c.verification_checks = [{ "name" => "boot", "command" => "echo ok", "type" => "boot_check" }]
      end

      ArnoldPipeline::VerificationRunner.stubs(:call).returns({
        all_passed: true, summary: "All passed",
        checks: [{ name: "boot", success: true, type: :boot_check }]
      })

      engine.send(:run_verification_checks)

      event = pipeline_run.pipeline_events.find_by(event_type: :verification_checks)
      assert_not_nil event, "Expected a verification_checks event"
      assert_not_nil event.duration_ms, "Expected duration_ms to be recorded"
      assert event.duration_ms >= 0
    end

    test "post_merge_hooks event includes duration_ms" do
      pipeline_run = PipelineRun.create!(nl_input: "Build an app", status: :pending)
      task = pipeline_run.tasks.create!(title: "Setup", position: 0, tier: 0, external_id: "1",
        result_diff: '[{"filename":"Gemfile"}]')

      event_recorder = PipelineEventRecorder.new(pipeline_run:)
      engine = TierExecutionEngine.new(
        executor: @executor, tier_gate_check: @tier_gate_check,
        logger: Logger.new(File::NULL), event_recorder: event_recorder
      )

      ArnoldPipeline.configure do |c|
        c.claude_code_repo_path = "/tmp/test-repo"
        c.post_merge_hooks = [{ "name" => "test", "trigger_paths" => ["Gemfile"], "command" => "echo ok" }]
      end

      ArnoldPipeline::PostMergeHookRunner.stubs(:call).returns([
        { name: "test", triggered: true, success: true, exit_code: 0 }
      ])

      engine.send(:run_post_merge_hooks, [task])

      event = pipeline_run.pipeline_events.find_by(event_type: :post_merge_hooks)
      assert_not_nil event, "Expected a post_merge_hooks event"
      assert_not_nil event.duration_ms, "Expected duration_ms to be recorded"
      assert event.duration_ms >= 0
    end

    test "criteria_check event includes duration_ms" do
      tmpdir = Dir.mktmpdir("arnold_criteria_event_test")

      pipeline_run = PipelineRun.create!(nl_input: "Build an app", status: :pending)
      task = pipeline_run.tasks.create!(
        title: "Setup", position: 0, tier: 1,
        acceptance_criteria: [{ "type" => "file_exists", "description" => "Gemfile exists", "params" => { "pattern" => "Gemfile" } }]
      )

      event_recorder = PipelineEventRecorder.new(pipeline_run:)
      engine = TierExecutionEngine.new(
        executor: @executor, tier_gate_check: @tier_gate_check,
        logger: Logger.new(File::NULL), event_recorder: event_recorder
      )

      ArnoldPipeline.configure do |c|
        c.claude_code_repo_path = tmpdir
        c.tier_gate_enabled = true
        c.criteria_check_mode = :advisory
      end

      ArnoldPipeline::CriteriaChecker.stubs(:call).returns({ verified: [], failed: [], unverified: [] })

      engine.send(:run_criteria_check!, pipeline_run, [task])

      event = pipeline_run.pipeline_events.find_by(event_type: :criteria_check)
      assert_not_nil event, "Expected a criteria_check event"
      assert_not_nil event.duration_ms, "Expected duration_ms to be recorded"
      assert event.duration_ms >= 0
    ensure
      FileUtils.rm_rf(tmpdir) if tmpdir
    end

    test "criteria_check event includes mode field" do
      tmpdir = Dir.mktmpdir("arnold_criteria_event_test")

      pipeline_run = PipelineRun.create!(nl_input: "Build an app", status: :pending)
      task = pipeline_run.tasks.create!(
        title: "Setup", position: 0, tier: 1,
        acceptance_criteria: [{ "type" => "file_exists", "description" => "Gemfile exists", "params" => { "pattern" => "Gemfile" } }]
      )

      event_recorder = PipelineEventRecorder.new(pipeline_run:)
      engine = TierExecutionEngine.new(
        executor: @executor, tier_gate_check: @tier_gate_check,
        logger: Logger.new(File::NULL), event_recorder: event_recorder
      )

      ArnoldPipeline.configure do |c|
        c.claude_code_repo_path = tmpdir
        c.tier_gate_enabled = true
        c.criteria_check_mode = :advisory
      end

      ArnoldPipeline::CriteriaChecker.stubs(:call).returns({ verified: [], failed: [], unverified: [] })

      engine.send(:run_criteria_check!, pipeline_run, [task])

      event = pipeline_run.pipeline_events.find_by(event_type: :criteria_check)
      assert_equal "advisory", event.summary["mode"]
    ensure
      FileUtils.rm_rf(tmpdir) if tmpdir
    end

    # --- extract_failure_summary ---

    test "extract_failure_summary does not truncate long test names or messages" do
      long_name = "TasksControllerTest#test_should_handle_authentication_and_return_proper_error_responses_for_all_endpoints"
      long_message = "Expected response to be a <200: OK> but was a <401: Unauthorized>. The authentication token was expired and the refresh mechanism failed."

      test_result = TestExecution::TestResult.new(
        passed: false, exit_code: 1,
        summary: "38 runs, 81 assertions, 2 failures, 0 errors, 0 skips",
        failures: [
          { name: long_name, location: "test/controllers/tasks_controller_test.rb:42", message: long_message }
        ]
      )

      issues = @engine.send(:extract_failure_summary, test_result)
      assert_equal 1, issues.size
      assert_includes issues.first, long_name
      assert_includes issues.first, long_message
    end

    test "extract_failure_summary preserves full summary when no failures parsed" do
      long_summary = "38 runs, 81 assertions, 2 failures, 0 errors, 0 skips"
      test_result = TestExecution::TestResult.new(
        passed: false, exit_code: 1,
        summary: long_summary, failures: []
      )

      issues = @engine.send(:extract_failure_summary, test_result)
      assert_equal 1, issues.size
      assert_includes issues.first, long_summary
    end

    # --- Error handling ---

    test "falls back to generic task when CorrectiveTaskGenerator fails" do
      pipeline_run = PipelineRun.create!(nl_input: "Build an app")
      task = pipeline_run.tasks.create!(
        title: "Setup DB", position: 0, tier: 0, description: "Create database",
        external_id: "42", result_diff: '[{"filename":"schema.rb"}]'
      )

      verification_results = {
        checks: [
          { name: "tests", type: :test_suite, success: false,
            stdout: "3 runs, 3 assertions, 1 failures, 0 errors", stderr: "", exit_code: 1 }
        ],
        all_passed: false,
        summary: "0 passed, 1 failed"
      }

      ArnoldPipeline::CorrectiveTaskGenerator.stubs(:call).raises(RuntimeError, "LLM exploded")

      result = @engine.send(:run_tier_gate!, pipeline_run, 0, [task],
                            verification_results: verification_results)

      refute result["pass"]
      assert_equal 1, result["corrective_tasks"].size
      assert_equal "Fix test failures", result["corrective_tasks"].first["title"]
      assert_includes result["corrective_tasks"].first["labels"], "bugfix"
    end

    # --- extract_test_output ---

    test "extract_test_output returns nil when verification_results is nil" do
      result = @engine.send(:extract_test_output, nil)
      assert_nil result
    end

    test "extract_test_output extracts test_suite stdout" do
      verification_results = {
        checks: [
          { name: "Test suite", type: :test_suite, success: false, exit_code: 1,
            stdout: "FAIL test_something\nExpected 1 got 2", stderr: "" }
        ]
      }
      result = @engine.send(:extract_test_output, verification_results)
      assert_includes result, "FAIL test_something"
    end

    test "extract_test_output truncates to last 3000 chars" do
      long_output = "x" * 5000
      verification_results = {
        checks: [
          { name: "Test suite", type: :test_suite, success: false, exit_code: 1,
            stdout: long_output, stderr: "" }
        ]
      }
      result = @engine.send(:extract_test_output, verification_results)
      assert_equal 3000, result.length
    end

    test "extract_test_output returns nil when no test_suite check exists" do
      verification_results = {
        checks: [
          { name: "Boot check", type: :boot, success: true, exit_code: 0, stdout: "OK", stderr: "" }
        ]
      }
      result = @engine.send(:extract_test_output, verification_results)
      assert_nil result
    end

    # --- build_corrective_description with verification_output ---

    test "build_corrective_description includes test output when verification_output provided" do
      verification_output = "1 runs, 0 assertions, 1 failures\nFAIL UserTest#test_validates_email\nExpected nil to not be nil"

      result = @engine.send(:build_corrective_description,
        base_description: "Fix the failing tests",
        gate_issues: ["test failures"],
        original_tier_tasks: [],
        acceptance_criteria_summary: nil,
        verification_output: verification_output
      )

      assert_includes result, "## Test Output"
      assert_includes result, "FAIL UserTest#test_validates_email"
      assert_includes result, "Expected nil to not be nil"
    end

    test "build_corrective_description omits test output when verification_output is nil" do
      result = @engine.send(:build_corrective_description,
        base_description: "Fix the failing tests",
        gate_issues: ["test failures"],
        original_tier_tasks: [],
        acceptance_criteria_summary: nil,
        verification_output: nil
      )

      refute_includes result, "## Test Output"
    end

    # --- handle_tier_gate_failure! with verification_results ---

    test "handle_tier_gate_failure! passes verification output to corrective task descriptions" do
      ArnoldPipeline.configure do |c|
        c.max_iterations = 3
        c.max_tier_retries = 1
        c.tier_gate_enabled = true
        c.llm_api_key = "test"
        c.github_token = "test"
        c.github_repo = "owner/repo"
      end

      pipeline_run = ArnoldPipeline::PipelineRun.create!(nl_input: "Build an app")
      pipeline_run.tasks.create!(title: "Setup DB", position: 0, tier: 0)

      gate_fail = {
        "pass" => false,
        "issues" => ["test failures"],
        "corrective_tasks" => [
          { "title" => "Fix tests", "description" => "fix the test failures" }
        ],
        "context_summary" => "context"
      }
      gate_pass = { "pass" => true, "issues" => [], "context_summary" => "Fixed.", "corrective_tasks" => [] }

      @executor.stubs(:call).returns([])
      @executor.stubs(:await_results).returns(nil)
      @executor.stubs(:merge_results).returns([])
      @tier_gate_check.stubs(:call).returns(gate_pass)

      verification_results = {
        all_passed: false,
        checks: [
          { name: "Test suite", type: :test_suite, success: false, exit_code: 1,
            stdout: "1 runs, 0 assertions, 1 failures, 0 errors\nFAIL UserTest#test_validates_email\nExpected nil to not be nil",
            stderr: "" }
        ]
      }

      @engine.send(:handle_tier_gate_failure!, pipeline_run, 0, [], gate_fail, [],
                   verification_results: verification_results)

      corrective = pipeline_run.tasks.where(title: "Fix tests").first
      assert_not_nil corrective
      assert_includes corrective.description, "## Test Output"
      assert_includes corrective.description, "FAIL UserTest#test_validates_email"
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

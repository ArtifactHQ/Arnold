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
  end
end

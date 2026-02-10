require "test_helper"
require "arnold_pipeline/providers/execution/claude_code"
require "arnold_pipeline/agents/executor"
require "arnold_pipeline/tier_execution_engine"

module ArnoldPipeline
  class ClaudeCodeProviderIntegrationTest < ActiveSupport::TestCase
    setup do
      @repo_path = Dir.mktmpdir
      system("git", "-C", @repo_path, "init", exception: true)
      system("git", "-C", @repo_path, "commit", "--allow-empty", "-m", "init", exception: true)

      ArnoldPipeline.configure do |c|
        c.execution_provider = :claude_code
        c.claude_code_repo_path = @repo_path
        c.llm_provider = :anthropic
        c.llm_api_key = "test-key"
        c.tier_gate_enabled = false
        c.context_propagation_enabled = false
      end
    end

    teardown do
      FileUtils.remove_entry(@repo_path) if @repo_path && Dir.exist?(@repo_path)
      ArnoldPipeline.reset_configuration!
    end

    test "executor publishes tasks and fetches results synchronously" do
      pipeline_run = PipelineRun.create!(nl_input: "Build a calculator")

      task = pipeline_run.tasks.create!(
        title: "Implement calculator",
        description: "Basic arithmetic operations",
        position: 0,
        tier: 0
      )

      provider = Providers::Execution.build
      provider.stubs(:execute_claude_code).returns({
        success: true,
        output: "Implemented calculator with add, subtract, multiply, divide",
        error: nil
      })
      provider.stubs(:normalize_worktree)
      provider.stubs(:capture_diff).returns(
        "diff --git a/calculator.rb b/calculator.rb\nnew file mode 100644\n+class Calculator\n+end"
      )
      provider.stubs(:setup_worktree).returns(@repo_path)

      executor = Agents::Executor.new(provider:, logger: Logger.new(File::NULL))

      # Publish tasks
      executor.call(tasks: [task], pipeline_run:)
      task.reload
      assert task.external_id.present?, "Task should have external_id after publish"
      assert_equal "in_progress", task.status

      # Fetch results — sync, no polling
      assert_equal false, provider.async?
      results = executor.fetch_results(pipeline_run:, tasks: [task])
      assert_equal 1, results.size
      assert_equal :completed, results.first[:status]
      assert_equal false, results.first[:workflow_active]

      # Verify task was updated with diff
      task.reload
      assert task.result_diff.present?
      assert_equal false, task.workflow_active?
    end

    test "TierExecutionEngine uses claude_code provider without awaiting_results" do
      pipeline_run = PipelineRun.create!(nl_input: "Build a calculator", status: :pending)

      pipeline_run.tasks.create!(
        title: "Setup project structure",
        description: "Initialize the project",
        position: 0,
        tier: 0
      )
      pipeline_run.tasks.create!(
        title: "Implement calculator logic",
        description: "Add, subtract, multiply, divide",
        position: 1,
        tier: 1
      )

      provider = Providers::Execution.build
      provider.stubs(:execute_claude_code).returns({
        success: true,
        output: "Done",
        error: nil
      })
      provider.stubs(:normalize_worktree)
      provider.stubs(:capture_diff).returns(
        "diff --git a/app.rb b/app.rb\nnew file mode 100644\n+class App\n+end"
      )
      provider.stubs(:setup_worktree).returns(@repo_path)
      provider.stubs(:merge_branch)

      executor = Agents::Executor.new(provider:, logger: Logger.new(File::NULL))
      tier_gate_check = stub(call: nil)
      engine = TierExecutionEngine.new(
        executor: executor,
        tier_gate_check: tier_gate_check,
        logger: Logger.new(File::NULL)
      )

      engine.execute_tiers!(pipeline_run)

      # All tasks should have external_ids and results
      pipeline_run.tasks.reload.each do |task|
        assert task.external_id.present?, "Task '#{task.title}' should have external_id"
        assert task.result_diff.present?, "Task '#{task.title}' should have result_diff"
      end

      # The pipeline never entered awaiting_results
      refute_equal "awaiting_results", pipeline_run.reload.status
    end

    test "sync provider fetch_results returns immediately without polling" do
      pipeline_run = PipelineRun.create!(nl_input: "Quick test")

      task = pipeline_run.tasks.create!(
        title: "Quick task",
        description: "Simple operation",
        position: 0,
        tier: 0,
        external_id: "cc-pre-set"
      )

      provider = Providers::Execution.build

      # Seed results directly (simulating create_tasks already ran)
      provider.instance_variable_set(:@results, {
        "cc-pre-set" => {
          success: true,
          diff: "diff --git a/file.rb b/file.rb\n+content",
          output: "Done"
        }
      })

      executor = Agents::Executor.new(provider:, logger: Logger.new(File::NULL))

      # This should return immediately — no sleep, no polling
      sleep_called = false
      executor.stubs(:sleep_func).returns(->(_) { sleep_called = true })

      results = executor.fetch_results(pipeline_run:, tasks: [task])
      assert_equal 1, results.size
      refute sleep_called, "Sync provider should not trigger polling sleep"
    end
  end
end

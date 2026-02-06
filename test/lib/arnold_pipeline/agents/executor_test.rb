require "test_helper"
require "arnold_pipeline/agents/executor"

module ArnoldPipeline
  module Agents
    class ExecutorTest < ActiveSupport::TestCase
      setup do
        @provider = stub("execution_provider")
        @executor = Executor.new(provider: @provider, logger: Logger.new(File::NULL))
        @pipeline_run = ArnoldPipeline::PipelineRun.create!(nl_input: "Build an app")
      end

      test "creates tasks and updates records with external IDs" do
        task = @pipeline_run.tasks.create!(title: "Setup DB", position: 0)

        @provider.expects(:create_tasks).returns([
          { external_id: "42", external_url: "https://github.com/o/r/issues/42", title: "Setup DB" }
        ])

        @executor.call(tasks: [task], pipeline_run: @pipeline_run)

        task.reload
        assert_equal "42", task.external_id
        assert_equal "https://github.com/o/r/issues/42", task.external_url
        assert_equal "in_progress", task.status
      end

      test "fetch_results stores diffs on task records" do
        task = @pipeline_run.tasks.create!(title: "Setup DB", position: 0, external_id: "42")

        @provider.expects(:fetch_results).returns([
          { task_id: task.id, external_id: "42", diffs: [{ filename: "db/schema.rb" }], status: :completed }
        ])

        results = @executor.fetch_results(pipeline_run: @pipeline_run)
        assert_equal 1, results.size

        task.reload
        assert_includes task.result_diff, "db/schema.rb"
      end

      test "fetch_results stores comments on task records" do
        task = @pipeline_run.tasks.create!(title: "Setup DB", position: 0, external_id: "42")

        comments = [{ source: "issue", author: "copilot", body: "Can't scaffold without Gemfile", created_at: "2025-02-06T00:00:00Z" }]
        @provider.expects(:fetch_results).returns([
          { task_id: task.id, external_id: "42", diffs: [], comments: comments, status: :pending }
        ])

        @executor.fetch_results(pipeline_run: @pipeline_run)

        task.reload
        assert_equal 1, task.result_comments.size
        assert_equal "issue", task.result_comments.first["source"]
      end

      test "fetch_results marks task as failed when provider returns failed" do
        task = @pipeline_run.tasks.create!(title: "Setup DB", position: 0, external_id: "42")

        @provider.expects(:fetch_results).returns([
          { task_id: task.id, external_id: "42", diffs: [], comments: [], status: :failed }
        ])

        @executor.fetch_results(pipeline_run: @pipeline_run)

        task.reload
        assert task.failed?, "Task should be marked as failed"
      end

      test "merge_results delegates to provider" do
        @provider.expects(:merge_results).returns([{ pr_number: 1, task_id: 1 }])

        results = @executor.merge_results(pipeline_run: @pipeline_run)
        assert_equal 1, results.size
      end

      # --- await_results tests ---

      test "await_results returns immediately when all tasks have results on first fetch" do
        sleep_calls = []
        executor = Executor.new(
          provider: @provider,
          logger: Logger.new(File::NULL),
          sleep_func: ->(s) { sleep_calls << s }
        )

        task = @pipeline_run.tasks.create!(title: "Setup DB", position: 0, external_id: "42", result_diff: '[{"filename":"schema.rb"}]')

        @provider.stubs(:fetch_results).returns([])

        ArnoldPipeline.configure do |c|
          c.polling_interval = 2
          c.polling_timeout = 20
          c.polling_max_interval = 6
        end

        executor.await_results(pipeline_run: @pipeline_run)

        assert_empty sleep_calls, "Should not sleep when all tasks already have results"
      ensure
        ArnoldPipeline.reset_configuration!
      end

      test "await_results polls until all tasks have results" do
        sleep_calls = []
        executor = Executor.new(
          provider: @provider,
          logger: Logger.new(File::NULL),
          sleep_func: ->(s) { sleep_calls << s }
        )

        task = @pipeline_run.tasks.create!(title: "Setup DB", position: 0, external_id: "42")
        fetch_count = 0

        @provider.stubs(:fetch_results).with { |kwargs|
          fetch_count += 1
          # Simulate result appearing on second fetch
          if fetch_count >= 2
            task.update!(result_diff: '[{"filename":"schema.rb"}]')
          end
          true
        }.returns([])

        ArnoldPipeline.configure do |c|
          c.polling_interval = 2
          c.polling_timeout = 20
          c.polling_max_interval = 6
        end

        executor.await_results(pipeline_run: @pipeline_run)

        assert_equal [2], sleep_calls
      ensure
        ArnoldPipeline.reset_configuration!
      end

      test "await_results stops after timeout with partial results" do
        sleep_calls = []
        executor = Executor.new(
          provider: @provider,
          logger: Logger.new(File::NULL),
          sleep_func: ->(s) { sleep_calls << s }
        )

        @pipeline_run.tasks.create!(title: "Task 1", position: 0, external_id: "1")
        @pipeline_run.tasks.create!(title: "Task 2", position: 1, external_id: "2")

        @provider.stubs(:fetch_results).returns([])

        ArnoldPipeline.configure do |c|
          c.polling_interval = 2
          c.polling_timeout = 10
          c.polling_max_interval = 6
        end

        executor.await_results(pipeline_run: @pipeline_run)

        # Backoff: 2, 4, 4 (capped by remaining time) = 10s total
        assert_equal [2, 4, 4], sleep_calls
      ensure
        ArnoldPipeline.reset_configuration!
      end

      test "await_results uses exponential backoff with cap" do
        sleep_calls = []
        executor = Executor.new(
          provider: @provider,
          logger: Logger.new(File::NULL),
          sleep_func: ->(s) { sleep_calls << s }
        )

        @pipeline_run.tasks.create!(title: "Task 1", position: 0, external_id: "1")

        @provider.stubs(:fetch_results).returns([])

        ArnoldPipeline.configure do |c|
          c.polling_interval = 2
          c.polling_timeout = 20
          c.polling_max_interval = 6
        end

        executor.await_results(pipeline_run: @pipeline_run)

        # Backoff: 2, 4, 6, 6, 2 (remaining) = 20s total
        assert_equal [2, 4, 6, 6, 2], sleep_calls
      ensure
        ArnoldPipeline.reset_configuration!
      end

      test "await_results considers failed tasks as resolved" do
        sleep_calls = []
        executor = Executor.new(
          provider: @provider,
          logger: Logger.new(File::NULL),
          sleep_func: ->(s) { sleep_calls << s }
        )

        task = @pipeline_run.tasks.create!(title: "Setup DB", position: 0, external_id: "42", status: :failed)

        @provider.stubs(:fetch_results).returns([])

        ArnoldPipeline.configure do |c|
          c.polling_interval = 2
          c.polling_timeout = 20
          c.polling_max_interval = 6
        end

        executor.await_results(pipeline_run: @pipeline_run)

        assert_empty sleep_calls, "Should not sleep when failed tasks are considered resolved"
      ensure
        ArnoldPipeline.reset_configuration!
      end

      test "await_results considers tasks with comments as resolved" do
        sleep_calls = []
        executor = Executor.new(
          provider: @provider,
          logger: Logger.new(File::NULL),
          sleep_func: ->(s) { sleep_calls << s }
        )

        task = @pipeline_run.tasks.create!(
          title: "Setup DB", position: 0, external_id: "42", status: :in_progress,
          result_comments: [{ source: "issue", author: "copilot", body: "I can't do this", created_at: "2025-02-06T00:00:00Z" }]
        )

        @provider.stubs(:fetch_results).returns([])

        ArnoldPipeline.configure do |c|
          c.polling_interval = 2
          c.polling_timeout = 20
          c.polling_max_interval = 6
        end

        executor.await_results(pipeline_run: @pipeline_run)

        assert_empty sleep_calls, "Should not sleep when tasks have comments (Claude gave feedback)"
      ensure
        ArnoldPipeline.reset_configuration!
      end

      test "await_results tasks without external_id do not block completion" do
        sleep_calls = []
        executor = Executor.new(
          provider: @provider,
          logger: Logger.new(File::NULL),
          sleep_func: ->(s) { sleep_calls << s }
        )

        # Task with external_id and result — counts as complete
        @pipeline_run.tasks.create!(title: "Task 1", position: 0, external_id: "1", result_diff: '[{"filename":"a.rb"}]')
        # Task without external_id — should not block
        @pipeline_run.tasks.create!(title: "Task 2", position: 1, external_id: nil)

        @provider.stubs(:fetch_results).returns([])

        ArnoldPipeline.configure do |c|
          c.polling_interval = 2
          c.polling_timeout = 10
          c.polling_max_interval = 6
        end

        executor.await_results(pipeline_run: @pipeline_run)

        assert_empty sleep_calls, "Tasks without external_id should not block completion"
      ensure
        ArnoldPipeline.reset_configuration!
      end
    end
  end
end

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

      test "merge_results delegates to provider" do
        @provider.expects(:merge_results).returns([{ pr_number: 1, task_id: 1 }])

        results = @executor.merge_results(pipeline_run: @pipeline_run)
        assert_equal 1, results.size
      end
    end
  end
end

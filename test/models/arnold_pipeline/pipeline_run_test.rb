require "test_helper"

module ArnoldPipeline
  class PipelineRunTest < ActiveSupport::TestCase
    test "requires nl_input" do
      run_record = PipelineRun.new(nl_input: nil)
      assert_not run_record.valid?
      assert_includes run_record.errors[:nl_input], "can't be blank"
    end

    test "defaults to pending status" do
      run_record = PipelineRun.new(nl_input: "Build a todo app")
      assert_equal "pending", run_record.status
    end

    test "has all expected status values" do
      expected = %w[pending generating_spec breaking_tasks executing analyzing completed max_iterations_reached failed awaiting_results paused]
      assert_equal expected, PipelineRun.statuses.keys
    end

    test "has_one specification" do
      run_record = PipelineRun.create!(nl_input: "Build a todo app")
      spec = run_record.create_specification!(content: "# Todo App Spec", version: 1)

      assert_equal spec, run_record.reload.specification
    end

    test "has_many tasks" do
      run_record = PipelineRun.create!(nl_input: "Build a todo app")
      task = run_record.tasks.create!(title: "Setup database", position: 0)

      assert_includes run_record.reload.tasks, task
    end

    test "has_many iterations" do
      run_record = PipelineRun.create!(nl_input: "Build a todo app")
      iteration = run_record.iterations.create!(number: 1, decision: "done", confidence: 95)

      assert_includes run_record.reload.iterations, iteration
    end

    test "destroys dependent associations" do
      run_record = PipelineRun.create!(nl_input: "Build a todo app")
      run_record.create_specification!(content: "spec", version: 1)
      run_record.tasks.create!(title: "Task 1", position: 0)
      run_record.iterations.create!(number: 1, decision: "done", confidence: 90)

      assert_difference ["Specification.count", "Task.count", "Iteration.count"], -1 do
        run_record.destroy!
      end
    end
  end
end

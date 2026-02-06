require "test_helper"

module ArnoldPipeline
  class TaskTest < ActiveSupport::TestCase
    setup do
      @run = PipelineRun.create!(nl_input: "Build a todo app")
    end

    test "requires title" do
      task = @run.tasks.build(title: nil, position: 0)
      assert_not task.valid?
      assert_includes task.errors[:title], "can't be blank"
    end

    test "requires position" do
      task = @run.tasks.build(title: "Setup DB", position: nil)
      assert_not task.valid?
      assert_includes task.errors[:position], "can't be blank"
    end

    test "position must be non-negative" do
      task = @run.tasks.build(title: "Setup DB", position: -1)
      assert_not task.valid?
    end

    test "defaults to pending status" do
      task = @run.tasks.build(title: "Setup DB", position: 0)
      assert_equal "pending", task.status
    end

    test "has all expected status values" do
      expected = %w[pending in_progress completed failed]
      assert_equal expected, Task.statuses.keys
    end

    test "orders by position by default" do
      @run.tasks.create!(title: "Third", position: 2)
      @run.tasks.create!(title: "First", position: 0)
      @run.tasks.create!(title: "Second", position: 1)

      assert_equal %w[First Second Third], @run.tasks.reload.map(&:title)
    end

    test "belongs to pipeline_run" do
      task = @run.tasks.create!(title: "Setup DB", position: 0)
      assert_equal @run, task.pipeline_run
    end
  end
end

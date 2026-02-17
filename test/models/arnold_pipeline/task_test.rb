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
      expected = %w[pending in_progress completed failed superseded]
      assert_equal expected, Task.statuses.keys
    end

    test "accepts superseded status" do
      task = @run.tasks.create!(title: "Setup DB", position: 0, status: :superseded)
      assert task.superseded?
      assert_equal "superseded", task.status
    end

    test "ordered scope sorts by position" do
      @run.tasks.create!(title: "Third", position: 2)
      @run.tasks.create!(title: "First", position: 0)
      @run.tasks.create!(title: "Second", position: 1)

      assert_equal %w[First Second Third], @run.tasks.ordered.map(&:title)
    end

    test "belongs to pipeline_run" do
      task = @run.tasks.create!(title: "Setup DB", position: 0)
      assert_equal @run, task.pipeline_run
    end

    # --- resolution_summary tests ---

    test "resolution_summary shows no_signals when task has no resolution indicators" do
      task = @run.tasks.create!(title: "Setup DB", position: 0, external_id: "42")
      assert_equal "Setup DB (#42): no_signals", task.resolution_summary
    end

    test "resolution_summary shows has_diffs when task has diffs" do
      task = @run.tasks.create!(title: "Setup DB", position: 0, external_id: "42", result_diff: '[{"filename":"schema.rb"}]')
      assert_equal "Setup DB (#42): has_diffs", task.resolution_summary
    end

    test "resolution_summary shows failed when task failed" do
      task = @run.tasks.create!(title: "Setup DB", position: 0, external_id: "42", status: :failed)
      assert_equal "Setup DB (#42): failed", task.resolution_summary
    end

    test "resolution_summary shows workflow_active when workflow is active" do
      task = @run.tasks.create!(title: "Setup DB", position: 0, external_id: "42", workflow_active: true)
      assert_equal "Setup DB (#42): workflow_active", task.resolution_summary
    end

    test "resolution_summary shows multiple signals" do
      task = @run.tasks.create!(
        title: "Setup DB", position: 0, external_id: "42",
        workflow_active: true,
        result_diff: '[{"filename":"schema.rb"}]',
        result_comments: [{ "source" => "issue", "author" => "copilot", "body" => "Can't do this" }]
      )
      assert_equal "Setup DB (#42): workflow_active, has_diffs, resolution_comments", task.resolution_summary
    end

    test "resolution_summary ignores empty diffs array" do
      task = @run.tasks.create!(title: "Setup DB", position: 0, external_id: "42", result_diff: "[]")
      assert_equal "Setup DB (#42): no_signals", task.resolution_summary
    end

    test "resolution_summary shows non_resolution_comments for planning comments" do
      task = @run.tasks.create!(
        title: "Setup DB", position: 0, external_id: "42",
        result_comments: [{ "source" => "issue", "author" => "copilot", "body" => "Analyzing the repository structure..." }]
      )
      assert_equal "Setup DB (#42): non_resolution_comments", task.resolution_summary
    end

    test "resolution_summary shows wip_comments_only for WIP comments" do
      task = @run.tasks.create!(
        title: "Setup DB", position: 0, external_id: "42",
        result_comments: [{ "source" => "issue", "author" => "copilot", "body" => "Claude Code is working on this issue." }]
      )
      assert_equal "Setup DB (#42): wip_comments_only", task.resolution_summary
    end
  end
end

require "test_helper"

module ArnoldPipeline
  class TaskSubstantiveCommentsTest < ActiveSupport::TestCase
    cover "ArnoldPipeline::Task*"

    setup do
      @run = PipelineRun.create!(nl_input: "Build an app")
    end

    def build_comment(body)
      { "source" => "issue", "author" => "copilot", "body" => body, "created_at" => "2025-02-06T00:00:00Z" }
    end

    # --- false cases: nil/empty ---

    test "returns false for nil comments" do
      task = @run.tasks.create!(title: "Task", position: 0, result_comments: nil)
      assert_not task.has_substantive_comments?
    end

    test "returns false for empty comments" do
      task = @run.tasks.create!(title: "Task", position: 0, result_comments: [])
      assert_not task.has_substantive_comments?
    end

    # --- false cases: WIP-only ---

    test "returns false for 'is working' WIP comment" do
      task = @run.tasks.create!(title: "Task", position: 0,
        result_comments: [build_comment("Claude Code is working on this issue.")])
      assert_not task.has_substantive_comments?
    end

    test "returns false for 'starting work' WIP comment" do
      task = @run.tasks.create!(title: "Task", position: 0,
        result_comments: [build_comment("Starting work on this task now.")])
      assert_not task.has_substantive_comments?
    end

    test "returns false for 'looking into' WIP comment" do
      task = @run.tasks.create!(title: "Task", position: 0,
        result_comments: [build_comment("Looking into this issue.")])
      assert_not task.has_substantive_comments?
    end

    test "returns false for 'get back to you' WIP comment" do
      task = @run.tasks.create!(title: "Task", position: 0,
        result_comments: [build_comment("I'll analyze this and get back to you.")])
      assert_not task.has_substantive_comments?
    end

    test "returns false for 'in progress' WIP comment" do
      task = @run.tasks.create!(title: "Task", position: 0,
        result_comments: [build_comment("This task is in progress.")])
      assert_not task.has_substantive_comments?
    end

    test "returns false for 'picking up' WIP comment" do
      task = @run.tasks.create!(title: "Task", position: 0,
        result_comments: [build_comment("Picking up this issue now.")])
      assert_not task.has_substantive_comments?
    end

    test "returns false when ALL comments are WIP" do
      task = @run.tasks.create!(title: "Task", position: 0,
        result_comments: [
          build_comment("Claude Code is working on this issue."),
          build_comment("Starting work on the implementation.")
        ])
      assert_not task.has_substantive_comments?
    end

    # --- true cases: completion ---

    test "returns true for 'finished' completion comment" do
      task = @run.tasks.create!(title: "Task", position: 0,
        result_comments: [build_comment("Claude finished @user's task in 3m 47s")])
      assert task.has_substantive_comments?
    end

    test "returns true for 'Create PR' completion comment" do
      task = @run.tasks.create!(title: "Task", position: 0,
        result_comments: [build_comment("Done! Create PR here.")])
      assert task.has_substantive_comments?
    end

    test "returns true for 'completed' completion comment" do
      task = @run.tasks.create!(title: "Task", position: 0,
        result_comments: [build_comment("Task completed successfully.")])
      assert task.has_substantive_comments?
    end

    # --- true cases: blocker comments ---

    test "returns true for 'can't' blocker comment" do
      task = @run.tasks.create!(title: "Task", position: 0,
        result_comments: [build_comment("I can't scaffold without Gemfile")])
      assert task.has_substantive_comments?
    end

    test "returns true for 'cant' blocker comment" do
      task = @run.tasks.create!(title: "Task", position: 0,
        result_comments: [build_comment("I cant do this without dependencies")])
      assert task.has_substantive_comments?
    end

    test "returns true for 'unable to' blocker comment" do
      task = @run.tasks.create!(title: "Task", position: 0,
        result_comments: [build_comment("Unable to complete this task.")])
      assert task.has_substantive_comments?
    end

    test "returns true for 'failed' blocker comment" do
      task = @run.tasks.create!(title: "Task", position: 0,
        result_comments: [build_comment("The build failed with errors.")])
      assert task.has_substantive_comments?
    end

    test "returns true for 'error' blocker comment" do
      task = @run.tasks.create!(title: "Task", position: 0,
        result_comments: [build_comment("Got an error running migrations.")])
      assert task.has_substantive_comments?
    end

    # --- false cases: non-resolution comments (no explicit completion/failure signal) ---

    test "returns false for unknown comment without resolution signal" do
      task = @run.tasks.create!(title: "Task", position: 0,
        result_comments: [build_comment("Here are the changes I made to the codebase.")])
      assert_not task.has_substantive_comments?
    end

    test "returns false for planning/analysis comment" do
      task = @run.tasks.create!(title: "Task", position: 0,
        result_comments: [build_comment(
          "Project Bootstrap Analysis\nTasks:\n- Gather context\n- Create backend\n" \
          "Analysis: I've analyzed the repository structure.\nSetting up the project structure..."
        )])
      assert_not task.has_substantive_comments?
    end

    # --- true cases: mixed ---

    test "returns true when mix of WIP and substantive comments" do
      task = @run.tasks.create!(title: "Task", position: 0,
        result_comments: [
          build_comment("Claude Code is working on this issue."),
          build_comment("Claude finished @user's task in 3m 47s — Create PR")
        ])
      assert task.has_substantive_comments?
    end

    # --- edge case: WIP + completion signals in same comment ---

    test "comment with both WIP and completion signals is substantive" do
      task = @run.tasks.create!(title: "Task", position: 0,
        result_comments: [build_comment("Claude Code is working on this and finished the PR.")])
      assert task.has_substantive_comments?
    end
  end
end

require "test_helper"

module ArnoldPipeline
  class PipelineRunTest < ActiveSupport::TestCase
    cover "ArnoldPipeline::PipelineRun*"

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

      assert_difference [ "Specification.count", "Task.count", "Iteration.count" ], -1 do
        run_record.destroy!
      end
    end

    # --- Status transition validation ---

    test "VALID_TRANSITIONS covers all statuses" do
      assert_equal PipelineRun.statuses.keys.sort, PipelineRun::VALID_TRANSITIONS.keys.sort
    end

    test "allows valid transition from pending to generating_spec" do
      run_record = PipelineRun.create!(nl_input: "Build an app")
      run_record.status = :generating_spec
      assert run_record.valid?, "Expected pending -> generating_spec to be valid"
    end

    test "allows valid transition from pending to failed" do
      run_record = PipelineRun.create!(nl_input: "Build an app")
      run_record.status = :failed
      assert run_record.valid?, "Expected pending -> failed to be valid"
    end

    test "allows valid transition from generating_spec to breaking_tasks" do
      run_record = PipelineRun.create!(nl_input: "Build an app", status: :generating_spec)
      run_record.status = :breaking_tasks
      assert run_record.valid?, "Expected generating_spec -> breaking_tasks to be valid"
    end

    test "allows valid transition from analyzing to completed" do
      run_record = PipelineRun.create!(nl_input: "Build an app", status: :analyzing)
      run_record.status = :completed
      assert run_record.valid?, "Expected analyzing -> completed to be valid"
    end

    test "allows valid transition from analyzing to executing (iterate_tasks)" do
      run_record = PipelineRun.create!(nl_input: "Build an app", status: :analyzing)
      run_record.status = :executing
      assert run_record.valid?, "Expected analyzing -> executing to be valid"
    end

    test "allows valid transition from analyzing to breaking_tasks (iterate_spec)" do
      run_record = PipelineRun.create!(nl_input: "Build an app", status: :analyzing)
      run_record.status = :breaking_tasks
      assert run_record.valid?, "Expected analyzing -> breaking_tasks to be valid"
    end

    test "allows valid transition from executing to analyzing (sync provider)" do
      run_record = PipelineRun.create!(nl_input: "Build an app", status: :executing)
      run_record.status = :analyzing
      assert run_record.valid?, "Expected executing -> analyzing to be valid"
    end

    test "allows valid transition from executing to paused (tier gate exhaustion)" do
      run_record = PipelineRun.create!(nl_input: "Build an app", status: :executing)
      run_record.status = :paused
      assert run_record.valid?, "Expected executing -> paused to be valid"
    end

    test "allows valid transition from paused to executing (resume)" do
      run_record = PipelineRun.create!(nl_input: "Build an app", status: :paused)
      run_record.status = :executing
      assert run_record.valid?, "Expected paused -> executing to be valid"
    end

    test "allows valid transition from failed to generating_spec (resume)" do
      run_record = PipelineRun.create!(nl_input: "Build an app", status: :failed)
      run_record.status = :generating_spec
      assert run_record.valid?, "Expected failed -> generating_spec to be valid"
    end

    test "rejects invalid transition from pending to completed" do
      run_record = PipelineRun.create!(nl_input: "Build an app")
      run_record.status = :completed
      assert_not run_record.valid?
      assert_includes run_record.errors[:status], "cannot transition from 'pending' to 'completed'"
    end

    test "rejects invalid transition from pending to analyzing" do
      run_record = PipelineRun.create!(nl_input: "Build an app")
      run_record.status = :analyzing
      assert_not run_record.valid?
    end

    test "rejects transition from completed (terminal state)" do
      run_record = PipelineRun.create!(nl_input: "Build an app", status: :completed)
      run_record.status = :pending
      assert_not run_record.valid?
      assert_includes run_record.errors[:status], "cannot transition from 'completed' to 'pending'"
    end

    test "rejects transition from max_iterations_reached (terminal state)" do
      run_record = PipelineRun.create!(nl_input: "Build an app", status: :max_iterations_reached)
      run_record.status = :generating_spec
      assert_not run_record.valid?
      assert_includes run_record.errors[:status], "cannot transition from 'max_iterations_reached' to 'generating_spec'"
    end

    test "allows update without status change" do
      run_record = PipelineRun.create!(nl_input: "Build an app", status: :executing)
      run_record.metadata = { "some" => "data" }
      assert run_record.valid?, "Expected non-status update to be valid"
    end
  end
end

require "test_helper"
require "arnold_pipeline/resume_inferrer"

module ArnoldPipeline
  class ResumeInferrerTest < ActiveSupport::TestCase
    test "returns generate_spec when no specification exists" do
      pipeline_run = PipelineRun.create!(nl_input: "Build an app", status: :paused)

      assert_equal :generate_spec, ResumeInferrer.call(pipeline_run)
    end

    test "returns break_tasks when specification exists but no tasks" do
      pipeline_run = PipelineRun.create!(nl_input: "Build an app", status: :paused)
      pipeline_run.create_specification!(content: "Spec", version: 1)

      assert_equal :break_tasks, ResumeInferrer.call(pipeline_run)
    end

    test "returns execute when tasks have no tier assigned" do
      pipeline_run = PipelineRun.create!(nl_input: "Build an app", status: :paused)
      pipeline_run.create_specification!(content: "Spec", version: 1)
      pipeline_run.tasks.create!(title: "Setup DB", position: 0, tier: nil)

      assert_equal :execute, ResumeInferrer.call(pipeline_run)
    end

    test "returns execute when tasks have no external_id" do
      pipeline_run = PipelineRun.create!(nl_input: "Build an app", status: :paused)
      pipeline_run.create_specification!(content: "Spec", version: 1)
      pipeline_run.tasks.create!(title: "Setup DB", position: 0, tier: 0)

      assert_equal :execute, ResumeInferrer.call(pipeline_run)
    end

    test "returns execute when tasks have active workflows" do
      pipeline_run = PipelineRun.create!(nl_input: "Build an app", status: :paused)
      pipeline_run.create_specification!(content: "Spec", version: 1)
      pipeline_run.tasks.create!(
        title: "Setup DB", position: 0, tier: 0, external_id: "42",
        result_diff: '[{"filename":"schema.rb"}]',
        workflow_active: true
      )

      assert_equal :execute, ResumeInferrer.call(pipeline_run)
    end

    test "returns analyze when all tasks are resolved" do
      pipeline_run = PipelineRun.create!(nl_input: "Build an app", status: :paused)
      pipeline_run.create_specification!(content: "Spec", version: 1)
      pipeline_run.tasks.create!(
        title: "Setup DB", position: 0, tier: 0, external_id: "42",
        result_diff: '[{"filename":"schema.rb"}]',
        workflow_active: false
      )

      assert_equal :analyze, ResumeInferrer.call(pipeline_run)
    end

    test "returns execute when some tasks lack diffs and are not failed" do
      pipeline_run = PipelineRun.create!(nl_input: "Build an app", status: :paused)
      pipeline_run.create_specification!(content: "Spec", version: 1)
      pipeline_run.tasks.create!(
        title: "Setup DB", position: 0, tier: 0, external_id: "42",
        result_diff: '[{"filename":"schema.rb"}]'
      )
      pipeline_run.tasks.create!(
        title: "Build API", position: 1, tier: 1, external_id: "43"
      )

      assert_equal :execute, ResumeInferrer.call(pipeline_run)
    end

    test "returns analyze when task is failed with no diffs" do
      pipeline_run = PipelineRun.create!(nl_input: "Build an app", status: :paused)
      pipeline_run.create_specification!(content: "Spec", version: 1)
      pipeline_run.tasks.create!(
        title: "Setup DB", position: 0, tier: 0, external_id: "42",
        status: :failed
      )

      assert_equal :analyze, ResumeInferrer.call(pipeline_run)
    end
  end
end

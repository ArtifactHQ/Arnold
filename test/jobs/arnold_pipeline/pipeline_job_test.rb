require "test_helper"
require "arnold_pipeline/orchestrator"

module ArnoldPipeline
  class PipelineJobTest < ActiveJob::TestCase
    test "enqueues job" do
      run_record = PipelineRun.create!(nl_input: "Build a todo app")

      assert_enqueued_with(job: PipelineJob, args: [run_record.id]) do
        PipelineJob.perform_later(run_record.id)
      end
    end

    test "performs by calling orchestrator" do
      run_record = PipelineRun.create!(nl_input: "Build a todo app")

      mock_orchestrator = stub("orchestrator")
      mock_orchestrator.expects(:call).with(nl_input: "Build a todo app").returns(run_record)
      Orchestrator.expects(:new).returns(mock_orchestrator)

      PipelineJob.perform_now(run_record.id)
    end
  end
end

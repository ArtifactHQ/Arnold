module ArnoldPipeline
  class PipelineJob < ApplicationJob
    queue_as :default

    def perform(pipeline_run_id)
      pipeline_run = PipelineRun.find(pipeline_run_id)
      orchestrator = Orchestrator.new

      if pipeline_run.pending?
        orchestrator.call(nl_input: pipeline_run.nl_input, pipeline_run: pipeline_run)
      else
        orchestrator.resume(pipeline_run: pipeline_run)
      end
    rescue => e
      pipeline_run&.update!(status: :failed, metadata: { error: e.message }) if pipeline_run&.persisted?
      raise
    end
  end
end

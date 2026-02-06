module ArnoldPipeline
  class PipelineJob < ApplicationJob
    queue_as :default

    def perform(pipeline_run_id)
      pipeline_run = PipelineRun.find(pipeline_run_id)
      Orchestrator.new.call(nl_input: pipeline_run.nl_input)
    rescue => e
      pipeline_run&.update!(status: :failed, metadata: { error: e.message }) if pipeline_run&.persisted?
      raise
    end
  end
end

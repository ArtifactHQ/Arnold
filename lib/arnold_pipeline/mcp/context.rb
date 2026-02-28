require "arnold_pipeline/library/manager"

module ArnoldPipeline
  module Mcp
    class Context
      def pipeline_run(run_id: nil)
        if run_id
          PipelineRun.find_by(id: run_id)
        else
          PipelineRun.order(created_at: :desc).first
        end
      end

      def specification(run_id: nil)
        pipeline_run(run_id:)&.specification
      end

      def library_manager
        @library_manager ||= Library::Manager.new(logger: Logger.new(File::NULL))
      end

      def configuration
        ArnoldPipeline.configuration
      end
    end
  end
end

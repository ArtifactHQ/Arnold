module ArnoldPipeline
  class PipelineEventRecorder
    attr_reader :pipeline_run

    def initialize(pipeline_run:)
      @pipeline_run = pipeline_run
    end

    def record(event_type:, stage:, summary:, payload: nil, duration_ms: nil, iteration_number: nil, tier_number: nil)
      return unless ArnoldPipeline.configuration.event_logging_enabled

      attrs = {
        event_type:,
        stage:,
        summary:,
        duration_ms:,
        iteration_number:,
        tier_number:
      }

      if ArnoldPipeline.configuration.verbose_event_logging && payload
        attrs[:payload] = payload
      end

      pipeline_run.pipeline_events.create!(attrs)
    rescue => e
      # Non-fatal — event recording failure must never crash the pipeline
      nil
    end

    def timed(event_type:, stage:, summary: nil, payload: nil, iteration_number: nil, tier_number: nil)
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = yield
      elapsed = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000).round(1)

      final_summary = summary.is_a?(Proc) ? summary.call(result) : summary
      final_payload = payload.is_a?(Proc) ? payload.call(result) : payload

      record(
        event_type:,
        stage:,
        summary: final_summary || {},
        payload: final_payload,
        duration_ms: elapsed,
        iteration_number:,
        tier_number:
      )

      result
    end
  end
end

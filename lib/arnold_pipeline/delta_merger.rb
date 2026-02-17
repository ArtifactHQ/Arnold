require "arnold_pipeline/openspec_bridge"

module ArnoldPipeline
  class DeltaMerger
    attr_reader :logger

    def initialize(logger: Logger.new($stdout, level: Logger::INFO))
      @logger = logger
    end

    # Apply deltas to a specification: persist delta records, merge content, snapshot revision.
    # iteration: optional Iteration record (nil for user-initiated iterations)
    def apply!(spec:, raw_deltas:, change_source:, pipeline_run: nil, iteration: nil)
      persist_deltas!(spec, iteration, raw_deltas) if iteration
      merge_deltas!(spec, raw_deltas, pipeline_run)
      snapshot_revision!(spec, raw_deltas, change_source)

      merge_strategy = ArnoldPipeline.configuration.openspec_enabled ? "openspec" : "append"
      { merge_strategy:, delta_count: raw_deltas.size, new_version: spec.reload.version }
    end

    def merge_deltas!(spec, deltas, pipeline_run)
      if ArnoldPipeline.configuration.openspec_enabled
        merged = openspec_merge(spec, deltas, pipeline_run)
        return if merged
      end
      append_deltas!(spec, deltas)
    end

    def append_deltas!(spec, deltas)
      additions = deltas.select { |d| d["operation"] == "added" }.map { |d| d["content"] || d["after_content"] }
      modifications = deltas.select { |d| d["operation"] == "modified" }.map { |d| d["after_content"] }
      removals = deltas.select { |d| d["operation"] == "removed" }.map { |d| "REMOVED: #{d['requirement']} — #{d['rationale']}" }

      clarifications = (additions + modifications + removals).compact.join("\n\n")
      updated_content = "#{spec.content}\n\n## Spec Iteration\n#{clarifications}"
      spec.update!(content: updated_content, version: spec.version + 1)
    end

    def persist_deltas!(spec, iteration, raw_deltas)
      raw_deltas.each do |d|
        spec.spec_deltas.create!(
          iteration:,
          operation: d["operation"],
          section: d["section"],
          requirement: d["requirement"],
          before_content: d["before_content"],
          after_content: d["after_content"] || d["content"],
          rationale: d["rationale"]
        )
      end
    end

    def snapshot_revision!(spec, raw_deltas, change_source)
      summary = raw_deltas.map do |d|
        op = d["operation"]&.upcase
        req = d["requirement"] || "new requirement"
        section = d["section"]
        "#{op}: #{section} > #{req}"
      end

      spec.spec_revisions.create!(
        version: spec.version,
        content: spec.content,
        structured_data: spec.structured_data,
        change_source:,
        delta_summary: summary
      )
    rescue => e
      logger.warn { "[Arnold] Failed to snapshot revision: #{e.message}" }
    end

    private

    def openspec_merge(spec, deltas, pipeline_run)
      iteration = pipeline_run&.iterations&.order(:number)&.last
      change_name = iteration ? "iteration-#{iteration.number}" : "user-iterate-#{Time.current.to_i}"

      OpenspecBridge.with_workspace(logger:) do |bridge|
        bridge.write_spec!(spec)
        merged_content = bridge.write_delta_and_merge!(
          change_name:, deltas:
        )

        if merged_content
          spec.update!(content: merged_content, version: spec.version + 1)
          true
        end
      end
    rescue => e
      logger.warn { "[Arnold] OpenSpec merge error: #{e.message}" }
      nil
    end
  end
end

module ArnoldPipeline
  class DeltaPresenter
    def initialize(deltas, from_version:, to_version:)
      @deltas = deltas
      @from_version = from_version
      @to_version = to_version
    end

    def to_s
      lines = [ "Proposed changes to specification (v#{@from_version} → v#{@to_version}):", "" ]
      @deltas.each do |delta|
        lines.concat(format_delta(delta))
        lines << ""
      end
      lines.join("\n")
    end

    def to_json_data
      @deltas.map do |delta|
        {
          operation: delta["operation"],
          section: delta["section"],
          requirement: delta["requirement"],
          rationale: delta["rationale"]
        }.compact
      end
    end

    private

    def format_delta(delta)
      lines = []
      case delta["operation"]
      when "added"
        lines << "  ADDED: #{delta['section']} > #{delta['requirement'] || 'New requirement'}"
        lines << "    #{delta['rationale']}"
      when "modified"
        lines << "  MODIFIED: #{delta['section']} > #{delta['requirement']}"
        if delta["before_content"].present? && delta["after_content"].present?
          lines << "    Before: #{truncate(delta['before_content'], 120)}"
          lines << "    After:  #{truncate(delta['after_content'], 120)}"
        end
        lines << "    Rationale: #{delta['rationale']}"
      when "removed"
        lines << "  REMOVED: #{delta['section']} > #{delta['requirement']}"
        lines << "    Rationale: #{delta['rationale']}"
      end
      lines
    end

    def truncate(text, max)
      clean = text.to_s.gsub(/\s+/, " ").strip
      clean.length > max ? "#{clean[0, max]}..." : clean
    end
  end
end

module ArnoldPipeline
  module TestExecution
    TestResult = Data.define(
      :passed,
      :exit_code,
      :summary,
      :failures,
      :framework,
      :error
    ) do
      def initialize(passed:, exit_code:, summary:, failures: [], framework: nil, error: nil)
        super
      end

      def to_gate_summary
        lines = []
        lines << "## Test Execution Results"
        lines << ""
        lines << "**Overall: #{passed ? 'PASSED' : 'FAILED'}**"
        lines << "- Exit code: #{exit_code}"
        lines << "- Framework: #{framework || 'unknown'}"
        lines << "- Summary: #{summary}"

        if error
          lines << ""
          lines << "### Runner Error"
          lines << error
        end

        if failures.any?
          lines << ""
          lines << "### Failures (#{failures.size})"
          failures.each do |f|
            location = f[:location] ? " (#{f[:location]})" : ""
            lines << "- **#{f[:name]}**#{location}: #{f[:message]}"
          end
        end

        lines.join("\n")
      end
    end
  end
end

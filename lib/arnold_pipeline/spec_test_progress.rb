module ArnoldPipeline
  SpecTestProgress = Data.define(
    :total_tests,
    :total_passing,
    :newly_passing,
    :regressions,
    :still_failing
  ) do
    def initialize(total_tests:, total_passing:, newly_passing: [], regressions: [], still_failing: [])
      super
    end

    def pass_rate
      return 0.0 if total_tests == 0

      (total_passing.to_f / total_tests * 100).round(1)
    end

    def to_gate_summary
      lines = []
      lines << "## Spec-Scenario Test Progression"
      lines << ""
      lines << "**#{total_passing}/#{total_tests} spec-scenario tests passing (#{pass_rate}%)**"

      if newly_passing.any?
        lines << ""
        lines << "### Newly Passing (#{newly_passing.size})"
        newly_passing.each { |t| lines << "- #{t}" }
      end

      if regressions.any?
        lines << ""
        lines << "### Regressions (#{regressions.size})"
        regressions.each { |t| lines << "- #{t}" }
      end

      if still_failing.any?
        lines << ""
        lines << "### Still Failing (#{still_failing.size})"
        still_failing.each { |t| lines << "- #{t}" }
      end

      lines.join("\n")
    end
  end
end

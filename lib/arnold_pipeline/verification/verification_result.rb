module ArnoldPipeline
  module Verification
    VerificationResult = Data.define(
      :setup_passed,
      :boot_passed,
      :health_check_passed,
      :test_passed,
      :errors
    ) do
      def initialize(setup_passed:, boot_passed:, health_check_passed:, test_passed: nil, errors: [])
        super
      end

      def passed?
        setup_passed && boot_passed && health_check_passed && (test_passed.nil? || test_passed)
      end

      def to_gate_summary
        lines = []
        lines << "## Verification Results"
        lines << ""
        lines << "| Step | Result |"
        lines << "|------|--------|"
        lines << "| Setup | #{step_label(setup_passed)} |"
        lines << "| Boot  | #{step_label(boot_passed)} |"
        lines << "| Health Check | #{step_label(health_check_passed)} |"
        lines << "| Test  | #{step_label(test_passed)} |" unless test_passed.nil?
        lines << ""
        lines << "**Overall: #{passed? ? "PASSED" : "FAILED"}**"

        if errors.any?
          lines << ""
          lines << "### Errors"
          errors.each { |e| lines << "- #{e}" }
        end

        lines.join("\n")
      end

      private

      def step_label(value)
        case value
        when true then "PASSED"
        when false then "FAILED"
        when nil then "SKIPPED"
        end
      end
    end
  end
end

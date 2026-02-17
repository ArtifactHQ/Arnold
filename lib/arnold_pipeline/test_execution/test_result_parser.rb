module ArnoldPipeline
  module TestExecution
    class TestResultParser
      def self.call(stdout:, stderr:, exit_code:)
        new(stdout:, stderr:, exit_code:).call
      end

      def initialize(stdout:, stderr:, exit_code:)
        @stdout = stdout.to_s
        @stderr = stderr.to_s
        @exit_code = exit_code
        @combined = "#{@stdout}\n#{@stderr}"
      end

      def call
        result = try_minitest || try_rspec || try_jest || try_pytest || generic_result
        result
      end

      private

      def try_minitest
        # Minitest summary: "X runs, Y assertions, Z failures, W errors, V skips"
        match = @combined.match(/(\d+)\s+runs?,\s*(\d+)\s+assertions?,\s*(\d+)\s+failures?,\s*(\d+)\s+errors?/)
        return nil unless match

        runs = match[1].to_i
        assertions = match[2].to_i
        failures_count = match[3].to_i
        errors_count = match[4].to_i

        summary = "#{runs} runs, #{assertions} assertions, #{failures_count} failures, #{errors_count} errors"
        failures = extract_minitest_failures

        TestResult.new(
          passed: failures_count == 0 && errors_count == 0,
          exit_code: @exit_code,
          summary: summary,
          failures: failures,
          framework: "minitest"
        )
      end

      def extract_minitest_failures
        failures = []

        # Minitest failure blocks look like:
        #   1) Failure:
        # TestName#test_something [path/to/file.rb:42]:
        # Expected true, got false
        @combined.scan(/\d+\)\s+(?:Failure|Error):\n(.+?)(?:\[(.+?)\])?:?\n(.+?)(?=\n\n|\n\d+\)|\z)/m).each do |name, location, message|
          failures << {
            name: name.strip,
            message: message.strip.lines.first&.strip || message.strip,
            location: location&.strip
          }
        end

        failures
      end

      def try_rspec
        # RSpec summary: "X examples, Y failures" or "X examples, Y failures, Z pending"
        match = @combined.match(/(\d+)\s+examples?,\s*(\d+)\s+failures?/)
        return nil unless match

        examples = match[1].to_i
        failures_count = match[2].to_i

        summary = "#{examples} examples, #{failures_count} failures"
        failures = extract_rspec_failures

        TestResult.new(
          passed: failures_count == 0,
          exit_code: @exit_code,
          summary: summary,
          failures: failures,
          framework: "rspec"
        )
      end

      def extract_rspec_failures
        failures = []

        # RSpec failure blocks:
        #   1) Description of failing test
        #      Failure/Error: expect(x).to eq(y)
        #        expected: ...
        #        got: ...
        #      # ./spec/file_spec.rb:42
        @combined.scan(/^\s+\d+\)\s+(.+?)\n\s+(?:Failure\/Error:.+?\n)(.+?)(?=^\s+\d+\)|^Finished|^Failed|\z)/m).each do |name, body|
          location_match = body.match(/#\s+(\S+:\d+)/)
          message = body.lines.reject { |l| l.strip.start_with?("#") }.map(&:strip).reject(&:empty?).first || body.strip

          failures << {
            name: name.strip,
            message: message,
            location: location_match&.[](1)
          }
        end

        failures
      end

      def try_jest
        # Jest summary formats:
        #   "Tests:  5 passed, 5 total"
        #   "Tests:  2 failed, 3 passed, 5 total"
        #   "Tests:  3 failed, 3 total" (all fail, no "passed" segment)
        #   "Tests:  1 skipped, 4 passed, 5 total"
        match = @combined.match(/Tests:\s+.*?(\d+)\s+total/)
        return nil unless match

        total = match[1].to_i
        passed_m = @combined.match(/Tests:\s+.*?(\d+)\s+passed/)
        failed_m = @combined.match(/Tests:\s+.*?(\d+)\s+failed/)
        passed = passed_m ? passed_m[1].to_i : 0
        failed = failed_m ? failed_m[1].to_i : 0

        summary = "#{total} tests, #{passed} passed, #{failed} failed"
        failures = extract_jest_failures

        TestResult.new(
          passed: failed == 0,
          exit_code: @exit_code,
          summary: summary,
          failures: failures,
          framework: "jest"
        )
      end

      def extract_jest_failures
        failures = []

        # Jest failure pattern:
        #   FAIL src/file.test.js
        #     > test description
        #       expect(received).toBe(expected)
        @combined.scan(/FAIL\s+(\S+).*?\n((?:\s+.*\n)*)/m).each do |file, block|
          block.scan(/[x\u2718]\s+(.+)/) do |desc|
            failures << {
              name: desc[0].strip,
              message: "Failed",
              location: file.strip
            }
          end
        end

        # Also try "● test name" pattern
        @combined.scan(/\u25CF\s+(.+?)(?:\n\n|\z)/m).each do |desc|
          name = desc[0].lines.first&.strip || desc[0].strip
          next if failures.any? { |f| f[:name] == name }

          failures << {
            name: name,
            message: desc[0].lines[1..]&.map(&:strip)&.reject(&:empty?)&.first || "Failed",
            location: nil
          }
        end

        failures
      end

      def try_pytest
        # Pytest summary: "= N passed =", "= N passed, M failed =", "= N passed, M warnings ="
        # Also handles "in X.XXs" suffix: "= 10 passed, 3 warnings in 0.34s ="
        match = @combined.match(/=+\s+((?:\d+\s+(?:passed|failed|errors?|warnings?|deselected|xfailed|xpassed)(?:,\s*)?)+)(?:\s+in\s+\S+)?\s*=+/)
        return nil unless match

        result_text = match[1]
        passed_m = result_text.match(/(\d+)\s+passed/)
        failed_m = result_text.match(/(\d+)\s+failed/)
        error_m = result_text.match(/(\d+)\s+errors?/)

        passed_count = passed_m ? passed_m[1].to_i : 0
        failed_count = failed_m ? failed_m[1].to_i : 0
        error_count = error_m ? error_m[1].to_i : 0

        summary = "#{passed_count} passed, #{failed_count} failed"
        summary += ", #{error_count} errors" if error_count > 0
        failures = extract_pytest_failures

        TestResult.new(
          passed: failed_count == 0 && error_count == 0,
          exit_code: @exit_code,
          summary: summary,
          failures: failures,
          framework: "pytest"
        )
      end

      def extract_pytest_failures
        failures = []

        # Pytest FAILED lines: "FAILED tests/test_file.py::test_name - AssertionError: message"
        @combined.scan(/FAILED\s+(\S+?)(?:\s+-\s+(.+))?$/).each do |test_path, message|
          parts = test_path.split("::")
          name = parts.last || test_path
          location = parts.first if parts.size > 1

          failures << {
            name: name,
            message: (message || "Failed").strip,
            location: location
          }
        end

        failures
      end

      def generic_result
        # No framework detected — use exit code and raw output
        output = @stdout.strip
        output = @stderr.strip if output.empty?
        summary = output.lines.last&.strip || "exit code #{@exit_code}"
        # Truncate summary if it's too long — use generous limit so gate
        # issue strings are not cut mid-word (e.g., "TasksControllerTe…")
        summary = summary[0, 2000] if summary.length > 2000

        TestResult.new(
          passed: @exit_code == 0,
          exit_code: @exit_code,
          summary: summary,
          failures: [],
          framework: nil
        )
      end
    end
  end
end

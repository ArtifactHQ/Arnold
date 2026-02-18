require "test_helper"
require "arnold_pipeline/test_execution/test_result"

module ArnoldPipeline
  module TestExecution
    class TestResultTest < ActiveSupport::TestCase
      test "passed result with defaults" do
        result = TestResult.new(
          passed: true,
          exit_code: 0,
          summary: "14 tests, 0 failures"
        )

        assert result.passed
        assert_equal 0, result.exit_code
        assert_equal "14 tests, 0 failures", result.summary
        assert_equal [], result.failures
        assert_nil result.framework
        assert_nil result.error
      end

      test "failed result with failures" do
        result = TestResult.new(
          passed: false,
          exit_code: 1,
          summary: "14 tests, 2 failures",
          failures: [
            { name: "test_login", message: "Expected 200, got 401", location: "test/auth_test.rb:42" }
          ],
          framework: "minitest"
        )

        refute result.passed
        assert_equal 1, result.exit_code
        assert_equal 1, result.failures.size
        assert_equal "minitest", result.framework
      end

      test "result with error" do
        result = TestResult.new(
          passed: false,
          exit_code: -1,
          summary: "boot command failed",
          error: "Boot timed out after 60s"
        )

        refute result.passed
        assert_equal "Boot timed out after 60s", result.error
      end

      test "to_gate_summary includes overall status" do
        result = TestResult.new(
          passed: true,
          exit_code: 0,
          summary: "14 tests, 0 failures",
          framework: "minitest"
        )

        summary = result.to_gate_summary

        assert_includes summary, "## Test Execution Results"
        assert_includes summary, "**Overall: PASSED**"
        assert_includes summary, "Exit code: 0"
        assert_includes summary, "Framework: minitest"
        assert_includes summary, "Summary: 14 tests, 0 failures"
        refute_includes summary, "### Failures"
        refute_includes summary, "### Runner Error"
      end

      test "to_gate_summary shows FAILED for failing tests" do
        result = TestResult.new(
          passed: false,
          exit_code: 1,
          summary: "14 tests, 2 failures",
          framework: "rspec"
        )

        summary = result.to_gate_summary
        assert_includes summary, "**Overall: FAILED**"
      end

      test "to_gate_summary includes failures section" do
        result = TestResult.new(
          passed: false,
          exit_code: 1,
          summary: "14 tests, 2 failures",
          failures: [
            { name: "test_login", message: "Expected 200, got 401", location: "test/auth_test.rb:42" },
            { name: "test_signup", message: "Timeout", location: nil }
          ],
          framework: "minitest"
        )

        summary = result.to_gate_summary

        assert_includes summary, "### Failures (2)"
        assert_includes summary, "**test_login** (test/auth_test.rb:42): Expected 200, got 401"
        assert_includes summary, "**test_signup**: Timeout"
      end

      test "to_gate_summary includes error section" do
        result = TestResult.new(
          passed: false,
          exit_code: -1,
          summary: "boot command failed",
          error: "Boot command timed out after 60s"
        )

        summary = result.to_gate_summary

        assert_includes summary, "### Runner Error"
        assert_includes summary, "Boot command timed out after 60s"
      end

      test "hollow defaults to false" do
        result = TestResult.new(
          passed: true,
          exit_code: 0,
          summary: "14 tests, 0 failures"
        )

        refute result.hollow
      end

      test "hollow result" do
        result = TestResult.new(
          passed: false,
          exit_code: 0,
          summary: "0 runs, 0 assertions, 0 failures, 0 errors",
          framework: "minitest",
          hollow: true
        )

        refute result.passed
        assert result.hollow
      end

      test "to_gate_summary includes hollow warning" do
        result = TestResult.new(
          passed: false,
          exit_code: 0,
          summary: "0 runs, 0 assertions, 0 failures, 0 errors",
          framework: "minitest",
          hollow: true
        )

        summary = result.to_gate_summary

        assert_includes summary, "WARNING: Test suite exited with 0 runs"
      end

      test "to_gate_summary excludes hollow warning when not hollow" do
        result = TestResult.new(
          passed: true,
          exit_code: 0,
          summary: "14 tests, 0 failures",
          framework: "minitest"
        )

        summary = result.to_gate_summary

        refute_includes summary, "WARNING"
      end

      test "to_gate_summary shows unknown framework when nil" do
        result = TestResult.new(
          passed: true,
          exit_code: 0,
          summary: "ok"
        )

        summary = result.to_gate_summary
        assert_includes summary, "Framework: unknown"
      end
    end
  end
end

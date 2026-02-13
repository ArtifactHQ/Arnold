require "test_helper"
require "arnold_pipeline/verification/verification_result"

module ArnoldPipeline
  module Verification
    class VerificationResultTest < ActiveSupport::TestCase
      test "all steps passed returns passed?" do
        result = VerificationResult.new(
          setup_passed: true,
          boot_passed: true,
          health_check_passed: true
        )

        assert result.passed?
      end

      test "all steps passed with test_passed true returns passed?" do
        result = VerificationResult.new(
          setup_passed: true,
          boot_passed: true,
          health_check_passed: true,
          test_passed: true
        )

        assert result.passed?
      end

      test "nil test_passed is treated as skipped and does not fail" do
        result = VerificationResult.new(
          setup_passed: true,
          boot_passed: true,
          health_check_passed: true,
          test_passed: nil
        )

        assert result.passed?
      end

      test "failed setup returns not passed" do
        result = VerificationResult.new(
          setup_passed: false,
          boot_passed: false,
          health_check_passed: false,
          errors: ["Setup command failed"]
        )

        refute result.passed?
      end

      test "failed health check returns not passed" do
        result = VerificationResult.new(
          setup_passed: true,
          boot_passed: true,
          health_check_passed: false,
          errors: ["Health check failed"]
        )

        refute result.passed?
      end

      test "failed test returns not passed" do
        result = VerificationResult.new(
          setup_passed: true,
          boot_passed: true,
          health_check_passed: true,
          test_passed: false,
          errors: ["Test command failed"]
        )

        refute result.passed?
      end

      test "defaults test_passed to nil and errors to empty" do
        result = VerificationResult.new(
          setup_passed: true,
          boot_passed: true,
          health_check_passed: true
        )

        assert_nil result.test_passed
        assert_equal [], result.errors
      end

      test "to_gate_summary includes all step results" do
        result = VerificationResult.new(
          setup_passed: true,
          boot_passed: true,
          health_check_passed: false,
          errors: ["Health check timed out"]
        )

        summary = result.to_gate_summary

        assert_includes summary, "## Verification Results"
        assert_includes summary, "| Setup | PASSED |"
        assert_includes summary, "| Boot  | PASSED |"
        assert_includes summary, "| Health Check | FAILED |"
        assert_includes summary, "**Overall: FAILED**"
        assert_includes summary, "Health check timed out"
      end

      test "to_gate_summary shows PASSED overall when all pass" do
        result = VerificationResult.new(
          setup_passed: true,
          boot_passed: true,
          health_check_passed: true
        )

        summary = result.to_gate_summary

        assert_includes summary, "**Overall: PASSED**"
        refute_includes summary, "### Errors"
      end

      test "to_gate_summary includes test row when test_passed is non-nil" do
        result = VerificationResult.new(
          setup_passed: true,
          boot_passed: true,
          health_check_passed: true,
          test_passed: true
        )

        summary = result.to_gate_summary
        assert_includes summary, "| Test  | PASSED |"
      end

      test "to_gate_summary omits test row when test_passed is nil" do
        result = VerificationResult.new(
          setup_passed: true,
          boot_passed: true,
          health_check_passed: true,
          test_passed: nil
        )

        summary = result.to_gate_summary
        refute_includes summary, "| Test  |"
      end

      test "to_gate_summary shows multiple errors" do
        result = VerificationResult.new(
          setup_passed: false,
          boot_passed: false,
          health_check_passed: false,
          errors: ["Setup failed: missing bin/setup", "Boot failed: command not found"]
        )

        summary = result.to_gate_summary
        assert_includes summary, "- Setup failed: missing bin/setup"
        assert_includes summary, "- Boot failed: command not found"
      end
    end
  end
end

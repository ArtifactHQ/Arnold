require "test_helper"
require "arnold_pipeline/verification_check"

module ArnoldPipeline
  class VerificationCheckTest < ActiveSupport::TestCase
    cover "ArnoldPipeline::VerificationCheck*"

    test "defaults type to :custom" do
      check = VerificationCheck.new(name: "lint", command: "rubocop")
      assert_equal :custom, check.type
    end

    test "defaults required to false" do
      check = VerificationCheck.new(name: "lint", command: "rubocop")
      assert_equal false, check.required
      refute check.required?
    end

    test "coerces string type to symbol" do
      check = VerificationCheck.new(name: "boot", command: "rails server", type: "boot")
      assert_equal :boot, check.type
    end

    # --- Check Type Registry ---

    test "CHECK_TYPE_DEFAULTS includes solid_stack with default_tier 0" do
      defaults = VerificationCheck::CHECK_TYPE_DEFAULTS[:solid_stack]
      assert_equal 0, defaults[:default_tier]
      assert defaults[:tier_gate]
      assert defaults[:finalization]
    end

    test "CHECK_TYPE_DEFAULTS includes boot with default_tier 0" do
      defaults = VerificationCheck::CHECK_TYPE_DEFAULTS[:boot]
      assert_equal 0, defaults[:default_tier]
    end

    test "CHECK_TYPE_DEFAULTS includes test_suite with nil default_tier" do
      defaults = VerificationCheck::CHECK_TYPE_DEFAULTS[:test_suite]
      assert_nil defaults[:default_tier]
      assert defaults[:tier_gate]
      refute defaults[:finalization]
    end

    test "CHECK_TYPE_DEFAULTS includes custom with nil default_tier" do
      defaults = VerificationCheck::CHECK_TYPE_DEFAULTS[:custom]
      assert_nil defaults[:default_tier]
    end

    test "scheduled_for_tier? returns true when default_tier matches" do
      check = VerificationCheck.new(name: "Solid stack", type: :solid_stack, required: true)
      assert check.scheduled_for_tier?(0)
      refute check.scheduled_for_tier?(1)
    end

    test "scheduled_for_tier? returns true for all tiers when default_tier is nil" do
      check = VerificationCheck.new(name: "Custom", command: "echo ok", type: :custom)
      assert check.scheduled_for_tier?(0)
      assert check.scheduled_for_tier?(3)
    end

    test "eligible_for_finalization? returns true for solid_stack" do
      check = VerificationCheck.new(name: "Solid stack", type: :solid_stack, required: true)
      assert check.eligible_for_finalization?
    end

    test "eligible_for_finalization? returns false for test_suite" do
      check = VerificationCheck.new(name: "Tests", command: "bin/rails test", type: :test_suite)
      refute check.eligible_for_finalization?
    end
  end
end

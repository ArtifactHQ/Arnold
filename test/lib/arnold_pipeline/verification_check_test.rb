require "test_helper"
require "arnold_pipeline/verification_check"

module ArnoldPipeline
  class VerificationCheckTest < ActiveSupport::TestCase
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
  end
end

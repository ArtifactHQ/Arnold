require "test_helper"
require "arnold_pipeline/spec_test_progress"

module ArnoldPipeline
  class SpecTestProgressTest < ActiveSupport::TestCase
    cover "ArnoldPipeline::SpecTestProgress*"

    test "initializes with defaults" do
      progress = SpecTestProgress.new(total_tests: 10, total_passing: 3)

      assert_equal 10, progress.total_tests
      assert_equal 3, progress.total_passing
      assert_equal [], progress.newly_passing
      assert_equal [], progress.regressions
      assert_equal [], progress.still_failing
    end

    test "initializes with all fields" do
      progress = SpecTestProgress.new(
        total_tests: 20,
        total_passing: 15,
        newly_passing: [ "test_login", "test_signup" ],
        regressions: [ "test_logout" ],
        still_failing: [ "test_admin", "test_reset" ]
      )

      assert_equal 20, progress.total_tests
      assert_equal 15, progress.total_passing
      assert_equal [ "test_login", "test_signup" ], progress.newly_passing
      assert_equal [ "test_logout" ], progress.regressions
      assert_equal [ "test_admin", "test_reset" ], progress.still_failing
    end

    test "pass_rate calculates percentage" do
      progress = SpecTestProgress.new(total_tests: 20, total_passing: 15)
      assert_equal 75.0, progress.pass_rate
    end

    test "pass_rate returns 0.0 for zero tests" do
      progress = SpecTestProgress.new(total_tests: 0, total_passing: 0)
      assert_equal 0.0, progress.pass_rate
    end

    test "pass_rate returns 100.0 when all pass" do
      progress = SpecTestProgress.new(total_tests: 10, total_passing: 10)
      assert_equal 100.0, progress.pass_rate
    end

    test "pass_rate rounds to one decimal" do
      progress = SpecTestProgress.new(total_tests: 3, total_passing: 1)
      assert_equal 33.3, progress.pass_rate
    end

    test "to_gate_summary includes passing count and rate" do
      progress = SpecTestProgress.new(total_tests: 20, total_passing: 8)
      summary = progress.to_gate_summary

      assert_includes summary, "8/20 spec-scenario tests passing (40.0%)"
    end

    test "to_gate_summary includes newly passing tests" do
      progress = SpecTestProgress.new(
        total_tests: 20,
        total_passing: 8,
        newly_passing: [ "test_login", "test_signup" ]
      )
      summary = progress.to_gate_summary

      assert_includes summary, "Newly Passing (2)"
      assert_includes summary, "- test_login"
      assert_includes summary, "- test_signup"
    end

    test "to_gate_summary includes regressions" do
      progress = SpecTestProgress.new(
        total_tests: 20,
        total_passing: 8,
        regressions: [ "test_logout" ]
      )
      summary = progress.to_gate_summary

      assert_includes summary, "Regressions (1)"
      assert_includes summary, "- test_logout"
    end

    test "to_gate_summary includes still failing tests" do
      progress = SpecTestProgress.new(
        total_tests: 20,
        total_passing: 8,
        still_failing: [ "test_admin", "test_reset" ]
      )
      summary = progress.to_gate_summary

      assert_includes summary, "Still Failing (2)"
      assert_includes summary, "- test_admin"
      assert_includes summary, "- test_reset"
    end

    test "to_gate_summary omits empty sections" do
      progress = SpecTestProgress.new(total_tests: 10, total_passing: 10)
      summary = progress.to_gate_summary

      refute_includes summary, "Newly Passing"
      refute_includes summary, "Regressions"
      refute_includes summary, "Still Failing"
    end

    test "Data.define creates frozen immutable object" do
      progress = SpecTestProgress.new(total_tests: 5, total_passing: 2)
      assert progress.frozen?
    end
  end
end

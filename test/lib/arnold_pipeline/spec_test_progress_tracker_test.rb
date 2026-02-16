require "test_helper"
require "arnold_pipeline/test_execution/test_result"
require "arnold_pipeline/test_execution/test_result_parser"
require "arnold_pipeline/test_execution/test_runner"
require "arnold_pipeline/spec_test_progress_tracker"

module ArnoldPipeline
  class SpecTestProgressTrackerTest < ActiveSupport::TestCase
    setup do
      @repo_path = Dir.mktmpdir
      @test_directory = "test/spec_integration"
      @test_dir_abs = File.join(@repo_path, @test_directory)
      FileUtils.mkdir_p(@test_dir_abs)

      ArnoldPipeline.configure do |c|
        c.test_timeout = 30
      end
    end

    teardown do
      FileUtils.rm_rf(@repo_path)
      ArnoldPipeline.reset_configuration!
    end

    test "returns zero progress when test directory does not exist" do
      FileUtils.rm_rf(@test_dir_abs)

      progress = SpecTestProgressTracker.call(
        repo_path: @repo_path,
        test_directory: @test_directory
      )

      assert_equal 0, progress.total_tests
      assert_equal 0, progress.total_passing
      assert_equal [], progress.newly_passing
      assert_equal [], progress.regressions
      assert_equal [], progress.still_failing
    end

    test "runs spec tests and returns progress" do
      # Write a simple test file
      File.write(File.join(@test_dir_abs, "sample_test.rb"), <<~RUBY)
        require "minitest/autorun"
        class SampleTest < Minitest::Test
          def test_passing
            assert true
          end
          def test_failing
            assert false, "Expected failure"
          end
        end
      RUBY

      test_result = TestExecution::TestResult.new(
        passed: false,
        exit_code: 1,
        summary: "2 runs, 2 assertions, 1 failures, 0 errors",
        failures: [
          { name: "SampleTest#test_failing", message: "Expected failure", location: "sample_test.rb:7" }
        ],
        framework: "minitest"
      )

      TestExecution::TestRunner.expects(:call).returns(test_result)

      progress = SpecTestProgressTracker.call(
        repo_path: @repo_path,
        test_directory: @test_directory
      )

      assert_equal 2, progress.total_tests
      assert_equal 1, progress.total_passing
      assert_includes progress.still_failing, "SampleTest#test_failing"
    end

    test "computes newly passing tests from previous results" do
      File.write(File.join(@test_dir_abs, "test.rb"), "placeholder")

      test_result = TestExecution::TestResult.new(
        passed: false,
        exit_code: 1,
        summary: "3 runs, 3 assertions, 1 failures, 0 errors",
        failures: [
          { name: "TestC#test_c", message: "still fails", location: "test.rb:3" }
        ],
        framework: "minitest"
      )

      TestExecution::TestRunner.expects(:call).returns(test_result)

      previous_results = {
        "failed_names" => ["TestA#test_a", "TestB#test_b", "TestC#test_c"]
      }

      progress = SpecTestProgressTracker.call(
        repo_path: @repo_path,
        test_directory: @test_directory,
        previous_results: previous_results
      )

      assert_equal 3, progress.total_tests
      assert_equal 2, progress.total_passing
      assert_includes progress.newly_passing, "TestA#test_a"
      assert_includes progress.newly_passing, "TestB#test_b"
      assert_equal ["TestC#test_c"], progress.still_failing
      assert_equal [], progress.regressions
    end

    test "detects regressions from previous results" do
      File.write(File.join(@test_dir_abs, "test.rb"), "placeholder")

      test_result = TestExecution::TestResult.new(
        passed: false,
        exit_code: 1,
        summary: "3 runs, 3 assertions, 2 failures, 0 errors",
        failures: [
          { name: "TestA#test_a", message: "still fails", location: "test.rb:1" },
          { name: "TestB#test_b", message: "new failure", location: "test.rb:2" }
        ],
        framework: "minitest"
      )

      TestExecution::TestRunner.expects(:call).returns(test_result)

      previous_results = {
        "failed_names" => ["TestA#test_a"]
      }

      progress = SpecTestProgressTracker.call(
        repo_path: @repo_path,
        test_directory: @test_directory,
        previous_results: previous_results
      )

      assert_equal 3, progress.total_tests
      assert_equal 1, progress.total_passing
      assert_equal ["TestA#test_a"], progress.still_failing
      assert_includes progress.regressions, "TestB#test_b"
      assert_equal [], progress.newly_passing
    end

    test "handles all tests passing" do
      File.write(File.join(@test_dir_abs, "test.rb"), "placeholder")

      test_result = TestExecution::TestResult.new(
        passed: true,
        exit_code: 0,
        summary: "5 runs, 10 assertions, 0 failures, 0 errors",
        failures: [],
        framework: "minitest"
      )

      TestExecution::TestRunner.expects(:call).returns(test_result)

      progress = SpecTestProgressTracker.call(
        repo_path: @repo_path,
        test_directory: @test_directory
      )

      assert_equal 5, progress.total_tests
      assert_equal 5, progress.total_passing
      assert_equal [], progress.still_failing
      assert_equal [], progress.regressions
    end

    test "without previous results treats all failures as still_failing" do
      File.write(File.join(@test_dir_abs, "test.rb"), "placeholder")

      test_result = TestExecution::TestResult.new(
        passed: false,
        exit_code: 1,
        summary: "4 runs, 4 assertions, 3 failures, 0 errors",
        failures: [
          { name: "TestA", message: "fail", location: nil },
          { name: "TestB", message: "fail", location: nil },
          { name: "TestC", message: "fail", location: nil }
        ],
        framework: "minitest"
      )

      TestExecution::TestRunner.expects(:call).returns(test_result)

      progress = SpecTestProgressTracker.call(
        repo_path: @repo_path,
        test_directory: @test_directory
      )

      assert_equal 4, progress.total_tests
      assert_equal 1, progress.total_passing
      assert_equal 3, progress.still_failing.size
      assert_equal [], progress.newly_passing
      assert_equal [], progress.regressions
    end
  end
end

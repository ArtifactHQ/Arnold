require "test_helper"
require "arnold_pipeline/test_execution/test_result"
require "arnold_pipeline/test_execution/test_result_parser"

module ArnoldPipeline
  module TestExecution
    class TestResultParserTest < ActiveSupport::TestCase
      # --- Minitest ---

      test "parses minitest passing output" do
        stdout = <<~OUTPUT
          Running 14 tests...
          ..............
          14 runs, 28 assertions, 0 failures, 0 errors, 0 skips
        OUTPUT

        result = TestResultParser.call(stdout: stdout, stderr: "", exit_code: 0)

        assert result.passed
        assert_equal "minitest", result.framework
        assert_equal "14 runs, 28 assertions, 0 failures, 0 errors", result.summary
        assert_empty result.failures
      end

      test "parses minitest failing output" do
        stdout = <<~OUTPUT
          Running 14 tests...
          ..........F.E.

          1) Failure:
          AuthTest#test_login [test/auth_test.rb:42]:
          Expected 200, got 401

          2) Error:
          AuthTest#test_signup [test/auth_test.rb:58]:
          NoMethodError: undefined method `create_user'

          14 runs, 28 assertions, 1 failures, 1 errors, 0 skips
        OUTPUT

        result = TestResultParser.call(stdout: stdout, stderr: "", exit_code: 1)

        refute result.passed
        assert_equal "minitest", result.framework
        assert_equal "14 runs, 28 assertions, 1 failures, 1 errors", result.summary
        assert_equal 2, result.failures.size
        assert_equal "AuthTest#test_login", result.failures[0][:name]
        assert_includes result.failures[0][:message], "Expected 200, got 401"
      end

      test "parses minitest singular forms (1 run, 1 assertion)" do
        stdout = "1 run, 1 assertion, 0 failures, 0 errors, 0 skips"

        result = TestResultParser.call(stdout: stdout, stderr: "", exit_code: 0)

        assert result.passed
        assert_equal "minitest", result.framework
        assert_equal "1 runs, 1 assertions, 0 failures, 0 errors", result.summary
      end

      # --- RSpec ---

      test "parses rspec passing output" do
        stdout = <<~OUTPUT
          ......

          Finished in 0.5 seconds
          6 examples, 0 failures
        OUTPUT

        result = TestResultParser.call(stdout: stdout, stderr: "", exit_code: 0)

        assert result.passed
        assert_equal "rspec", result.framework
        assert_equal "6 examples, 0 failures", result.summary
      end

      test "parses rspec failing output" do
        stdout = <<~OUTPUT
          .F..

          Failures:

            1) User login validates credentials
               Failure/Error: expect(response.status).to eq(200)
                 expected: 200
                      got: 401
               # ./spec/auth_spec.rb:42

          Finished in 0.8 seconds
          4 examples, 1 failure
        OUTPUT

        result = TestResultParser.call(stdout: stdout, stderr: "", exit_code: 1)

        refute result.passed
        assert_equal "rspec", result.framework
        assert_equal "4 examples, 1 failures", result.summary
      end

      # --- Jest ---

      test "parses jest passing output" do
        stdout = <<~OUTPUT
          PASS src/auth.test.js
          PASS src/api.test.js

          Test Suites: 2 passed, 2 total
          Tests:       8 passed, 8 total
          Snapshots:   0 total
          Time:        1.5s
        OUTPUT

        result = TestResultParser.call(stdout: stdout, stderr: "", exit_code: 0)

        assert result.passed
        assert_equal "jest", result.framework
        assert_equal "8 tests, 8 passed, 0 failed", result.summary
      end

      test "parses jest failing output" do
        stdout = <<~OUTPUT
          PASS src/api.test.js
          FAIL src/auth.test.js

          Test Suites: 1 failed, 1 passed, 2 total
          Tests:       2 failed, 6 passed, 8 total
          Snapshots:   0 total
          Time:        2.1s
        OUTPUT

        result = TestResultParser.call(stdout: stdout, stderr: "", exit_code: 1)

        refute result.passed
        assert_equal "jest", result.framework
        assert_equal "8 tests, 6 passed, 2 failed", result.summary
      end

      test "parses jest all-fail output (no passed segment)" do
        stdout = <<~OUTPUT
          FAIL src/auth.test.js

          Test Suites: 1 failed, 1 total
          Tests:       3 failed, 3 total
          Snapshots:   0 total
          Time:        0.8s
        OUTPUT

        result = TestResultParser.call(stdout: stdout, stderr: "", exit_code: 1)

        refute result.passed
        assert_equal "jest", result.framework
        assert_equal "3 tests, 0 passed, 3 failed", result.summary
      end

      test "parses jest output with skipped tests" do
        stdout = <<~OUTPUT
          Test Suites: 1 passed, 1 total
          Tests:       1 skipped, 4 passed, 5 total
          Snapshots:   0 total
        OUTPUT

        result = TestResultParser.call(stdout: stdout, stderr: "", exit_code: 0)

        assert result.passed
        assert_equal "jest", result.framework
        assert_equal "5 tests, 4 passed, 0 failed", result.summary
      end

      # --- Pytest ---

      test "parses pytest passing output" do
        stdout = <<~OUTPUT
          ============================= test session starts ==============================
          collected 10 items

          tests/test_auth.py ......                                               [ 60%]
          tests/test_api.py ....                                                   [100%]

          ============================== 10 passed ==============================
        OUTPUT

        result = TestResultParser.call(stdout: stdout, stderr: "", exit_code: 0)

        assert result.passed
        assert_equal "pytest", result.framework
        assert_equal "10 passed, 0 failed", result.summary
      end

      test "parses pytest failing output" do
        stdout = <<~OUTPUT
          ============================= test session starts ==============================
          collected 10 items

          tests/test_auth.py ...F..                                                [ 60%]
          tests/test_api.py ....                                                   [100%]

          FAILED tests/test_auth.py::test_login - AssertionError: expected 200
          FAILED tests/test_auth.py::test_signup - TimeoutError: connection refused

          ========================= 8 passed, 2 failed =========================
        OUTPUT

        result = TestResultParser.call(stdout: stdout, stderr: "", exit_code: 1)

        refute result.passed
        assert_equal "pytest", result.framework
        assert_equal "8 passed, 2 failed", result.summary
        assert_equal 2, result.failures.size
        assert_equal "test_login", result.failures[0][:name]
        assert_equal "AssertionError: expected 200", result.failures[0][:message]
        assert_equal "tests/test_auth.py", result.failures[0][:location]
      end

      test "parses pytest with warnings" do
        stdout = <<~OUTPUT
          ============================= test session starts ==============================
          collected 10 items

          tests/test_auth.py ..........                                              [100%]

          ============================== 10 passed, 3 warnings in 0.34s ==============================
        OUTPUT

        result = TestResultParser.call(stdout: stdout, stderr: "", exit_code: 0)

        assert result.passed
        assert_equal "pytest", result.framework
        assert_equal "10 passed, 0 failed", result.summary
      end

      test "parses pytest with failures and warnings" do
        stdout = <<~OUTPUT
          FAILED tests/test_auth.py::test_login - AssertionError

          ========================= 8 passed, 2 failed, 1 warning in 1.2s =========================
        OUTPUT

        result = TestResultParser.call(stdout: stdout, stderr: "", exit_code: 1)

        refute result.passed
        assert_equal "pytest", result.framework
        assert_equal "8 passed, 2 failed", result.summary
      end

      test "parses pytest with errors" do
        stdout = <<~OUTPUT
          ============================= test session starts ==============================
          ========================= 3 passed, 1 failed, 2 error =========================
        OUTPUT

        result = TestResultParser.call(stdout: stdout, stderr: "", exit_code: 1)

        refute result.passed
        assert_equal "pytest", result.framework
        assert_includes result.summary, "2 errors"
      end

      # --- Generic fallback ---

      test "returns generic result for unknown framework" do
        stdout = "All checks passed successfully"

        result = TestResultParser.call(stdout: stdout, stderr: "", exit_code: 0)

        assert result.passed
        assert_nil result.framework
        assert_equal "All checks passed successfully", result.summary
        assert_empty result.failures
      end

      test "generic result uses exit code for pass/fail" do
        result = TestResultParser.call(stdout: "something failed", stderr: "", exit_code: 1)

        refute result.passed
        assert_nil result.framework
        assert_equal 1, result.exit_code
      end

      test "generic result uses stderr when stdout is empty" do
        result = TestResultParser.call(stdout: "", stderr: "error: command not found", exit_code: 127)

        refute result.passed
        assert_equal "error: command not found", result.summary
      end

      test "generic result truncates very long summary at 2000 chars" do
        long_output = "x" * 3000
        result = TestResultParser.call(stdout: long_output, stderr: "", exit_code: 0)

        assert result.summary.length <= 2000
      end

      test "generic result preserves summaries under 2000 chars without truncation" do
        # Simulate a realistic long line (e.g., 500 char test name + message)
        long_output = "TasksControllerTest#test_should_handle_authentication" + ("_extra" * 50) + ": Expected 200 got 401"
        result = TestResultParser.call(stdout: long_output, stderr: "", exit_code: 1)

        assert_equal long_output.strip, result.summary
      end

      # --- Output in stderr ---

      test "detects framework from stderr when stdout is empty" do
        stderr = "14 runs, 28 assertions, 0 failures, 0 errors, 0 skips"

        result = TestResultParser.call(stdout: "", stderr: stderr, exit_code: 0)

        assert_equal "minitest", result.framework
        assert result.passed
      end
    end
  end
end

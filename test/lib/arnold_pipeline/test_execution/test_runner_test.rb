require "test_helper"
require "arnold_pipeline/test_execution/test_result"
require "arnold_pipeline/test_execution/test_result_parser"
require "arnold_pipeline/test_execution/test_runner"

module ArnoldPipeline
  module TestExecution
    class TestRunnerTest < ActiveSupport::TestCase
      setup do
        @repo_path = "/tmp/test_repo"
      end

      # --- Test command execution ---

      test "runs provided test command and returns parsed result" do
        mock_status = stub(success?: true, exitstatus: 0)
        stdout = "14 runs, 28 assertions, 0 failures, 0 errors, 0 skips"
        Open3.stubs(:capture3).with("bin/rails test", chdir: @repo_path).returns([ stdout, "", mock_status ])

        result = TestRunner.call(repo_path: @repo_path, test_command: "bin/rails test")

        assert result.passed
        assert_equal "minitest", result.framework
        assert_equal 0, result.exit_code
      end

      test "returns failed result for failing tests" do
        mock_status = stub(success?: false, exitstatus: 1)
        stdout = "14 runs, 28 assertions, 2 failures, 0 errors, 0 skips"
        Open3.stubs(:capture3).with("bundle exec rspec", chdir: @repo_path).returns([ stdout, "", mock_status ])

        result = TestRunner.call(repo_path: @repo_path, test_command: "bundle exec rspec")

        refute result.passed
        assert_equal 1, result.exit_code
      end

      # --- Boot command ---

      test "runs boot command before tests" do
        boot_status = stub(success?: true, exitstatus: 0)
        test_status = stub(success?: true, exitstatus: 0)

        seq = sequence("execution")
        Open3.expects(:capture3).with("bin/setup", chdir: @repo_path).returns([ "ok", "", boot_status ]).in_sequence(seq)
        Open3.expects(:capture3).with("npm test", chdir: @repo_path).returns([ "Tests:  5 passed, 5 total", "", test_status ]).in_sequence(seq)

        result = TestRunner.call(
          repo_path: @repo_path,
          test_command: "npm test",
          boot_command: "bin/setup"
        )

        assert result.passed
      end

      test "returns error result when boot command fails" do
        boot_status = stub(success?: false, exitstatus: 1)
        Open3.stubs(:capture3).with("bin/setup", chdir: @repo_path).returns([ "", "missing deps", boot_status ])

        result = TestRunner.call(
          repo_path: @repo_path,
          test_command: "npm test",
          boot_command: "bin/setup"
        )

        refute result.passed
        assert_equal "boot command failed", result.summary
        assert_includes result.error, "bin/setup"
        assert_includes result.error, "missing deps"
      end

      test "returns error result when boot command times out" do
        Timeout.stubs(:timeout).with(30).raises(Timeout::Error)

        result = TestRunner.call(
          repo_path: @repo_path,
          test_command: "npm test",
          boot_command: "bin/setup",
          boot_timeout: 30
        )

        refute result.passed
        assert_equal "boot command timed out", result.summary
        assert_includes result.error, "30s"
      end

      test "returns error result when boot command raises" do
        Open3.stubs(:capture3).with("bin/setup", chdir: @repo_path).raises(Errno::ENOENT, "No such file")

        result = TestRunner.call(
          repo_path: @repo_path,
          test_command: "npm test",
          boot_command: "bin/setup"
        )

        refute result.passed
        assert_equal "boot command error", result.summary
        assert_includes result.error, "No such file"
      end

      # --- Test command detection ---

      test "detects bin/rails test command" do
        File.stubs(:exist?).returns(false)
        File.stubs(:exist?).with(File.join(@repo_path, "bin/rails")).returns(true)

        mock_status = stub(success?: true, exitstatus: 0)
        Open3.expects(:capture3).with("bin/rails test", chdir: @repo_path).returns([ "5 runs, 10 assertions, 0 failures, 0 errors", "", mock_status ])

        result = TestRunner.call(repo_path: @repo_path)

        assert result.passed
      end

      test "detects bundle exec rspec for Gemfile with rspec" do
        File.stubs(:exist?).returns(false)
        File.stubs(:exist?).with(File.join(@repo_path, "bin/rails")).returns(false)
        File.stubs(:exist?).with(File.join(@repo_path, "Gemfile")).returns(true)
        File.stubs(:read).with(File.join(@repo_path, "Gemfile")).returns("gem 'rspec-rails'")

        mock_status = stub(success?: true, exitstatus: 0)
        Open3.expects(:capture3).with("bundle exec rspec", chdir: @repo_path).returns([ "6 examples, 0 failures", "", mock_status ])

        result = TestRunner.call(repo_path: @repo_path)

        assert result.passed
        assert_equal "rspec", result.framework
      end

      test "detects npm test for package.json" do
        File.stubs(:exist?).returns(false)
        File.stubs(:exist?).with(File.join(@repo_path, "bin/rails")).returns(false)
        File.stubs(:exist?).with(File.join(@repo_path, "Gemfile")).returns(false)
        File.stubs(:exist?).with(File.join(@repo_path, "package.json")).returns(true)

        mock_status = stub(success?: true, exitstatus: 0)
        Open3.expects(:capture3).with("npm test", chdir: @repo_path).returns([ "Tests:  5 passed, 5 total", "", mock_status ])

        result = TestRunner.call(repo_path: @repo_path)

        assert result.passed
      end

      test "detects pytest for pytest.ini" do
        File.stubs(:exist?).returns(false)
        File.stubs(:exist?).with(File.join(@repo_path, "bin/rails")).returns(false)
        File.stubs(:exist?).with(File.join(@repo_path, "Gemfile")).returns(false)
        File.stubs(:exist?).with(File.join(@repo_path, "package.json")).returns(false)
        File.stubs(:exist?).with(File.join(@repo_path, "pytest.ini")).returns(true)

        mock_status = stub(success?: true, exitstatus: 0)
        Open3.expects(:capture3).with("pytest", chdir: @repo_path).returns([ "============================== 5 passed ==============================", "", mock_status ])

        result = TestRunner.call(repo_path: @repo_path)

        assert result.passed
        assert_equal "pytest", result.framework
      end

      test "detects pytest for pyproject.toml" do
        File.stubs(:exist?).returns(false)
        File.stubs(:exist?).with(File.join(@repo_path, "bin/rails")).returns(false)
        File.stubs(:exist?).with(File.join(@repo_path, "Gemfile")).returns(false)
        File.stubs(:exist?).with(File.join(@repo_path, "package.json")).returns(false)
        File.stubs(:exist?).with(File.join(@repo_path, "pytest.ini")).returns(false)
        File.stubs(:exist?).with(File.join(@repo_path, "pyproject.toml")).returns(true)

        mock_status = stub(success?: true, exitstatus: 0)
        Open3.expects(:capture3).with("pytest", chdir: @repo_path).returns([ "============================== 3 passed ==============================", "", mock_status ])

        result = TestRunner.call(repo_path: @repo_path)

        assert result.passed
      end

      # --- Error handling ---

      test "returns error when no test command detected" do
        File.stubs(:exist?).returns(false)

        result = TestRunner.call(repo_path: @repo_path)

        refute result.passed
        assert_equal -1, result.exit_code
        assert_equal "no test suite found", result.summary
        assert_includes result.error, "Could not detect"
      end

      test "returns error when test command times out" do
        Timeout.stubs(:timeout).with(60).raises(Timeout::Error)

        result = TestRunner.call(
          repo_path: @repo_path,
          test_command: "bin/rails test",
          timeout: 60
        )

        refute result.passed
        assert_equal -1, result.exit_code
        assert_equal "test command timed out", result.summary
        assert_includes result.error, "60s"
      end

      test "returns error when test command not found" do
        Open3.stubs(:capture3).raises(Errno::ENOENT, "No such file - nonexistent")

        result = TestRunner.call(
          repo_path: @repo_path,
          test_command: "nonexistent"
        )

        refute result.passed
        assert_equal -1, result.exit_code
        assert_equal "test command not found", result.summary
        assert_includes result.error, "Command not found"
      end

      test "returns error for unexpected exceptions" do
        Open3.stubs(:capture3).raises(RuntimeError, "something broke")

        result = TestRunner.call(
          repo_path: @repo_path,
          test_command: "bin/rails test"
        )

        refute result.passed
        assert_equal -1, result.exit_code
        assert_includes result.error, "something broke"
      end

      # --- self.call class method ---

      test "class method delegates to instance" do
        mock_status = stub(success?: true, exitstatus: 0)
        Open3.stubs(:capture3).returns([ "ok", "", mock_status ])

        result = TestRunner.call(
          repo_path: @repo_path,
          test_command: "echo ok",
          timeout: 30,
          boot_command: nil,
          boot_timeout: 10
        )

        assert result.is_a?(TestResult)
      end
    end
  end
end

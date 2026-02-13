require "test_helper"
require "arnold_pipeline/verification/verification_result"
require "arnold_pipeline/verification/verification_runner"

module ArnoldPipeline
  module Verification
    class VerificationRunnerTest < ActiveSupport::TestCase
      setup do
        @repo_path = "/tmp/test_repo"
      end

      test "returns all-passed result when all steps succeed" do
        config = {
          setup_command: "bin/setup",
          run_command: "bin/dev",
          health_check: { url: "http://localhost:3000/up", expected_status: 200 }
        }

        mock_status = stub(success?: true, exitstatus: 0)
        Open3.stubs(:capture3).with("bin/setup", chdir: @repo_path).returns(["ok", "", mock_status])
        Process.stubs(:spawn).returns(12345)

        response = stub(code: "200")
        Net::HTTP.stubs(:get_response).returns(response)

        Process.stubs(:kill)
        Process.stubs(:waitpid)

        result = VerificationRunner.call(
          repo_path: @repo_path,
          verification_config: config
        )

        assert result.passed?
        assert result.setup_passed
        assert result.boot_passed
        assert result.health_check_passed
        assert_nil result.test_passed
        assert_empty result.errors
      end

      test "returns failed setup and skips subsequent steps" do
        config = {
          setup_command: "bin/setup",
          run_command: "bin/dev",
          health_check: { url: "http://localhost:3000/up", expected_status: 200 }
        }

        mock_status = stub(success?: false, exitstatus: 1)
        Open3.stubs(:capture3).with("bin/setup", chdir: @repo_path).returns(["", "error: missing deps", mock_status])

        result = VerificationRunner.call(
          repo_path: @repo_path,
          verification_config: config
        )

        refute result.passed?
        refute result.setup_passed
        refute result.boot_passed
        refute result.health_check_passed
        assert result.errors.any? { |e| e.include?("Setup") }
      end

      test "returns failed boot when spawn raises" do
        config = {
          setup_command: "bin/setup",
          run_command: "bin/dev",
          health_check: { url: "http://localhost:3000/up", expected_status: 200 }
        }

        mock_status = stub(success?: true, exitstatus: 0)
        Open3.stubs(:capture3).with("bin/setup", chdir: @repo_path).returns(["ok", "", mock_status])
        Process.stubs(:spawn).raises(Errno::ENOENT, "No such file - bin/dev")

        result = VerificationRunner.call(
          repo_path: @repo_path,
          verification_config: config
        )

        refute result.passed?
        assert result.setup_passed
        refute result.boot_passed
        refute result.health_check_passed
        assert result.errors.any? { |e| e.include?("Boot failed") }
      end

      test "returns failed health check after retries" do
        config = {
          setup_command: "bin/setup",
          run_command: "bin/dev",
          health_check: { url: "http://localhost:3000/up", expected_status: 200 }
        }

        mock_status = stub(success?: true, exitstatus: 0)
        Open3.stubs(:capture3).with("bin/setup", chdir: @repo_path).returns(["ok", "", mock_status])
        Process.stubs(:spawn).returns(12345)

        # Stub sleep to avoid actual waiting
        VerificationRunner.any_instance.stubs(:sleep)

        Net::HTTP.stubs(:get_response).raises(Errno::ECONNREFUSED)

        Process.stubs(:kill)
        Process.stubs(:waitpid)

        result = VerificationRunner.call(
          repo_path: @repo_path,
          verification_config: config
        )

        refute result.passed?
        assert result.setup_passed
        assert result.boot_passed
        refute result.health_check_passed
        assert result.errors.any? { |e| e.include?("Health check failed") }
      end

      test "health check succeeds after initial connection refused retries" do
        config = {
          setup_command: "bin/setup",
          run_command: "bin/dev",
          health_check: { url: "http://localhost:3000/up", expected_status: 200 }
        }

        mock_status = stub(success?: true, exitstatus: 0)
        Open3.stubs(:capture3).with("bin/setup", chdir: @repo_path).returns(["ok", "", mock_status])
        Process.stubs(:spawn).returns(12345)

        VerificationRunner.any_instance.stubs(:sleep)

        # Fail twice, then succeed
        response_ok = stub(code: "200")
        Net::HTTP.stubs(:get_response)
          .raises(Errno::ECONNREFUSED).then
          .raises(Errno::ECONNREFUSED).then
          .returns(response_ok)

        Process.stubs(:kill)
        Process.stubs(:waitpid)

        result = VerificationRunner.call(
          repo_path: @repo_path,
          verification_config: config
        )

        assert result.passed?
        assert result.health_check_passed
      end

      test "runs test command when provided and health check passes" do
        config = {
          setup_command: "bin/setup",
          run_command: "bin/dev",
          health_check: { url: "http://localhost:3000/up", expected_status: 200 },
          test_command: "bin/rails test"
        }

        mock_status = stub(success?: true, exitstatus: 0)
        Open3.stubs(:capture3).with("bin/setup", chdir: @repo_path).returns(["ok", "", mock_status])
        Open3.stubs(:capture3).with("bin/rails test", chdir: @repo_path).returns(["0 failures", "", mock_status])
        Process.stubs(:spawn).returns(12345)

        response = stub(code: "200")
        Net::HTTP.stubs(:get_response).returns(response)

        Process.stubs(:kill)
        Process.stubs(:waitpid)

        result = VerificationRunner.call(
          repo_path: @repo_path,
          verification_config: config
        )

        assert result.passed?
        assert_equal true, result.test_passed
      end

      test "test failure returns test_passed false" do
        config = {
          setup_command: "bin/setup",
          run_command: "bin/dev",
          health_check: { url: "http://localhost:3000/up", expected_status: 200 },
          test_command: "bin/rails test"
        }

        ok_status = stub(success?: true, exitstatus: 0)
        fail_status = stub(success?: false, exitstatus: 1)
        Open3.stubs(:capture3).with("bin/setup", chdir: @repo_path).returns(["ok", "", ok_status])
        Open3.stubs(:capture3).with("bin/rails test", chdir: @repo_path).returns(["", "1 failure", fail_status])
        Process.stubs(:spawn).returns(12345)

        response = stub(code: "200")
        Net::HTTP.stubs(:get_response).returns(response)

        Process.stubs(:kill)
        Process.stubs(:waitpid)

        result = VerificationRunner.call(
          repo_path: @repo_path,
          verification_config: config
        )

        refute result.passed?
        assert_equal false, result.test_passed
        assert result.errors.any? { |e| e.include?("Test") }
      end

      test "runs cleanup command always even on failure" do
        config = {
          setup_command: "bin/setup",
          cleanup_command: "cleanup.sh"
        }

        fail_status = stub(success?: false, exitstatus: 1)
        ok_status = stub(success?: true, exitstatus: 0)
        Open3.stubs(:capture3).with("bin/setup", chdir: @repo_path).returns(["", "error", fail_status])
        Open3.expects(:capture3).with("cleanup.sh", chdir: @repo_path).returns(["", "", ok_status])

        VerificationRunner.call(
          repo_path: @repo_path,
          verification_config: config
        )
      end

      test "handles missing setup_command gracefully" do
        config = {
          run_command: "bin/dev",
          health_check: { url: "http://localhost:3000/up", expected_status: 200 }
        }

        Process.stubs(:spawn).returns(12345)

        response = stub(code: "200")
        Net::HTTP.stubs(:get_response).returns(response)

        Process.stubs(:kill)
        Process.stubs(:waitpid)

        result = VerificationRunner.call(
          repo_path: @repo_path,
          verification_config: config
        )

        assert result.setup_passed
        assert result.boot_passed
        assert result.health_check_passed
      end

      test "handles missing run_command gracefully" do
        config = {
          setup_command: "bin/setup",
          health_check: { url: "http://localhost:3000/up", expected_status: 200 }
        }

        mock_status = stub(success?: true, exitstatus: 0)
        Open3.stubs(:capture3).with("bin/setup", chdir: @repo_path).returns(["ok", "", mock_status])

        response = stub(code: "200")
        Net::HTTP.stubs(:get_response).returns(response)

        result = VerificationRunner.call(
          repo_path: @repo_path,
          verification_config: config
        )

        assert result.setup_passed
        assert result.boot_passed
        assert result.health_check_passed
      end

      test "handles missing health_check gracefully" do
        config = {
          setup_command: "bin/setup",
          run_command: "bin/dev"
        }

        mock_status = stub(success?: true, exitstatus: 0)
        Open3.stubs(:capture3).with("bin/setup", chdir: @repo_path).returns(["ok", "", mock_status])
        Process.stubs(:spawn).returns(12345)

        Process.stubs(:kill)
        Process.stubs(:waitpid)

        result = VerificationRunner.call(
          repo_path: @repo_path,
          verification_config: config
        )

        assert result.setup_passed
        assert result.boot_passed
        assert result.health_check_passed
      end

      test "setup command timeout returns failure" do
        config = {
          setup_command: "bin/setup"
        }

        Timeout.stubs(:timeout).raises(Timeout::Error)

        result = VerificationRunner.call(
          repo_path: @repo_path,
          verification_config: config,
          timeout: 5
        )

        refute result.setup_passed
        assert result.errors.any? { |e| e.include?("timed out") }
      end

      test "health check with non-matching status code fails" do
        config = {
          health_check: { url: "http://localhost:3000/up", expected_status: 200 }
        }

        VerificationRunner.any_instance.stubs(:sleep)

        response = stub(code: "500")
        Net::HTTP.stubs(:get_response).returns(response)

        result = VerificationRunner.call(
          repo_path: @repo_path,
          verification_config: config
        )

        assert result.setup_passed
        assert result.boot_passed
        refute result.health_check_passed
      end

      test "kills server process group on cleanup" do
        config = {
          run_command: "bin/dev",
          health_check: { url: "http://localhost:3000/up", expected_status: 200 }
        }

        Process.stubs(:spawn).returns(99999)

        response = stub(code: "200")
        Net::HTTP.stubs(:get_response).returns(response)

        # Expect TERM signal to the process group (negative PID)
        Process.expects(:kill).with("-TERM", 99999)
        Process.stubs(:waitpid).with(99999)

        VerificationRunner.call(
          repo_path: @repo_path,
          verification_config: config
        )
      end

      test "empty config runs all steps as passed" do
        config = {}

        result = VerificationRunner.call(
          repo_path: @repo_path,
          verification_config: config
        )

        assert result.passed?
        assert result.setup_passed
        assert result.boot_passed
        assert result.health_check_passed
        assert_nil result.test_passed
        assert_empty result.errors
      end
    end
  end
end

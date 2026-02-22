require "test_helper"
require "arnold_pipeline/verification_runner"
require "arnold_pipeline/verification_check"
require "tmpdir"
require "fileutils"

module ArnoldPipeline
  class VerificationRunnerTest < ActiveSupport::TestCase
    cover "ArnoldPipeline::VerificationRunner*"

    setup do
      @tmpdir = Dir.mktmpdir("verification_runner_test")

      # Create a passing script
      @pass_script = File.join(@tmpdir, "pass.sh")
      File.write(@pass_script, "#!/bin/bash\necho 'all good'\nexit 0\n")
      FileUtils.chmod(0o755, @pass_script)

      # Create a failing script
      @fail_script = File.join(@tmpdir, "fail.sh")
      File.write(@fail_script, "#!/bin/bash\necho 'something broke' >&2\nexit 1\n")
      FileUtils.chmod(0o755, @fail_script)
    end

    teardown do
      FileUtils.rm_rf(@tmpdir)
    end

    test "runs all checks and returns results" do
      checks = [
        VerificationCheck.new(name: "check1", command: @pass_script),
        VerificationCheck.new(name: "check2", command: @pass_script)
      ]

      result = VerificationRunner.call(repo_path: @tmpdir, checks: checks)

      assert_equal 2, result[:checks].size
      assert_equal "check1", result[:checks][0][:name]
      assert_equal "check2", result[:checks][1][:name]
    end

    test "short-circuits on required check failure" do
      checks = [
        VerificationCheck.new(name: "required_fail", command: @fail_script, required: true),
        VerificationCheck.new(name: "should_not_run", command: @pass_script)
      ]

      result = VerificationRunner.call(repo_path: @tmpdir, checks: checks)

      assert_equal 1, result[:checks].size
      assert_equal "required_fail", result[:checks][0][:name]
      refute result[:checks][0][:success]
    end

    test "continues past non-required check failure" do
      checks = [
        VerificationCheck.new(name: "optional_fail", command: @fail_script, required: false),
        VerificationCheck.new(name: "still_runs", command: @pass_script)
      ]

      result = VerificationRunner.call(repo_path: @tmpdir, checks: checks)

      assert_equal 2, result[:checks].size
      refute result[:checks][0][:success]
      assert result[:checks][1][:success]
    end

    test "returns all_passed: true when all pass" do
      checks = [
        VerificationCheck.new(name: "a", command: @pass_script),
        VerificationCheck.new(name: "b", command: @pass_script)
      ]

      result = VerificationRunner.call(repo_path: @tmpdir, checks: checks)

      assert result[:all_passed]
    end

    test "returns all_passed: false when any fail" do
      checks = [
        VerificationCheck.new(name: "a", command: @pass_script),
        VerificationCheck.new(name: "b", command: @fail_script)
      ]

      result = VerificationRunner.call(repo_path: @tmpdir, checks: checks)

      refute result[:all_passed]
    end

    test "captures duration_ms for each check" do
      checks = [
        VerificationCheck.new(name: "timed", command: @pass_script)
      ]

      result = VerificationRunner.call(repo_path: @tmpdir, checks: checks)

      duration = result[:checks][0][:duration_ms]
      assert_kind_of Integer, duration
      assert duration >= 0
    end

    test "builds summary string" do
      checks = [
        VerificationCheck.new(name: "lint", command: @pass_script),
        VerificationCheck.new(name: "test", command: @fail_script)
      ]

      result = VerificationRunner.call(repo_path: @tmpdir, checks: checks)

      assert_equal "1 passed, 1 failed: lint=OK, test=FAIL", result[:summary]
    end

    test "rescues exceptions and returns error result" do
      checks = [
        VerificationCheck.new(name: "bad_cmd", command: "/nonexistent/command/xyz_12345")
      ]

      result = VerificationRunner.call(repo_path: @tmpdir, checks: checks)

      assert_equal 1, result[:checks].size
      refute result[:checks][0][:success]
      assert_nil result[:checks][0][:exit_code]
      assert result[:checks][0][:stderr].length > 0
    end

    test "caps stdout at 5000 chars" do
      # Create a script that outputs more than 5000 chars
      verbose_script = File.join(@tmpdir, "verbose.sh")
      File.write(verbose_script, "#!/bin/bash\nprintf 'x%.0s' {1..6000}\nexit 0\n")
      FileUtils.chmod(0o755, verbose_script)

      checks = [
        VerificationCheck.new(name: "verbose", command: verbose_script)
      ]

      result = VerificationRunner.call(repo_path: @tmpdir, checks: checks)

      assert result[:checks][0][:stdout].length <= 5000
    end

    test "captures tail of stdout when output exceeds cap" do
      # Create a script where the important content is at the END
      tail_script = File.join(@tmpdir, "tail_test.sh")
      # Emit 5500 chars of padding then the important summary line
      File.write(tail_script, <<~BASH)
        #!/bin/bash
        printf 'x%.0s' {1..5500}
        echo ""
        echo "14 runs, 28 assertions, 1 failures, 0 errors, 0 skips"
        exit 1
      BASH
      FileUtils.chmod(0o755, tail_script)

      checks = [
        VerificationCheck.new(name: "tail_check", command: tail_script)
      ]

      result = VerificationRunner.call(repo_path: @tmpdir, checks: checks)

      stdout = result[:checks][0][:stdout]
      assert stdout.length <= 5000
      # The minitest summary line at the end MUST be preserved
      assert_includes stdout, "14 runs, 28 assertions, 1 failures, 0 errors, 0 skips"
    end

    test "short output is not truncated by tail capture" do
      short_script = File.join(@tmpdir, "short.sh")
      File.write(short_script, "#!/bin/bash\necho 'hello world'\nexit 0\n")
      FileUtils.chmod(0o755, short_script)

      checks = [
        VerificationCheck.new(name: "short", command: short_script)
      ]

      result = VerificationRunner.call(repo_path: @tmpdir, checks: checks)

      assert_includes result[:checks][0][:stdout], "hello world"
    end

    test "VerificationCheck accepts solid_stack type without command" do
      check = VerificationCheck.new(name: "solid", type: :solid_stack, required: true)
      assert_equal :solid_stack, check.type
      assert_nil check.command
      assert check.required?
    end

    test "solid_stack check generates and runs probe script" do
      runner_script = File.join(@tmpdir, "bin", "rails")
      FileUtils.mkdir_p(File.join(@tmpdir, "bin"))
      File.write(runner_script, <<~BASH)
        #!/bin/bash
        # Simulate bin/rails runner — just run the script it's given
        ruby "$2"
      BASH
      FileUtils.chmod(0o755, runner_script)

      checks = [
        VerificationCheck.new(name: "Solid stack", type: :solid_stack, required: true)
      ]

      result = VerificationRunner.call(repo_path: @tmpdir, checks: checks)

      assert_equal 1, result[:checks].size
      assert result[:checks][0][:success], "Expected solid_stack check to pass but got: #{result[:checks][0][:stderr]}"
      assert_equal :solid_stack, result[:checks][0][:type]
      assert_includes result[:checks][0][:stdout], "Solid stack connections OK"
    end

    test "solid_stack check reports failure when probe script exits non-zero" do
      runner_script = File.join(@tmpdir, "bin", "rails")
      FileUtils.mkdir_p(File.join(@tmpdir, "bin"))
      File.write(runner_script, <<~BASH)
        #!/bin/bash
        echo "SolidQueue: no such table: solid_queue_jobs. Ensure config.solid_queue.connects_to is set" >&2
        exit 1
      BASH
      FileUtils.chmod(0o755, runner_script)

      checks = [
        VerificationCheck.new(name: "Solid stack", type: :solid_stack, required: true)
      ]

      result = VerificationRunner.call(repo_path: @tmpdir, checks: checks)

      assert_equal 1, result[:checks].size
      refute result[:checks][0][:success]
      assert_includes result[:checks][0][:stderr], "SolidQueue"
      refute result[:all_passed]
    end

    test "returns empty results when checks array is empty" do
      result = VerificationRunner.call(repo_path: @tmpdir, checks: [])

      assert_equal [], result[:checks]
      assert result[:all_passed]
      assert_equal "0 passed, 0 failed: ", result[:summary]
    end
  end
end

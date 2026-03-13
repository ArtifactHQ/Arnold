require "test_helper"
require "arnold_pipeline/brownfield/health_baseline_runner"
require "tmpdir"

module ArnoldPipeline
  module Brownfield
    class HealthBaselineRunnerTest < ActiveSupport::TestCase
      test "runs git status check" do
        Dir.mktmpdir do |dir|
          # Initialize a git repo
          Open3.capture3("git init", chdir: dir)
          Open3.capture3("git config user.email 'test@test.com'", chdir: dir)
          Open3.capture3("git config user.name 'Test'", chdir: dir)

          result = HealthBaselineRunner.call(repo_path: dir)

          git_check = result[:checks].find { |c| c[:name] == "git_status" }
          assert git_check, "git_status check should be present"
          assert git_check[:success]
        end
      end

      test "git_status check fails when repo has uncommitted changes" do
        Dir.mktmpdir do |dir|
          Open3.capture3("git init", chdir: dir)
          Open3.capture3("git config user.email 'test@test.com'", chdir: dir)
          Open3.capture3("git config user.name 'Test'", chdir: dir)
          File.write(File.join(dir, "dirty.txt"), "uncommitted")

          result = HealthBaselineRunner.call(repo_path: dir)
          git_check = result[:checks].find { |c| c[:name] == "git_status" }
          assert git_check, "git_status check should be present"
          refute git_check[:success], "git_status should fail with uncommitted changes"
        end
      end

      test "detects build command for Rails project" do
        Dir.mktmpdir do |dir|
          File.write(File.join(dir, "Gemfile"), "source 'https://rubygems.org'")

          runner = HealthBaselineRunner.new(repo_path: dir)

          # Just verify the command is detected, not that it runs successfully
          command = runner.send(:command_for, :build)
          assert_equal "bundle install --quiet", command
        end
      end

      test "detects test command for Rails project" do
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, "bin"))
          File.write(File.join(dir, "bin/rails"), "#!/usr/bin/env ruby")

          runner = HealthBaselineRunner.new(repo_path: dir)
          command = runner.send(:command_for, :test_suite)
          assert_equal "bin/rails test", command
        end
      end

      test "detects test command for npm project" do
        Dir.mktmpdir do |dir|
          File.write(File.join(dir, "package.json"), '{"scripts": {"test": "jest"}}')

          runner = HealthBaselineRunner.new(repo_path: dir)
          command = runner.send(:command_for, :test_suite)
          assert_equal "npm test", command
        end
      end

      test "skips checks with no detected command" do
        Dir.mktmpdir do |dir|
          # Empty directory — no commands detected
          result = HealthBaselineRunner.call(repo_path: dir)

          # git_status always has a command, but others may be nil
          assert result[:checks].size >= 1
        end
      end

      test "handles timeout" do
        Dir.mktmpdir do |dir|
          Open3.capture3("git init", chdir: dir)

          runner = HealthBaselineRunner.new(repo_path: dir, timeout: 0)

          # With 0 timeout, checks should timeout
          result = runner.call
          # git_status may or may not timeout (it's fast), but the structure should be valid
          assert result[:checks].is_a?(Array)
          assert result.key?(:all_passed)
          assert result.key?(:summary)
        end
      end

      test "parses minitest output" do
        runner = HealthBaselineRunner.new(repo_path: "/tmp")
        output = "42 runs, 100 assertions, 2 failures, 1 errors, 3 skips"
        parsed = runner.send(:parse_test_output, output)

        assert parsed
        assert_equal 42, parsed["runs"]
        assert_equal 100, parsed["assertions"]
        assert_equal 2, parsed["failures"]
        assert_equal 1, parsed["errors"]
        assert_equal 3, parsed["skips"]
      end

      test "parses jest output" do
        runner = HealthBaselineRunner.new(repo_path: "/tmp")
        output = "Tests:  3 failed, 1 skipped, 42 passed, 46 total"
        parsed = runner.send(:parse_test_output, output)

        assert parsed
        assert_equal 3, parsed["failures"]
        assert_equal 1, parsed["skips"]
        assert_equal 42, parsed["passed"]
        assert_equal 46, parsed["runs"]
      end

      test "parses pytest output" do
        runner = HealthBaselineRunner.new(repo_path: "/tmp")
        output = "15 passed, 2 failed, 1 skipped"
        parsed = runner.send(:parse_test_output, output)

        assert parsed
        assert_equal 15, parsed["passed"]
        assert_equal 2, parsed["failures"]
        assert_equal 1, parsed["skips"]
      end

      test "returns nil for unparseable output" do
        runner = HealthBaselineRunner.new(repo_path: "/tmp")
        parsed = runner.send(:parse_test_output, "no test output here")
        assert_nil parsed
      end

      test "build_summary formats check results" do
        runner = HealthBaselineRunner.new(repo_path: "/tmp")
        results = [
          { name: "git_status", success: true },
          { name: "build", success: true },
          { name: "test_suite", success: false }
        ]
        summary = runner.send(:build_summary, results)
        assert_includes summary, "2 passed"
        assert_includes summary, "1 failed"
        assert_includes summary, "git_status=OK"
        assert_includes summary, "test_suite=FAIL"
      end
    end
  end
end

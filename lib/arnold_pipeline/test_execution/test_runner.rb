require "open3"
require "timeout"

module ArnoldPipeline
  module TestExecution
    class TestRunner
      def self.call(repo_path:, test_command: nil, timeout: 120, boot_command: nil, boot_timeout: 60)
        new(repo_path:, test_command:, timeout:, boot_command:, boot_timeout:).call
      end

      def initialize(repo_path:, test_command: nil, timeout: 120, boot_command: nil, boot_timeout: 60)
        @repo_path = repo_path
        @test_command = test_command
        @timeout = timeout
        @boot_command = boot_command
        @boot_timeout = boot_timeout
      end

      def call
        if @boot_command
          boot_result = run_boot
          return boot_result if boot_result
        end

        command = @test_command || detect_test_command
        unless command
          return TestResult.new(
            passed: false,
            exit_code: -1,
            summary: "no test suite found",
            error: "Could not detect a test command. Set test_command in configuration."
          )
        end

        run_tests(command)
      end

      private

      def run_boot
        stdout, stderr, status = Timeout.timeout(@boot_timeout) do
          Open3.capture3(@boot_command, chdir: @repo_path)
        end

        return nil if status.success?

        output = stderr.strip
        output = stdout.strip if output.empty?

        TestResult.new(
          passed: false,
          exit_code: status.exitstatus,
          summary: "boot command failed",
          error: "Boot command '#{@boot_command}' failed (exit #{status.exitstatus}): #{output[0, 500]}"
        )
      rescue Timeout::Error
        TestResult.new(
          passed: false,
          exit_code: -1,
          summary: "boot command timed out",
          error: "Boot command '#{@boot_command}' timed out after #{@boot_timeout}s"
        )
      rescue => e
        TestResult.new(
          passed: false,
          exit_code: -1,
          summary: "boot command error",
          error: "Boot command '#{@boot_command}' error: #{e.message}"
        )
      end

      def run_tests(command)
        stdout, stderr, status = Timeout.timeout(@timeout) do
          Open3.capture3(command, chdir: @repo_path)
        end

        TestResultParser.call(
          stdout: stdout,
          stderr: stderr,
          exit_code: status.exitstatus
        )
      rescue Timeout::Error
        TestResult.new(
          passed: false,
          exit_code: -1,
          summary: "test command timed out",
          error: "timeout after #{@timeout}s"
        )
      rescue Errno::ENOENT => e
        TestResult.new(
          passed: false,
          exit_code: -1,
          summary: "test command not found",
          error: "Command not found: #{e.message}"
        )
      rescue => e
        TestResult.new(
          passed: false,
          exit_code: -1,
          summary: "test command error",
          error: "#{e.class}: #{e.message}"
        )
      end

      def detect_test_command
        if File.exist?(File.join(@repo_path, "bin/rails"))
          "bin/rails test"
        elsif File.exist?(File.join(@repo_path, "Gemfile")) && gemfile_contains_rspec?
          "bundle exec rspec"
        elsif File.exist?(File.join(@repo_path, "package.json"))
          "npm test"
        elsif File.exist?(File.join(@repo_path, "pytest.ini")) ||
              File.exist?(File.join(@repo_path, "pyproject.toml"))
          "pytest"
        end
      end

      def gemfile_contains_rspec?
        gemfile = File.join(@repo_path, "Gemfile")
        return false unless File.exist?(gemfile)

        File.read(gemfile).include?("rspec")
      rescue
        false
      end
    end
  end
end

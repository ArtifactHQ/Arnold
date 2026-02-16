require "open3"

module ArnoldPipeline
  class VerificationRunner
    STDOUT_CAP = 5000
    STDERR_CAP = 2000

    def self.call(repo_path:, checks:, logger: nil)
      new(repo_path:, checks:, logger:).call
    end

    def initialize(repo_path:, checks:, logger: nil)
      @repo_path = repo_path
      @checks = checks
      @logger = logger
    end

    def call
      results = []

      @checks.each do |check|
        result = run_check(check)
        results << result

        if !result[:success] && check.required?
          @logger&.info("[VerificationRunner] Required check '#{check.name}' failed — short-circuiting")
          break
        end
      end

      {
        checks: results,
        all_passed: results.all? { |r| r[:success] },
        summary: build_summary(results)
      }
    end

    private

    def run_check(check)
      @logger&.info("[VerificationRunner] Running check: #{check.name}")

      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      stdout, stderr, status = Open3.capture3(check.command, chdir: @repo_path)
      duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000).round

      {
        name: check.name,
        type: check.type,
        success: status.success?,
        exit_code: status.exitstatus,
        stdout: stdout[0, STDOUT_CAP],
        stderr: stderr[0, STDERR_CAP],
        duration_ms: duration_ms
      }
    rescue => e
      duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - (start || Process.clock_gettime(Process::CLOCK_MONOTONIC))) * 1000).round

      @logger&.warn("[VerificationRunner] Check '#{check.name}' raised: #{e.message}")

      {
        name: check.name,
        type: check.type,
        success: false,
        exit_code: nil,
        stdout: "",
        stderr: e.message[0, STDERR_CAP],
        duration_ms: duration_ms
      }
    end

    def build_summary(results)
      passed = results.count { |r| r[:success] }
      failed = results.count { |r| !r[:success] }
      details = results.map { |r| "#{r[:name]}=#{r[:success] ? "OK" : "FAIL"}" }.join(", ")

      "#{passed} passed, #{failed} failed: #{details}"
    end
  end
end

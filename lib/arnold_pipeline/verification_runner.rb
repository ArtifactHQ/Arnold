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
      stdout, stderr, status = Bundler.with_unbundled_env do
        Open3.capture3(check.command, chdir: @repo_path)
      end
      duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000).round

      {
        name: check.name,
        type: check.type,
        success: status.success?,
        exit_code: status.exitstatus,
        stdout: tail_capture(stdout, STDOUT_CAP),
        stderr: tail_capture(stderr, STDERR_CAP),
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

    # Capture the LAST n characters of output so that test summary lines
    # and failure blocks (which appear at the end) are preserved instead
    # of discarding them in favour of early loading/path output.
    def tail_capture(output, cap)
      return output if output.length <= cap
      output[-cap, cap]
    end

    def build_summary(results)
      passed = results.count { |r| r[:success] }
      failed = results.count { |r| !r[:success] }
      details = results.map { |r| "#{r[:name]}=#{r[:success] ? "OK" : "FAIL"}" }.join(", ")

      "#{passed} passed, #{failed} failed: #{details}"
    end
  end
end

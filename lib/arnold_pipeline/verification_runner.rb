require "bundler"
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

      command = check.type == :solid_stack ? solid_stack_command : check.command
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      stdout, stderr, status = Bundler.with_unbundled_env do
        Open3.capture3(command, chdir: @repo_path)
      end
      duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000).round

      {
        name: check.name,
        type: check.type,
        success: status.success?,
        exit_code: status.exitstatus,
        stdout: tail_capture(stdout, STDOUT_CAP),
        stderr: tail_capture(stderr, STDERR_CAP),
        duration_ms: duration_ms,
        required: check.required?
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
        duration_ms: duration_ms,
        required: check.required?
      }
    end

    SOLID_STACK_SCRIPT = <<~'RUBY'
      errors = []
      if defined?(SolidQueue::Record)
        begin
          SolidQueue::Record.connection.active?
          puts "SolidQueue: OK"
        rescue => e
          errors << "SolidQueue: #{e.message}. Ensure config.solid_queue.connects_to = { database: { writing: :queue } } is set in config/environments/development.rb"
        end
      end
      if defined?(SolidCache::Record)
        begin
          SolidCache::Record.connection.active?
          puts "SolidCache: OK"
        rescue => e
          errors << "SolidCache: #{e.message}. Ensure config.solid_cache.connects_to = { database: { writing: :cache } } is set in config/environments/development.rb"
        end
      end
      if defined?(ActionCable) && ActionCable.const_defined?(:Record, false)
        begin
          ActionCable::Record.connection.active?
          puts "ActionCable: OK"
        rescue => e
          errors << "ActionCable: #{e.message}. Check cable database configuration in config/environments/development.rb"
        end
      end
      if errors.any?
        $stderr.puts errors.join("\n")
        exit 1
      else
        puts "All Solid stack connections OK"
      end
    RUBY

    def solid_stack_command
      script_path = File.join(@repo_path, "tmp", "arnold_solid_check.rb")
      FileUtils.mkdir_p(File.dirname(script_path))
      File.write(script_path, SOLID_STACK_SCRIPT)
      "bin/rails runner #{script_path}"
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

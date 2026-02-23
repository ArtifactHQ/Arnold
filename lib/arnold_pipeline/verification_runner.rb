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
        stdout: capture_output(check.type, stdout, STDOUT_CAP),
        stderr: capture_output(check.type, stderr, STDERR_CAP),
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

    # Route capture strategy based on check type.
    # Test suites: keep tail (failure summary at bottom).
    # Everything else: keep head+tail (exception at top, context at bottom).
    def capture_output(check_type, output, cap)
      if check_type == :test_suite
        tail_capture(output, cap)
      else
        head_and_tail_capture(output, cap)
      end
    end

    # Keep the LAST n characters — test failure summaries appear at the end.
    def tail_capture(output, cap)
      return output if output.length <= cap
      output[-cap, cap]
    end

    # Keep the FIRST n/2 and LAST n/2 characters — boot/solid_stack errors
    # have the exception at the top and recent context at the bottom.
    def head_and_tail_capture(output, cap)
      return output if output.length <= cap

      half = cap / 2
      output[0, half] + "\n...[truncated]...\n" + output[-half, half]
    end

    def build_summary(results)
      passed = results.count { |r| r[:success] }
      failed = results.count { |r| !r[:success] }
      details = results.map { |r| "#{r[:name]}=#{r[:success] ? "OK" : "FAIL"}" }.join(", ")

      "#{passed} passed, #{failed} failed: #{details}"
    end
  end
end

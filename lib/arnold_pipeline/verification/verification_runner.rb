require "open3"
require "net/http"
require "uri"
require "timeout"

module ArnoldPipeline
  module Verification
    class VerificationRunner
      def self.call(repo_path:, verification_config:, timeout: 120, health_check_retries: 10, health_check_interval: 3)
        new(repo_path:, verification_config:, timeout:, health_check_retries:, health_check_interval:).call
      end

      def initialize(repo_path:, verification_config:, timeout: 120, health_check_retries: 10, health_check_interval: 3)
        @repo_path = repo_path
        @verification_config = verification_config
        @timeout = timeout
        @health_check_retries = health_check_retries
        @health_check_interval = health_check_interval
        @errors = []
        @server_pid = nil
      end

      def call
        setup_passed = run_setup
        boot_passed = setup_passed ? run_boot : false
        health_check_passed = boot_passed ? run_health_check : false
        test_passed = health_check_passed ? run_tests : nil

        VerificationResult.new(
          setup_passed:,
          boot_passed:,
          health_check_passed:,
          test_passed:,
          errors: @errors
        )
      ensure
        run_cleanup
      end

      private

      def run_setup
        command = @verification_config[:setup_command]
        return true unless command

        run_command(command, label: "setup")
      end

      def run_boot
        command = @verification_config[:run_command]
        return true unless command

        begin
          @server_pid = Process.spawn(
            command,
            chdir: @repo_path,
            out: File::NULL,
            err: File::NULL,
            pgroup: true
          )
          true
        rescue => e
          @errors << "Boot failed: #{e.message}"
          false
        end
      end

      def run_health_check
        config = @verification_config[:health_check]
        return true unless config

        url = config[:url]
        expected_status = config[:expected_status] || 200
        uri = URI.parse(url)

        @health_check_retries.times do |i|
          begin
            response = Net::HTTP.get_response(uri)
            if response.code.to_i == expected_status
              return true
            end
          rescue Errno::ECONNREFUSED, Errno::ECONNRESET, Net::OpenTimeout, SocketError
            # Server not ready yet, retry
          rescue => e
            @errors << "Health check attempt #{i + 1} error: #{e.message}"
          end

          sleep @health_check_interval
        end

        @errors << "Health check failed: #{url} did not return #{expected_status} after #{@health_check_retries} retries"
        false
      end

      def run_tests
        command = @verification_config[:test_command]
        return nil unless command

        run_command(command, label: "test")
      end

      def run_cleanup
        cleanup_command = @verification_config[:cleanup_command]

        if cleanup_command
          Open3.capture3(cleanup_command, chdir: @repo_path)
        end

        kill_server
      rescue => e
        @errors << "Cleanup error: #{e.message}"
      end

      def kill_server
        return unless @server_pid

        begin
          Process.kill("-TERM", @server_pid)
          Timeout.timeout(5) { Process.waitpid(@server_pid) }
        rescue Errno::ESRCH, Errno::ECHILD
          # Process already exited
        rescue Timeout::Error
          begin
            Process.kill("-KILL", @server_pid)
            Process.waitpid(@server_pid)
          rescue Errno::ESRCH, Errno::ECHILD
            # Process already exited
          end
        end

        @server_pid = nil
      end

      def run_command(command, label:)
        stdout, stderr, status = Timeout.timeout(@timeout) do
          Open3.capture3(command, chdir: @repo_path)
        end

        unless status.success?
          output = stderr.to_s.strip
          output = stdout.to_s.strip if output.empty?
          @errors << "#{label.capitalize} command failed (exit #{status.exitstatus}): #{output[0, 500]}"
        end

        status.success?
      rescue Timeout::Error
        @errors << "#{label.capitalize} command timed out after #{@timeout}s"
        false
      rescue => e
        @errors << "#{label.capitalize} command error: #{e.message}"
        false
      end
    end
  end
end

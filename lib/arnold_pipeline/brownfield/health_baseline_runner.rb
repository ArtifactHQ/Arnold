require "bundler"
require "open3"
require "yaml"
require "timeout"

module ArnoldPipeline
  module Brownfield
    class HealthBaselineRunner
      PARSERS_PATH = File.expand_path("data/test_output_parsers.yml", __dir__)
      STDOUT_CAP = 5000
      STDERR_CAP = 2000

      CHECKS = %i[git_status build boot lint test_suite].freeze

      def self.call(repo_path:, conventions: {}, artifact_map: [], timeout: 120)
        new(repo_path:, conventions:, artifact_map:, timeout:).call
      end

      def initialize(repo_path:, conventions: {}, artifact_map: [], timeout: 120)
        @repo_path = repo_path
        @conventions = conventions || {}
        @artifact_map = artifact_map || []
        @timeout = timeout
        @parsers = load_parsers
      end

      def call
        results = []

        CHECKS.each do |check_name|
          command = command_for(check_name)
          next unless command

          result = run_check(check_name, command)
          results << result
        end

        {
          checks: results,
          all_passed: results.all? { |r| r[:success] },
          summary: build_summary(results)
        }
      end

      private

      def command_for(check_name)
        case check_name
        when :git_status
          "git status --porcelain"
        when :build
          detect_build_command
        when :boot
          detect_boot_command
        when :lint
          detect_lint_command
        when :test_suite
          detect_test_command
        end
      end

      def detect_build_command
        if File.exist?(File.join(@repo_path, "Gemfile"))
          "bundle install --quiet"
        elsif File.exist?(File.join(@repo_path, "package.json"))
          "npm install --silent"
        elsif File.exist?(File.join(@repo_path, "Cargo.toml"))
          "cargo build"
        elsif File.exist?(File.join(@repo_path, "pom.xml"))
          "./mvnw compile -q"
        elsif File.exist?(File.join(@repo_path, "requirements.txt"))
          "pip install -r requirements.txt -q"
        end
      end

      def detect_boot_command
        if File.exist?(File.join(@repo_path, "bin/rails"))
          "bin/rails runner 'puts \"Boot OK\"'"
        elsif File.exist?(File.join(@repo_path, "manage.py"))
          "python manage.py check"
        elsif File.exist?(File.join(@repo_path, "next.config.js")) || File.exist?(File.join(@repo_path, "next.config.mjs"))
          "npx next build --no-lint 2>&1 | head -20"
        end
      end

      def detect_lint_command
        if File.exist?(File.join(@repo_path, ".rubocop.yml"))
          "bundle exec rubocop --format simple"
        elsif File.exist?(File.join(@repo_path, ".eslintrc.json")) || File.exist?(File.join(@repo_path, ".eslintrc.js"))
          "npx eslint . --format compact 2>&1 | tail -5"
        elsif File.exist?(File.join(@repo_path, "Cargo.toml"))
          "cargo clippy -- -D warnings 2>&1 | tail -5"
        end
      end

      def detect_test_command
        if File.exist?(File.join(@repo_path, "bin/rails"))
          "bin/rails test"
        elsif File.exist?(File.join(@repo_path, "Gemfile")) && File.read(File.join(@repo_path, "Gemfile")).include?("rspec")
          "bundle exec rspec --format progress"
        elsif File.exist?(File.join(@repo_path, "package.json"))
          "npm test"
        elsif File.exist?(File.join(@repo_path, "Cargo.toml"))
          "cargo test"
        elsif File.exist?(File.join(@repo_path, "manage.py"))
          "python manage.py test"
        elsif File.exist?(File.join(@repo_path, "pom.xml"))
          "./mvnw test -q"
        end
      end

      def run_check(name, command)
        start = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        stdout, stderr, status = Timeout.timeout(@timeout) do
          Bundler.with_unbundled_env do
            Open3.capture3("sh", "-c", command, chdir: @repo_path)
          end
        end

        duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000).round

        result = {
          name: name.to_s,
          command:,
          success: check_success?(name, status, stdout:),
          exit_code: status.exitstatus,
          stdout: truncate_output(stdout, STDOUT_CAP),
          stderr: truncate_output(stderr, STDERR_CAP),
          duration_ms:
        }

        if name == :test_suite
          result[:parsed] = parse_test_output(stdout + stderr)
        end

        result
      rescue Timeout::Error
        duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000).round
        {
          name: name.to_s,
          command:,
          success: false,
          exit_code: nil,
          stdout: "",
          stderr: "Timed out after #{@timeout}s",
          duration_ms:
        }
      rescue => e
        duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - (start || Process.clock_gettime(Process::CLOCK_MONOTONIC))) * 1000).round
        {
          name: name.to_s,
          command:,
          success: false,
          exit_code: nil,
          stdout: "",
          stderr: e.message[0, STDERR_CAP],
          duration_ms:
        }
      end

      def check_success?(name, status, stdout: "")
        case name
        when :git_status
          # git status --porcelain exits 0 regardless — success means repo is clean
          status.success? && stdout.strip.empty?
        when :lint
          # Lint warnings are OK, only hard failures count
          status.success?
        else
          status.success?
        end
      end

      def parse_test_output(output)
        @parsers.each do |_name, parser|
          pattern = Regexp.new(parser["summary_pattern"])
          match = output.match(pattern)
          next unless match

          groups = parser["summary_groups"]
          result = {}
          groups.each do |key, index|
            result[key] = match[index]&.to_i
          end
          return result
        end

        nil
      end

      def load_parsers
        YAML.safe_load_file(PARSERS_PATH)["parsers"]
      rescue
        {}
      end

      def truncate_output(output, cap)
        return output if output.length <= cap
        half = cap / 2
        output[0, half] + "\n...[truncated]...\n" + output[-half, half]
      end

      def build_summary(results)
        passed = results.count { |r| r[:success] }
        failed = results.count { |r| !r[:success] }
        details = results.map { |r| "#{r[:name]}=#{r[:success] ? 'OK' : 'FAIL'}" }.join(", ")
        "#{passed} passed, #{failed} failed: #{details}"
      end
    end
  end
end

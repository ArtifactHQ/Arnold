require "open3"

module ArnoldPipeline
  module Brownfield
    class TestNameCollector
      TIMEOUT = 30
      FRAMEWORK_COMMANDS = {
        "rails_minitest" => "bin/rails test --dry-run 2>&1",
        "rspec" => "bundle exec rspec --dry-run --format documentation 2>&1",
        "jest" => "npx jest --listTests 2>&1",
        "pytest" => "pytest --collect-only -q 2>&1",
        "cargo" => "cargo test -- --list 2>&1"
      }.freeze

      CONCERN_KEYWORDS = {
        "auth" => %w[user session login logout password registration sign_in sign_up auth token credential],
        "data_layer" => %w[model record database migration schema seed query association validation],
        "api_layer" => %w[controller route endpoint request response api resource action],
        "background_jobs" => %w[job worker queue mailer task schedule],
        "realtime" => %w[channel cable websocket broadcast stream subscription],
        "testing" => %w[test_helper factory fixture mock stub],
        "frontend" => %w[view component helper javascript stimulus turbo template form],
        "deployment" => %w[deploy docker container ci pipeline]
      }.freeze

      def self.call(repo_path:, stack_fingerprint:, recipe_alignment: {})
        new(repo_path:, stack_fingerprint:, recipe_alignment:).call
      end

      def initialize(repo_path:, stack_fingerprint:, recipe_alignment: {})
        @repo_path = repo_path
        @stack_fingerprint = stack_fingerprint
        @recipe_alignment = recipe_alignment
      end

      def call
        framework = detect_test_framework
        return empty_result unless framework

        command = FRAMEWORK_COMMANDS[framework]
        return empty_result unless command

        output = run_command(command)
        return empty_result if output.nil? || output.strip.empty?

        test_names = parse_test_names(output, framework)
        grouped = group_by_concern(test_names)

        { test_names: test_names, grouped_by_concern: grouped, framework: framework }
      rescue => e
        # Graceful failure — test name collection is supplementary
        empty_result
      end

      private

      def detect_test_framework
        language = @stack_fingerprint[:language] || @stack_fingerprint["language"]
        framework = @stack_fingerprint[:framework] || @stack_fingerprint["framework"]

        case language
        when "ruby"
          if File.exist?(File.join(@repo_path, ".rspec")) ||
             Dir.exist?(File.join(@repo_path, "spec"))
            "rspec"
          else
            "rails_minitest"
          end
        when "typescript", "javascript"
          "jest"
        when "python"
          "pytest"
        when "rust"
          "cargo"
        end
      end

      def run_command(command)
        stdout, _stderr, status = Open3.capture3(
          command,
          chdir: @repo_path,
          timeout: TIMEOUT
        )
        stdout
      rescue Errno::ENOENT, Errno::EACCES
        nil
      rescue => e
        nil
      end

      def parse_test_names(output, framework)
        case framework
        when "rails_minitest"
          parse_minitest(output)
        when "rspec"
          parse_rspec(output)
        when "jest"
          parse_jest(output)
        when "pytest"
          parse_pytest(output)
        when "cargo"
          parse_cargo(output)
        else
          []
        end
      end

      def parse_minitest(output)
        # Minitest dry-run outputs lines like: "SomeTest#test_something"
        output.lines
          .map(&:strip)
          .select { |line| line.match?(/\A\w+.*#test_/) }
          .map { |line| line.split(" = ").first&.strip }
          .compact
      end

      def parse_rspec(output)
        # RSpec documentation format outputs indented test descriptions
        output.lines
          .map(&:strip)
          .reject(&:empty?)
          .reject { |line| line.start_with?("Pending:") || line.start_with?("Finished") || line.match?(/^\d+ examples?/) }
          .select { |line| line.length > 3 && !line.start_with?("Using") }
      end

      def parse_jest(output)
        # Jest --listTests outputs file paths, one per line
        output.lines
          .map(&:strip)
          .reject(&:empty?)
          .select { |line| line.match?(/\.(test|spec)\.(ts|js|tsx|jsx)$/) }
      end

      def parse_pytest(output)
        # pytest --collect-only -q outputs: "test_file.py::test_name"
        output.lines
          .map(&:strip)
          .reject(&:empty?)
          .select { |line| line.include?("::") && !line.start_with?("=") }
      end

      def parse_cargo(output)
        # cargo test -- --list outputs: "test_name: test"
        output.lines
          .map(&:strip)
          .reject(&:empty?)
          .select { |line| line.end_with?(": test") }
          .map { |line| line.chomp(": test") }
      end

      def group_by_concern(test_names)
        grouped = Hash.new { |h, k| h[k] = [] }

        test_names.each do |name|
          downcased = name.downcase
          matched = false

          CONCERN_KEYWORDS.each do |concern_id, keywords|
            if keywords.any? { |kw| downcased.include?(kw) }
              grouped[concern_id] << name
              matched = true
              break
            end
          end

          grouped["uncategorized"] << name unless matched
        end

        grouped
      end

      def empty_result
        { test_names: [], grouped_by_concern: {}, framework: nil }
      end
    end
  end
end

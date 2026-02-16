require "arnold_pipeline/spec_test_progress"
require "arnold_pipeline/test_execution/test_runner"
require "arnold_pipeline/test_execution/test_result_parser"

module ArnoldPipeline
  class SpecTestProgressTracker
    def self.call(repo_path:, test_directory:, previous_results: nil)
      new(repo_path:, test_directory:, previous_results:).call
    end

    def initialize(repo_path:, test_directory:, previous_results: nil)
      @repo_path = repo_path
      @test_directory = test_directory
      @previous_results = previous_results
    end

    def call
      test_dir = File.join(@repo_path, @test_directory)
      unless Dir.exist?(test_dir)
        return SpecTestProgress.new(
          total_tests: 0,
          total_passing: 0,
          newly_passing: [],
          regressions: [],
          still_failing: []
        )
      end

      test_result = run_spec_tests(test_dir)
      current_results = parse_individual_results(test_result)

      compute_progress(current_results)
    end

    private

    def run_spec_tests(test_dir)
      command = build_test_command(test_dir)
      timeout = ArnoldPipeline.configuration.test_timeout

      TestExecution::TestRunner.call(
        repo_path: @repo_path,
        test_command: command,
        timeout: timeout
      )
    end

    def build_test_command(test_dir)
      if File.exist?(File.join(@repo_path, "bin/rails"))
        "bin/rails test #{@test_directory}"
      elsif File.exist?(File.join(@repo_path, "Gemfile"))
        "bundle exec ruby -Itest -e 'Dir.glob(\"#{@test_directory}/**/*_test.rb\").each { |f| require_relative f }'"
      elsif File.exist?(File.join(@repo_path, "package.json"))
        "npx jest #{@test_directory}"
      elsif File.exist?(File.join(@repo_path, "pytest.ini")) ||
            File.exist?(File.join(@repo_path, "pyproject.toml"))
        "pytest #{@test_directory}"
      else
        "ruby -Itest -e 'Dir.glob(\"#{@test_directory}/**/*_test.rb\").each { |f| require_relative f }'"
      end
    end

    def parse_individual_results(test_result)
      # Build a hash of test_name => :passed or :failed
      results = {}

      if test_result.failures.any?
        test_result.failures.each do |f|
          results[f[:name]] = :failed
        end
      end

      # Parse passing test count from summary
      # The total test count and passing info comes from the summary
      total = extract_total_tests(test_result)
      passing = total - test_result.failures.size

      # Mark passing tests as passed (we don't have individual names for passing tests,
      # so we track failures explicitly and compute passing count)
      {
        total: total,
        passing_count: [passing, 0].max,
        failed_names: test_result.failures.map { |f| f[:name] }
      }
    end

    def extract_total_tests(test_result)
      summary = test_result.summary.to_s

      # Minitest: "X runs, Y assertions, ..."
      if (match = summary.match(/(\d+)\s+runs?/))
        return match[1].to_i
      end

      # RSpec: "X examples, ..."
      if (match = summary.match(/(\d+)\s+examples?/))
        return match[1].to_i
      end

      # Jest: "N total"
      if (match = summary.match(/(\d+)\s+total/))
        return match[1].to_i
      end

      # Pytest: "N passed, M failed"
      passed_m = summary.match(/(\d+)\s+passed/)
      failed_m = summary.match(/(\d+)\s+failed/)
      if passed_m || failed_m
        return (passed_m&.[](1).to_i || 0) + (failed_m&.[](1).to_i || 0)
      end

      # Fallback: count failures as the only known tests
      test_result.failures.size
    end

    def compute_progress(current_results)
      current_failed = Set.new(current_results[:failed_names])

      if @previous_results
        previous_failed = Set.new(@previous_results["failed_names"] || [])

        newly_passing = (previous_failed - current_failed).to_a
        regressions = (current_failed - previous_failed).to_a
        still_failing = (current_failed & previous_failed).to_a
      else
        newly_passing = []
        regressions = []
        still_failing = current_failed.to_a
      end

      SpecTestProgress.new(
        total_tests: current_results[:total],
        total_passing: current_results[:passing_count],
        newly_passing: newly_passing,
        regressions: regressions,
        still_failing: still_failing
      )
    end
  end
end

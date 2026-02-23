require "json"
require "logger"
require "arnold_pipeline/providers/llm/base"

module ArnoldPipeline
  class CorrectiveTaskGenerator
    CATEGORIES = {
      view_markup: {
        label: "view-fix",
        location_pattern: /views\//i,
        message_pattern: /element.matching|no.matching|css.selector|expected.to.have/i
      },
      integration_expectation: {
        label: "integration-fix",
        location_pattern: /integration\//i,
        message_pattern: /expected.*(?:got|but was|to eq|to match)/i
      },
      unit_expectation: {
        label: "unit-fix",
        location_pattern: nil,
        message_pattern: /expected.*(?:got|but was|to eq|to match|to be)/i
      },
      missing_reference: {
        label: "missing-ref",
        location_pattern: nil,
        message_pattern: /\b(?:nil|undefined|nameerror|uninitialized|no method)\b/i
      },
      routing: {
        label: "routing-fix",
        location_pattern: nil,
        message_pattern: /\b(?:routing|no route|actioncontroller::routingerror)\b/i
      },
      general: {
        label: "bugfix",
        location_pattern: nil,
        message_pattern: nil
      }
    }.freeze

    RESPONSE_SCHEMA = {
      name: "corrective_tasks",
      schema: {
        type: "object", additionalProperties: false,
        required: ["tasks"],
        properties: {
          tasks: {
            type: "array",
            items: {
              type: "object", additionalProperties: false,
              required: ["title", "description", "labels"],
              properties: {
                title: { type: "string" },
                description: { type: "string" },
                labels: { type: "array", items: { type: "string" } }
              }
            }
          }
        }
      }
    }.freeze

    MAX_FAILURES_PER_CATEGORY = 5

    def self.call(test_result:, diffs:, task_summaries:, repo_context: nil, llm_client: nil, logger: nil)
      new(
        test_result:,
        diffs:,
        task_summaries:,
        repo_context:,
        llm_client:,
        logger: logger || Logger.new($stdout, level: Logger::WARN)
      ).call
    end

    def initialize(test_result:, diffs:, task_summaries:, repo_context: nil, llm_client: nil, logger:)
      @test_result = test_result
      @diffs = diffs
      @task_summaries = task_summaries
      @repo_context = repo_context
      @llm_client = llm_client
      @logger = logger
    end

    def call
      return [] unless @test_result.has_issues?

      if @test_result.failures.empty?
        @logger.warn { "Test failures detected but no individual failures parsed — generating generic corrective task" }
        return [generic_failure_task]
      end

      grouped = group_failures_by_category(@test_result.failures)
      return [] if grouped.empty?

      grouped.flat_map do |category, failures|
        generate_task_for_category(category, failures)
      end.compact
    end

    private

    def group_failures_by_category(failures)
      grouped = {}

      failures.each do |failure|
        category = categorize_failure(failure)
        grouped[category] ||= []
        grouped[category] << failure
      end

      grouped
    end

    def categorize_failure(failure)
      location = failure[:location].to_s
      message = failure[:message].to_s

      # Order matters: more specific categories first
      if CATEGORIES[:view_markup][:location_pattern]&.match?(location) ||
         CATEGORIES[:view_markup][:message_pattern]&.match?(message)
        :view_markup
      elsif CATEGORIES[:integration_expectation][:location_pattern]&.match?(location) &&
            CATEGORIES[:integration_expectation][:message_pattern]&.match?(message)
        :integration_expectation
      elsif CATEGORIES[:routing][:message_pattern]&.match?(message)
        :routing
      elsif CATEGORIES[:missing_reference][:message_pattern]&.match?(message)
        :missing_reference
      elsif CATEGORIES[:unit_expectation][:message_pattern]&.match?(message)
        :unit_expectation
      else
        :general
      end
    end

    def generate_task_for_category(category, failures)
      limited_failures = failures.first(MAX_FAILURES_PER_CATEGORY)

      begin
        llm_task = generate_via_llm(category, limited_failures)
        return llm_task if llm_task && !llm_task.empty?
      rescue => e
        @logger.warn { "LLM corrective task generation failed for #{category}: #{e.message}" }
      end

      [build_fallback_task(category, limited_failures)]
    end

    def generate_via_llm(category, failures)
      client = @llm_client || Providers::Llm.build
      category_info = CATEGORIES[category]

      system_prompt = <<~SYSTEM
        You are a test failure analyst. Given test failures grouped by category,
        generate a single corrective task that a coding agent can use to fix the issues.
        The task description must include specific file:line references and tell the agent
        exactly what to change and where.
      SYSTEM

      failure_details = failures.map do |f|
        location = f[:location] ? " at #{f[:location]}" : ""
        "- #{f[:name]}#{location}: #{f[:message]}"
      end.join("\n")

      user_prompt = <<~USER
        ## Failure Category: #{category}

        ### Test Failures (#{failures.size} total)
        #{failure_details}

        ### Code Diffs
        #{@diffs}

        ### Task Summaries
        #{@task_summaries}
        #{repo_context_section}

        Generate exactly ONE corrective task for this category of failures.
        Include the label "#{category_info[:label]}" in the labels array.
        The description should reference specific files and line numbers from the failures.
      USER

      result = client.chat_json(
        messages: [{ role: :user, content: user_prompt }],
        system: system_prompt,
        schema: RESPONSE_SCHEMA
      )

      result&.dig("tasks")
    end

    def repo_context_section
      return "" unless @repo_context

      <<~SECTION

        ### Repository Context
        #{@repo_context}
      SECTION
    end

    def build_fallback_task(category, failures)
      category_info = CATEGORIES[category]

      file_refs = failures.filter_map { |f| f[:location] }.uniq
      ref_text = file_refs.any? ? "\n\nAffected locations:\n#{file_refs.map { |r| "- #{r}" }.join("\n")}" : ""

      failure_summary = failures.map { |f| "- #{f[:name]}: #{f[:message]}" }.join("\n")

      {
        "title" => "Fix #{category.to_s.tr('_', ' ')} failures (#{failures.size} test#{'s' if failures.size != 1})",
        "description" => "#{failures.size} test failure#{'s' if failures.size != 1} in the #{category} category need fixing.\n\nFailures:\n#{failure_summary}#{ref_text}",
        "labels" => [category_info[:label]]
      }
    end

    def generic_failure_task
      {
        "title" => "Fix test failures: #{@test_result.summary}",
        "description" => "The test suite failed but individual failure details could not be parsed from the output.\n\n" \
          "## Test Summary\n#{@test_result.summary}\n\n" \
          "## Instructions\nRun the full test suite, identify all failures and errors, and fix them.\n" \
          "Focus on errors first (often missing constants, undefined methods) as these frequently cause cascading failures.",
        "labels" => ["test-fix"]
      }
    end
  end
end

require "test_helper"
require "arnold_pipeline/prompts/analysis"
require "arnold_pipeline/library/manager"

module ArnoldPipeline
  module Prompts
    class AnalysisTest < ActiveSupport::TestCase
      setup do
        @manager = Library::Manager.new
        @persona = @manager.find_persona("testing quality review")
      end

      test "system_prompt includes completeness test names" do
        prompt = Analysis.system_prompt(persona: @persona)
        assert_includes prompt, "NEW READER TEST"
        assert_includes prompt, "CODING AGENT TEST"
        assert_includes prompt, "CHANGE REQUEST TEST"
      end

      test "system_prompt includes anti-pattern detection" do
        prompt = Analysis.system_prompt(persona: @persona)
        anti_patterns = [
          "ORPHANED REFERENCE", "CONTRADICTORY SPECIFICATION", "VAGUE QUANTITY",
          "MISSING NEGATIVE", "LAZY IDEA DROP", "ASSUMED UNDERSTANDING", "TECHNICAL LEAK"
        ]
        anti_patterns.each do |ap|
          assert_includes prompt, ap, "Missing anti-pattern: #{ap}"
        end
      end

      test "system_prompt includes completeness_scores in output format" do
        prompt = Analysis.system_prompt(persona: @persona)
        assert_includes prompt, "completeness_scores"
        assert_includes prompt, "new_reader_test"
        assert_includes prompt, "coding_agent_test"
        assert_includes prompt, "change_request_test"
      end

      test "system_prompt includes anti_patterns_found in output format" do
        prompt = Analysis.system_prompt(persona: @persona)
        assert_includes prompt, "anti_patterns_found"
      end

      test "system_prompt includes decision options" do
        prompt = Analysis.system_prompt(persona: @persona)
        assert_includes prompt, "done"
        assert_includes prompt, "iterate_tasks"
        assert_includes prompt, "iterate_spec"
      end

      test "system_prompt includes persona" do
        prompt = Analysis.system_prompt(persona: @persona)
        assert_includes prompt, @persona.system_prompt
      end

      test "system_prompt includes task results guidance" do
        prompt = Analysis.system_prompt(persona: @persona)
        assert_includes prompt, "Task Results"
        assert_includes prompt, "blocked dependencies"
      end

      test "user_prompt includes comments section when provided" do
        prompt = Analysis.user_prompt(
          spec_content: "# Spec",
          diffs: "diff content",
          iteration_number: 1,
          comments: "### Task: Setup DB (failed)\n[issue] copilot: Missing Gemfile"
        )
        assert_includes prompt, "## Task Comments / Agent Feedback"
        assert_includes prompt, "Missing Gemfile"
      end

      test "user_prompt omits comments section when empty" do
        prompt = Analysis.user_prompt(
          spec_content: "# Spec",
          diffs: "diff content",
          iteration_number: 1,
          comments: ""
        )
        refute_includes prompt, "## Task Comments / Agent Feedback"
      end

      test "system_prompt includes delta format for iterate_spec" do
        prompt = Analysis.system_prompt(persona: @persona)
        assert_includes prompt, "deltas"
        assert_includes prompt, '"operation": "added"'
        assert_includes prompt, '"operation": "modified"'
        assert_includes prompt, '"operation": "removed"'
        assert_includes prompt, "GIVEN"
        assert_includes prompt, "WHEN"
        assert_includes prompt, "THEN"
        assert_includes prompt, "### Requirement:"
        assert_includes prompt, "#### Scenario:"
      end

      test "system_prompt includes requirement_coverage in output format" do
        prompt = Analysis.system_prompt(persona: @persona)
        assert_includes prompt, "requirement_coverage"
        assert_includes prompt, "REQ-AUTH-001"
      end

      test "user_prompt omits comments section when not provided" do
        prompt = Analysis.user_prompt(
          spec_content: "# Spec",
          diffs: "diff content",
          iteration_number: 1
        )
        refute_includes prompt, "## Task Comments / Agent Feedback"
      end
    end
  end
end

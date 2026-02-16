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

      # --- Iteration context tests ---

      test "user_prompt includes iteration X of Y when max_iterations provided" do
        prompt = Analysis.user_prompt(
          spec_content: "# Spec", diffs: "diff", iteration_number: 2,
          max_iterations: 5
        )
        assert_includes prompt, "iteration 2 of 5"
      end

      test "user_prompt backward compatible without new params" do
        prompt = Analysis.user_prompt(
          spec_content: "# Spec", diffs: "diff", iteration_number: 1
        )
        refute_includes prompt, "## Iteration Context"
      end

      test "user_prompt includes FINAL ITERATION language on last iteration" do
        prompt = Analysis.user_prompt(
          spec_content: "# Spec", diffs: "diff", iteration_number: 3,
          max_iterations: 3, previous_decisions: [
            { iteration: 1, decision: "iterate_tasks", confidence: 75, reasoning_excerpt: "Missing auth" },
            { iteration: 2, decision: "iterate_tasks", confidence: 80, reasoning_excerpt: "Missing tests" }
          ]
        )
        assert_includes prompt, "FINAL ITERATION"
        assert_includes prompt, "MUST choose"
      end

      test "user_prompt includes penultimate iteration language" do
        prompt = Analysis.user_prompt(
          spec_content: "# Spec", diffs: "diff", iteration_number: 4,
          max_iterations: 5, previous_decisions: [
            { iteration: 1, decision: "iterate_tasks", confidence: 70, reasoning_excerpt: "..." },
            { iteration: 2, decision: "iterate_tasks", confidence: 75, reasoning_excerpt: "..." },
            { iteration: 3, decision: "iterate_tasks", confidence: 80, reasoning_excerpt: "..." }
          ]
        )
        assert_includes prompt, "penultimate iteration"
        assert_includes prompt, "Strongly prefer"
      end

      test "user_prompt includes half-budget language" do
        prompt = Analysis.user_prompt(
          spec_content: "# Spec", diffs: "diff", iteration_number: 3,
          max_iterations: 5, previous_decisions: [
            { iteration: 1, decision: "iterate_tasks", confidence: 70, reasoning_excerpt: "..." },
            { iteration: 2, decision: "done", confidence: 75, reasoning_excerpt: "..." }
          ]
        )
        assert_includes prompt, "half the iteration budget"
        assert_includes prompt, "Bias toward"
      end

      test "user_prompt lists previous decisions" do
        prompt = Analysis.user_prompt(
          spec_content: "# Spec", diffs: "diff", iteration_number: 2,
          max_iterations: 5, previous_decisions: [
            { iteration: 1, decision: "iterate_tasks", confidence: 75, reasoning_excerpt: "Missing auth handler" }
          ]
        )
        assert_includes prompt, "### Previous Decisions"
        assert_includes prompt, "Iteration 1"
        assert_includes prompt, "**iterate_tasks**"
        assert_includes prompt, "75%"
        assert_includes prompt, "Missing auth handler"
      end

      test "user_prompt includes stuck detection when all previous iterate_tasks" do
        prompt = Analysis.user_prompt(
          spec_content: "# Spec", diffs: "diff", iteration_number: 3,
          max_iterations: 5, previous_decisions: [
            { iteration: 1, decision: "iterate_tasks", confidence: 70, reasoning_excerpt: "..." },
            { iteration: 2, decision: "iterate_tasks", confidence: 75, reasoning_excerpt: "..." }
          ]
        )
        assert_includes prompt, "STUCK DETECTION"
      end

      test "user_prompt omits stuck detection with mixed decisions" do
        prompt = Analysis.user_prompt(
          spec_content: "# Spec", diffs: "diff", iteration_number: 3,
          max_iterations: 5, previous_decisions: [
            { iteration: 1, decision: "iterate_spec", confidence: 60, reasoning_excerpt: "..." },
            { iteration: 2, decision: "iterate_tasks", confidence: 75, reasoning_excerpt: "..." }
          ]
        )
        refute_includes prompt, "STUCK DETECTION"
      end

      test "user_prompt no convergence pressure early in budget" do
        prompt = Analysis.user_prompt(
          spec_content: "# Spec", diffs: "diff", iteration_number: 1,
          max_iterations: 5
        )
        assert_includes prompt, "## Iteration Context"
        refute_includes prompt, "Bias toward"
        refute_includes prompt, "Strongly prefer"
        refute_includes prompt, "MUST choose"
      end
    end
  end
end

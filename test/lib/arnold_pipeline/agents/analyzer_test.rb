require "test_helper"
require "arnold_pipeline/agents/analyzer"
require "arnold_pipeline/library/manager"
require "json_schemer"

module ArnoldPipeline
  module Agents
    class AnalyzerTest < ActiveSupport::TestCase
      setup do
        @llm = stub("llm")
        @agent = Analyzer.new(llm: @llm, logger: Logger.new(File::NULL))
        @persona = Library::Manager.new.find_persona("testing quality")
      end

      test "returns parsed analysis with done decision" do
        analysis = {
          "decision" => "done",
          "confidence" => 95,
          "reasoning" => "All features implemented correctly",
          "completeness_scores" => { "new_reader_test" => 90, "coding_agent_test" => 95, "change_request_test" => 85 },
          "anti_patterns_found" => [],
          "corrective_data" => { "tasks" => nil, "deltas" => nil },
          "requirement_coverage" => nil
        }
        @llm.expects(:chat_json).returns(analysis)

        result = @agent.call(
          spec_content: "# Spec", diffs: "diff content",
          iteration_number: 1, persona: @persona
        )

        assert_equal "done", result["decision"]
        assert_equal 95, result["confidence"]
      end

      test "returns iterate_tasks decision" do
        analysis = {
          "decision" => "iterate_tasks",
          "confidence" => 75,
          "reasoning" => "Missing error handling",
          "completeness_scores" => { "new_reader_test" => 70, "coding_agent_test" => 65, "change_request_test" => 60 },
          "anti_patterns_found" => [],
          "corrective_data" => {
            "tasks" => [{ "title" => "Add error handling", "description" => "...", "priority" => 0, "labels" => ["bugfix"], "depends_on" => [] }],
            "deltas" => nil
          },
          "requirement_coverage" => nil
        }
        @llm.expects(:chat_json).returns(analysis)

        result = @agent.call(
          spec_content: "# Spec", diffs: "diff content",
          iteration_number: 2, persona: @persona
        )

        assert_equal "iterate_tasks", result["decision"]
        assert_equal 75, result["confidence"]
      end

      test "raises on invalid decision" do
        analysis = {
          "decision" => "invalid", "confidence" => 50, "reasoning" => "test",
          "completeness_scores" => { "new_reader_test" => 50, "coding_agent_test" => 50, "change_request_test" => 50 },
          "anti_patterns_found" => [], "corrective_data" => { "tasks" => nil, "deltas" => nil },
          "requirement_coverage" => nil
        }
        @llm.expects(:chat_json).returns(analysis)

        assert_raises(ArnoldPipeline::Error) do
          @agent.call(spec_content: "spec", diffs: "diff", iteration_number: 1, persona: @persona)
        end
      end

      test "raises on invalid confidence" do
        analysis = {
          "decision" => "done", "confidence" => 150, "reasoning" => "test",
          "completeness_scores" => { "new_reader_test" => 50, "coding_agent_test" => 50, "change_request_test" => 50 },
          "anti_patterns_found" => [], "corrective_data" => { "tasks" => nil, "deltas" => nil },
          "requirement_coverage" => nil
        }
        @llm.expects(:chat_json).returns(analysis)

        assert_raises(ArnoldPipeline::Error) do
          @agent.call(spec_content: "spec", diffs: "diff", iteration_number: 1, persona: @persona)
        end
      end

      test "accepts valid completeness_scores" do
        analysis = {
          "decision" => "done",
          "confidence" => 90,
          "reasoning" => "Well done",
          "completeness_scores" => {
            "new_reader_test" => 85,
            "coding_agent_test" => 90,
            "change_request_test" => 80
          },
          "anti_patterns_found" => [],
          "corrective_data" => { "tasks" => nil, "deltas" => nil },
          "requirement_coverage" => nil
        }
        @llm.expects(:chat_json).returns(analysis)

        result = @agent.call(spec_content: "spec", diffs: "diff", iteration_number: 1, persona: @persona)

        assert_equal 85, result["completeness_scores"]["new_reader_test"]
        assert_equal 90, result["completeness_scores"]["coding_agent_test"]
        assert_equal 80, result["completeness_scores"]["change_request_test"]
      end

      test "passes comments through to prompt" do
        analysis = {
          "decision" => "done",
          "confidence" => 90,
          "reasoning" => "Analysis complete",
          "completeness_scores" => { "new_reader_test" => 90, "coding_agent_test" => 90, "change_request_test" => 90 },
          "anti_patterns_found" => [],
          "corrective_data" => { "tasks" => nil, "deltas" => nil },
          "requirement_coverage" => nil
        }
        @llm.expects(:chat_json).with { |params|
          user_msg = params[:messages].first[:content]
          user_msg.include?("## Task Comments / Agent Feedback") &&
            user_msg.include?("Missing Gemfile")
        }.returns(analysis)

        @agent.call(
          spec_content: "# Spec",
          diffs: "diff content",
          iteration_number: 1,
          persona: @persona,
          comments: "### Task: Setup DB (failed)\n[issue] copilot: Missing Gemfile"
        )
      end

      test "result without completeness_scores is still valid" do
        analysis = {
          "decision" => "done",
          "confidence" => 95,
          "reasoning" => "All good",
          "completeness_scores" => { "new_reader_test" => 95, "coding_agent_test" => 95, "change_request_test" => 95 },
          "anti_patterns_found" => [],
          "corrective_data" => { "tasks" => nil, "deltas" => nil },
          "requirement_coverage" => nil
        }
        @llm.expects(:chat_json).returns(analysis)

        result = @agent.call(spec_content: "spec", diffs: "diff", iteration_number: 1, persona: @persona)
        assert_equal "done", result["decision"]
      end

      test "passes max_iterations and previous_decisions through to prompt" do
        analysis = {
          "decision" => "done",
          "confidence" => 90,
          "reasoning" => "Analysis complete",
          "completeness_scores" => { "new_reader_test" => 90, "coding_agent_test" => 90, "change_request_test" => 90 },
          "anti_patterns_found" => [],
          "corrective_data" => { "tasks" => nil, "deltas" => nil },
          "requirement_coverage" => nil
        }
        @llm.expects(:chat_json).with { |params|
          user_msg = params[:messages].first[:content]
          user_msg.include?("iteration 2 of 3") &&
            user_msg.include?("### Previous Decisions") &&
            user_msg.include?("**iterate_tasks**")
        }.returns(analysis)

        @agent.call(
          spec_content: "# Spec",
          diffs: "diff content",
          iteration_number: 2,
          persona: @persona,
          max_iterations: 3,
          previous_decisions: [
            { iteration: 1, decision: "iterate_tasks", confidence: 75, reasoning_excerpt: "Missing auth" }
          ]
        )
      end

      # -- Schema validation --

      test "RESPONSE_SCHEMA validates a done response" do
        schemer = JSONSchemer.schema(Analyzer::RESPONSE_SCHEMA[:schema])
        data = {
          "decision" => "done", "confidence" => 95, "reasoning" => "All good",
          "completeness_scores" => { "new_reader_test" => 90, "coding_agent_test" => 95, "change_request_test" => 85 },
          "anti_patterns_found" => [],
          "corrective_data" => { "tasks" => nil, "deltas" => nil },
          "requirement_coverage" => nil
        }
        assert schemer.valid?(data), "Expected valid, got: #{schemer.validate(data).map(&:to_h)}"
      end

      test "RESPONSE_SCHEMA validates an iterate_tasks response" do
        schemer = JSONSchemer.schema(Analyzer::RESPONSE_SCHEMA[:schema])
        data = {
          "decision" => "iterate_tasks", "confidence" => 70, "reasoning" => "Missing features",
          "completeness_scores" => { "new_reader_test" => 60, "coding_agent_test" => 50, "change_request_test" => 55 },
          "anti_patterns_found" => ["ORPHANED_REFERENCE: User model referenced but not defined"],
          "corrective_data" => {
            "tasks" => [{ "title" => "Fix auth", "description" => "Add login", "priority" => 0, "labels" => ["backend"], "depends_on" => [] }],
            "deltas" => nil
          },
          "requirement_coverage" => [{ "id" => "REQ-AUTH-001", "status" => "partial", "notes" => "Missing OAuth" }]
        }
        assert schemer.valid?(data), "Expected valid, got: #{schemer.validate(data).map(&:to_h)}"
      end

      test "RESPONSE_SCHEMA validates an iterate_spec response with deltas" do
        schemer = JSONSchemer.schema(Analyzer::RESPONSE_SCHEMA[:schema])
        data = {
          "decision" => "iterate_spec", "confidence" => 60, "reasoning" => "Spec is ambiguous",
          "completeness_scores" => { "new_reader_test" => 40, "coding_agent_test" => 35, "change_request_test" => 45 },
          "anti_patterns_found" => [],
          "corrective_data" => {
            "tasks" => nil,
            "deltas" => [{
              "operation" => "modified", "section" => "Auth", "requirement" => "Login",
              "content" => nil, "before_content" => "old", "after_content" => "new", "rationale" => "Clarify"
            }]
          },
          "requirement_coverage" => nil
        }
        assert schemer.valid?(data), "Expected valid, got: #{schemer.validate(data).map(&:to_h)}"
      end
    end
  end
end

require "test_helper"
require "arnold_pipeline/agents/analyzer"
require "arnold_pipeline/library/manager"

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
          "corrective_data" => {}
        }
        @llm.expects(:chat).returns("```json\n#{JSON.generate(analysis)}\n```")

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
          "corrective_data" => {
            "tasks" => [{ "title" => "Add error handling", "description" => "..." }]
          }
        }
        @llm.expects(:chat).returns("```json\n#{JSON.generate(analysis)}\n```")

        result = @agent.call(
          spec_content: "# Spec", diffs: "diff content",
          iteration_number: 2, persona: @persona
        )

        assert_equal "iterate_tasks", result["decision"]
        assert_equal 75, result["confidence"]
      end

      test "raises on invalid decision" do
        analysis = { "decision" => "invalid", "confidence" => 50, "reasoning" => "test" }
        @llm.expects(:chat).returns("```json\n#{JSON.generate(analysis)}\n```")

        assert_raises(ArnoldPipeline::Error) do
          @agent.call(spec_content: "spec", diffs: "diff", iteration_number: 1, persona: @persona)
        end
      end

      test "raises on invalid confidence" do
        analysis = { "decision" => "done", "confidence" => 150, "reasoning" => "test" }
        @llm.expects(:chat).returns("```json\n#{JSON.generate(analysis)}\n```")

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
          "corrective_data" => {}
        }
        @llm.expects(:chat).returns("```json\n#{JSON.generate(analysis)}\n```")

        result = @agent.call(spec_content: "spec", diffs: "diff", iteration_number: 1, persona: @persona)

        assert_equal 85, result["completeness_scores"]["new_reader_test"]
        assert_equal 90, result["completeness_scores"]["coding_agent_test"]
        assert_equal 80, result["completeness_scores"]["change_request_test"]
      end

      test "warns but does not raise on invalid completeness_scores" do
        analysis = {
          "decision" => "done",
          "confidence" => 90,
          "reasoning" => "test",
          "completeness_scores" => "not a hash",
          "corrective_data" => {}
        }
        @llm.expects(:chat).returns("```json\n#{JSON.generate(analysis)}\n```")

        result = @agent.call(spec_content: "spec", diffs: "diff", iteration_number: 1, persona: @persona)
        assert_equal "done", result["decision"]
      end

      test "passes comments through to prompt" do
        analysis = {
          "decision" => "done",
          "confidence" => 90,
          "reasoning" => "Analysis complete",
          "corrective_data" => {}
        }
        @llm.expects(:chat).with { |params|
          user_msg = params[:messages].first[:content]
          user_msg.include?("## Task Comments / Agent Feedback") &&
            user_msg.include?("Missing Gemfile")
        }.returns("```json\n#{JSON.generate(analysis)}\n```")

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
          "corrective_data" => {}
        }
        @llm.expects(:chat).returns("```json\n#{JSON.generate(analysis)}\n```")

        result = @agent.call(spec_content: "spec", diffs: "diff", iteration_number: 1, persona: @persona)
        assert_equal "done", result["decision"]
        assert_nil result["completeness_scores"]
      end
    end
  end
end

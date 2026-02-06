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
    end
  end
end

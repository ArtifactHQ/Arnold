require "test_helper"
require "arnold_pipeline/agents/concern_diff_analyzer"

module ArnoldPipeline
  module Agents
    class ConcernDiffAnalyzerTest < ActiveSupport::TestCase
      setup do
        @llm = mock("llm")
        @agent = ConcernDiffAnalyzer.new(llm: @llm)
      end

      test "returns delta_concerns from LLM analysis" do
        result = {
          "delta_concerns" => [
            { "concern_id" => "auth", "delta_type" => "modify", "rationale" => "OAuth changes auth flow" }
          ],
          "summary" => "Auth system modification"
        }

        @llm.expects(:chat_json).once.returns(result)

        output = @agent.call(
          as_built_spec: "# Spec\n## Purpose\nA test app",
          change_request: "Add OAuth",
          concern_ids: ["auth", "data_layer"]
        )

        assert_equal 1, output["delta_concerns"].size
        assert_equal "auth", output["delta_concerns"].first["concern_id"]
        assert_equal "modify", output["delta_concerns"].first["delta_type"]
      end

      test "returns empty delta_concerns when no concerns affected" do
        result = {
          "delta_concerns" => [],
          "summary" => "No concerns affected"
        }

        @llm.expects(:chat_json).once.returns(result)

        output = @agent.call(
          as_built_spec: "# Spec",
          change_request: "Minor docs update",
          concern_ids: ["auth"]
        )

        assert_empty output["delta_concerns"]
      end

      test "passes schema to chat_json" do
        result = { "delta_concerns" => [], "summary" => "test" }

        @llm.expects(:chat_json).with { |messages:, schema:, **|
          schema[:name] == "concern_diff_analysis" &&
          schema[:schema][:properties].key?(:delta_concerns)
        }.returns(result)

        @agent.call(
          as_built_spec: "# Spec",
          change_request: "Add feature",
          concern_ids: ["auth"]
        )
      end
    end
  end
end

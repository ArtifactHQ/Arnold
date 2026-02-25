require "test_helper"
require "arnold_pipeline/mcp/context"
require "arnold_pipeline/providers/llm/base"
require "arnold_pipeline/mcp/tools/propose_change"

module ArnoldPipeline
  module Mcp
    module Tools
      class ProposeChangeTest < ActiveSupport::TestCase
        cover "ArnoldPipeline::Mcp::Tools::ProposeChange*"

        setup do
          @context = Context.new
          @run = PipelineRun.create!(nl_input: "Build a fitness tracking app")
          @spec = Specification.create!(
            pipeline_run: @run,
            content: "# Fitness Tracker\n\n## Purpose\nA fitness app.\n\n## Requirements\n- Track workouts",
            version: 1,
            structured_data: {
              "personas" => [{ "name" => "Athlete" }],
              "domains" => [{ "name" => "Workouts" }, { "name" => "Nutrition" }]
            }
          )

          @llm_response = {
            "summary" => "Added social sharing capability",
            "deltas" => [
              {
                "operation" => "added",
                "section" => "Workouts",
                "requirement" => "Social Sharing",
                "content" => "### Requirement: Social Sharing [REQ-SOCIAL-001]\nShare workout results.",
                "before_content" => "",
                "after_content" => "",
                "rationale" => "User requested social features"
              }
            ]
          }

          # Stub the LLM provider to avoid real API calls
          @llm_stub = stub("llm")
          ArnoldPipeline::Providers::Llm.stubs(:build).returns(@llm_stub)
          @llm_stub.stubs(:chat_json).returns(@llm_response)
          @llm_stub.stubs(:chat).returns(JSON.generate(@llm_response))
        end

        teardown do
          ArnoldPipeline.reset_configuration!
          ProposeChange.clear_proposals!
        end

        test "tool_name returns propose_change" do
          assert_equal "propose_change", ProposeChange.tool_name
        end

        test "description is present" do
          assert_kind_of String, ProposeChange.description
          refute_empty ProposeChange.description
        end

        test "input_schema requires description" do
          schema = ProposeChange.input_schema
          assert_equal "object", schema[:type]
          assert schema[:properties].key?(:description)
          assert_includes schema[:required], "description"
        end

        test "call returns proposal with change_id" do
          result = ProposeChange.call({ "description" => "Add social sharing" }, @context)

          assert result.key?(:change_id)
          assert_match(/\A[0-9a-f-]{36}\z/, result[:change_id])
        end

        test "call returns summary from analysis" do
          result = ProposeChange.call({ "description" => "Add social sharing" }, @context)
          assert_equal "Added social sharing capability", result[:summary]
        end

        test "call returns impact with domains affected" do
          result = ProposeChange.call({ "description" => "Add social sharing" }, @context)

          assert result[:impact].key?(:domains_affected)
          affected = result[:impact][:domains_affected]
          assert_kind_of Array, affected
          assert affected.any? { |d| d[:domain] == "Workouts" }
        end

        test "call returns impact with new capabilities" do
          result = ProposeChange.call({ "description" => "Add social sharing" }, @context)

          assert_includes result[:impact][:new_capabilities], "Social Sharing"
        end

        test "call returns impact with modified capabilities" do
          @llm_response["deltas"] = [{
            "operation" => "modified",
            "section" => "Workouts",
            "requirement" => "Track Exercises",
            "content" => "",
            "before_content" => "Old",
            "after_content" => "New",
            "rationale" => "Updated"
          }]
          @llm_stub.stubs(:chat_json).returns(@llm_response)

          result = ProposeChange.call({ "description" => "Modify tracking" }, @context)
          assert_includes result[:impact][:modified_capabilities], "Track Exercises"
        end

        test "call returns impact with removed capabilities" do
          @llm_response["deltas"] = [{
            "operation" => "removed",
            "section" => "Nutrition",
            "requirement" => "Calorie Counting",
            "content" => "",
            "before_content" => "",
            "after_content" => "",
            "rationale" => "No longer needed"
          }]
          @llm_stub.stubs(:chat_json).returns(@llm_response)

          result = ProposeChange.call({ "description" => "Remove calories" }, @context)

          assert_includes result[:impact][:removed_capabilities], "Calorie Counting"
          assert result[:questions].any? { |q| q.include?("Removing") }
        end

        test "call returns questions for removed capabilities" do
          @llm_response["deltas"] = [{
            "operation" => "removed",
            "section" => "Nutrition",
            "requirement" => "Calorie Counting",
            "content" => "",
            "before_content" => "",
            "after_content" => "",
            "rationale" => "Simplification"
          }]
          @llm_stub.stubs(:chat_json).returns(@llm_response)

          result = ProposeChange.call({ "description" => "Remove calories" }, @context)
          assert result[:questions].any? { |q| q.include?("Calorie Counting") }
        end

        test "call returns high confidence when no questions" do
          result = ProposeChange.call({ "description" => "Add social sharing" }, @context)
          assert_equal "high", result[:confidence]
        end

        test "call returns low confidence when no deltas" do
          @llm_response["deltas"] = []
          @llm_stub.stubs(:chat_json).returns(@llm_response)

          result = ProposeChange.call({ "description" => "Vague change" }, @context)
          assert_equal "low", result[:confidence]
        end

        test "call stores proposal for later confirmation" do
          result = ProposeChange.call({ "description" => "Add social sharing" }, @context)

          proposal = ProposeChange.proposals[result[:change_id]]
          assert_not_nil proposal
          assert_equal @run.id, proposal[:run_id]
          assert_equal "Add social sharing", proposal[:description]
          assert_not_nil proposal[:analysis]
        end

        test "call returns error when description is empty" do
          result = ProposeChange.call({ "description" => "" }, @context)
          assert_equal "Change description is required", result[:error]
        end

        test "call returns error when no pipeline run found" do
          PipelineRun.destroy_all
          result = ProposeChange.call({ "description" => "Add feature" }, @context)
          assert_equal "No pipeline run found", result[:error]
        end

        test "call returns error when no specification found" do
          run_no_spec = PipelineRun.create!(nl_input: "no spec")
          result = ProposeChange.call({ "description" => "Add feature", "run_id" => run_no_spec.id.to_s }, @context)
          assert_includes result[:error], "No specification found"
        end

        test "call handles LLM failure gracefully" do
          ArnoldPipeline::Providers::Llm.stubs(:build).raises(StandardError.new("API unavailable"))

          result = ProposeChange.call({ "description" => "Add feature" }, @context)

          # Should still return a result with low confidence
          assert result.key?(:change_id)
          assert_equal "low", result[:confidence]
          assert_includes result[:summary], "Unable to perform full analysis"
        end

        test "nil run_id falls back to latest run" do
          result = ProposeChange.call({ "description" => "Add feature", "run_id" => nil }, @context)
          assert result.key?(:change_id)
        end

        test "call response has all expected keys" do
          result = ProposeChange.call({ "description" => "Add social sharing" }, @context)

          assert result.key?(:change_id)
          assert result.key?(:summary)
          assert result.key?(:impact)
          assert result.key?(:questions)
          assert result.key?(:confidence)

          impact = result[:impact]
          assert impact.key?(:domains_affected)
          assert impact.key?(:personas_affected)
          assert impact.key?(:new_capabilities)
          assert impact.key?(:modified_capabilities)
          assert impact.key?(:removed_capabilities)
        end
      end
    end
  end
end

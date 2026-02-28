require "test_helper"
require "arnold_pipeline/mcp/context"
require "arnold_pipeline/mcp/tools/explore_capability"

module ArnoldPipeline
  module Mcp
    module Tools
      class ExploreCapabilityTest < ActiveSupport::TestCase
        cover "ArnoldPipeline::Mcp::Tools::ExploreCapability*"

        setup do
          @context = Context.new
          @run = PipelineRun.create!(nl_input: "Build a dog walking app")
          @spec = Specification.create!(
            pipeline_run: @run,
            content: "# Dog Walking App\n\n## Purpose\nConnect dog walkers with dog owners.\n\n## Booking\n- Schedule walks\n- Cancel bookings\n\n## Messaging\n- In-app chat",
            version: 1,
            structured_data: {
              "personas" => [
                { "name" => "Dog Owner", "description" => "Books walks" },
                { "name" => "Dog Walker", "description" => "Fulfills walks" }
              ],
              "domains" => [
                { "name" => "Booking", "description" => "Walk scheduling and management" },
                { "name" => "Messaging", "description" => "In-app communication" }
              ]
            }
          )

          @llm_response = {
            "capability" => "Walk Booking",
            "domain" => "Booking",
            "description" => "Allows dog owners to schedule on-demand or future walks with available walkers.",
            "user_flow" => "1. Owner opens app\n2. Selects walk type\n3. Chooses time\n4. Confirms booking\n5. Receives walker match",
            "personas_involved" => ["Dog Owner", "Dog Walker"],
            "depends_on" => ["User Authentication", "Walker Availability"],
            "enables" => ["Walk Tracking", "Payment Processing"],
            "open_questions" => [
              "Can owners book recurring walks?",
              "How far in advance can walks be scheduled?"
            ]
          }

          @llm_stub = stub("llm")
          @llm_stub.stubs(:chat_json).returns(@llm_response)
          Providers::Llm.stubs(:build).returns(@llm_stub)
        end

        teardown do
          ArnoldPipeline.reset_configuration!
        end

        test "tool_name returns explore_capability" do
          assert_equal "explore_capability", ExploreCapability.tool_name
        end

        test "description is present and non-empty" do
          assert_kind_of String, ExploreCapability.description
          refute_empty ExploreCapability.description
        end

        test "input_schema requires capability" do
          schema = ExploreCapability.input_schema
          assert_equal "object", schema[:type]
          assert schema[:properties].key?(:capability)
          assert_includes schema[:required], "capability"
        end

        test "natural language reference matches capability" do
          result = ExploreCapability.call({ "capability" => "booking system" }, @context)

          assert_equal "Walk Booking", result[:capability]
          assert_equal "Booking", result[:domain]
        end

        test "returns correct domain" do
          result = ExploreCapability.call({ "capability" => "booking" }, @context)

          assert_equal "Booking", result[:domain]
        end

        test "description is detailed" do
          result = ExploreCapability.call({ "capability" => "booking" }, @context)

          assert_kind_of String, result[:description]
          assert result[:description].length > 10
        end

        test "user flow is step-by-step" do
          result = ExploreCapability.call({ "capability" => "booking" }, @context)

          assert_kind_of String, result[:user_flow]
          assert_includes result[:user_flow], "1."
        end

        test "depends_on and enables populated" do
          result = ExploreCapability.call({ "capability" => "booking" }, @context)

          assert_kind_of Array, result[:depends_on]
          assert result[:depends_on].any?
          assert_kind_of Array, result[:enables]
          assert result[:enables].any?
        end

        test "open_questions populated" do
          result = ExploreCapability.call({ "capability" => "booking" }, @context)

          assert_kind_of Array, result[:open_questions]
          assert result[:open_questions].any?
        end

        test "personas involved identified" do
          result = ExploreCapability.call({ "capability" => "booking" }, @context)

          assert_includes result[:personas_involved], "Dog Owner"
          assert_includes result[:personas_involved], "Dog Walker"
        end

        test "call returns error when capability is empty" do
          result = ExploreCapability.call({ "capability" => "" }, @context)
          assert_equal "capability is required", result[:error]
        end

        test "call returns error when no pipeline run found" do
          PipelineRun.destroy_all
          result = ExploreCapability.call({ "capability" => "booking" }, @context)
          assert_equal "No pipeline run found", result[:error]
        end

        test "call returns error when no specification found" do
          run_no_spec = PipelineRun.create!(nl_input: "no spec")
          result = ExploreCapability.call(
            { "capability" => "booking", "run_id" => run_no_spec.id.to_s },
            @context
          )
          assert_includes result[:error], "No specification found"
        end

        test "call falls back gracefully when LLM is unavailable" do
          Providers::Llm.stubs(:build).raises(StandardError.new("API unavailable"))

          result = ExploreCapability.call({ "capability" => "booking" }, @context)

          # Fallback should find the Booking domain match
          assert_equal "booking", result[:capability]
          assert_equal "Booking", result[:domain]
        end

        test "unknown capability with LLM failure returns error" do
          Providers::Llm.stubs(:build).raises(StandardError.new("API unavailable"))

          result = ExploreCapability.call({ "capability" => "nonexistent feature xyz" }, @context)

          assert result.key?(:error)
          assert_includes result[:error], "nonexistent feature xyz"
        end

        test "response has all expected keys" do
          result = ExploreCapability.call({ "capability" => "booking" }, @context)

          assert result.key?(:capability)
          assert result.key?(:domain)
          assert result.key?(:description)
          assert result.key?(:user_flow)
          assert result.key?(:personas_involved)
          assert result.key?(:depends_on)
          assert result.key?(:enables)
          assert result.key?(:open_questions)
        end
      end
    end
  end
end

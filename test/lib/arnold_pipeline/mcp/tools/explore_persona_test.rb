require "test_helper"
require "arnold_pipeline/mcp/context"
require "arnold_pipeline/mcp/tools/explore_persona"

module ArnoldPipeline
  module Mcp
    module Tools
      class ExplorePersonaTest < ActiveSupport::TestCase
        cover "ArnoldPipeline::Mcp::Tools::ExplorePersona*"

        setup do
          @context = Context.new
          @run = PipelineRun.create!(nl_input: "Build a dog walking app")
          @spec = Specification.create!(
            pipeline_run: @run,
            content: "# Dog Walking App\n\n## Purpose\nConnect dog walkers with dog owners.\n\n## Booking\nDog Owner can schedule walks.\n\n## Navigation\nDog Walker uses GPS to navigate routes.",
            version: 1,
            structured_data: {
              "personas" => [
                {
                  "name" => "Dog Owner",
                  "description" => "Books walks for their dogs",
                  "capabilities" => [ "book walks", "track walker", "rate walks" ]
                },
                {
                  "name" => "Dog Walker",
                  "description" => "Accepts and fulfills walk requests",
                  "capabilities" => [ "accept jobs", "navigate routes" ]
                }
              ],
              "domains" => [
                { "name" => "Booking", "description" => "Walk scheduling" },
                { "name" => "Navigation", "description" => "Route management" },
                { "name" => "Payments", "description" => "Payment processing" }
              ]
            }
          )

          @llm_response = {
            "journey" => "The Dog Owner discovers the app, creates an account, books their first walk, and tracks the walker in real time.",
            "capabilities" => [
              { "description" => "Book walks", "domain" => "Booking", "status" => "defined" },
              { "description" => "Track walker location", "domain" => "Navigation", "status" => "defined" },
              { "description" => "Rate completed walks", "domain" => "Booking", "status" => "defined" }
            ],
            "pain_points" => [
              "Finding reliable walkers nearby",
              "Not knowing when the walk will end"
            ]
          }

          @llm_stub = stub("llm")
          @llm_stub.stubs(:chat_json).returns(@llm_response)
          Providers::Llm.stubs(:build).returns(@llm_stub)
        end

        teardown do
          ArnoldPipeline.reset_configuration!
        end

        test "tool_name returns explore_persona" do
          assert_equal "explore_persona", ExplorePersona.tool_name
        end

        test "description is present and non-empty" do
          assert_kind_of String, ExplorePersona.description
          refute_empty ExplorePersona.description
        end

        test "input_schema requires persona" do
          schema = ExplorePersona.input_schema
          assert_equal "object", schema[:type]
          assert schema[:properties].key?(:persona)
          assert_includes schema[:required], "persona"
        end

        test "exact name match finds persona" do
          result = ExplorePersona.call({ "persona" => "Dog Owner" }, @context)

          assert_equal "Dog Owner", result[:persona]
          assert_equal "Books walks for their dogs", result[:description]
        end

        test "fuzzy partial match finds persona" do
          result = ExplorePersona.call({ "persona" => "Walker" }, @context)

          assert_equal "Dog Walker", result[:persona]
        end

        test "case-insensitive match finds persona" do
          result = ExplorePersona.call({ "persona" => "dog owner" }, @context)

          assert_equal "Dog Owner", result[:persona]
        end

        test "unknown persona returns error with available personas" do
          result = ExplorePersona.call({ "persona" => "Cat Sitter" }, @context)

          assert_includes result[:error], "Cat Sitter"
          assert_includes result[:error], "not found"
          assert_includes result[:available_personas], "Dog Owner"
          assert_includes result[:available_personas], "Dog Walker"
        end

        test "journey narrative is populated" do
          result = ExplorePersona.call({ "persona" => "Dog Owner" }, @context)

          assert_kind_of String, result[:journey]
          refute_empty result[:journey]
          assert_includes result[:journey], "Dog Owner"
        end

        test "capabilities organized by domain" do
          result = ExplorePersona.call({ "persona" => "Dog Owner" }, @context)

          assert_kind_of Array, result[:capabilities]
          assert result[:capabilities].any? { |c| c[:domain] == "Booking" }
        end

        test "pain points populated" do
          result = ExplorePersona.call({ "persona" => "Dog Owner" }, @context)

          assert_kind_of Array, result[:pain_points]
          assert result[:pain_points].any? { |pp| pp.include?("reliable") }
        end

        test "domains_involved lists touched domains" do
          result = ExplorePersona.call({ "persona" => "Dog Owner" }, @context)

          assert_kind_of Array, result[:domains_involved]
          assert_includes result[:domains_involved], "Booking"
        end

        test "call returns error when persona is empty" do
          result = ExplorePersona.call({ "persona" => "" }, @context)
          assert_equal "persona is required", result[:error]
        end

        test "call returns error when no pipeline run found" do
          PipelineRun.destroy_all
          result = ExplorePersona.call({ "persona" => "Dog Owner" }, @context)
          assert_equal "No pipeline run found", result[:error]
        end

        test "call returns error when no specification found" do
          run_no_spec = PipelineRun.create!(nl_input: "no spec")
          result = ExplorePersona.call(
            { "persona" => "Dog Owner", "run_id" => run_no_spec.id.to_s },
            @context
          )
          assert_includes result[:error], "No specification found"
        end

        test "call falls back gracefully when LLM is unavailable" do
          Providers::Llm.stubs(:build).raises(StandardError.new("API unavailable"))

          result = ExplorePersona.call({ "persona" => "Dog Owner" }, @context)

          assert_equal "Dog Owner", result[:persona]
          assert_kind_of String, result[:journey]
          assert_kind_of Array, result[:capabilities]
          assert_kind_of Array, result[:pain_points]
        end

        test "response has all expected keys" do
          result = ExplorePersona.call({ "persona" => "Dog Owner" }, @context)

          assert result.key?(:persona)
          assert result.key?(:description)
          assert result.key?(:journey)
          assert result.key?(:capabilities)
          assert result.key?(:pain_points)
          assert result.key?(:domains_involved)
        end
      end
    end
  end
end

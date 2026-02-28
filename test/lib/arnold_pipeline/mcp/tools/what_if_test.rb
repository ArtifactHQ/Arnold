require "test_helper"
require "arnold_pipeline/mcp/context"
require "arnold_pipeline/mcp/tools/what_if"

module ArnoldPipeline
  module Mcp
    module Tools
      class WhatIfTest < ActiveSupport::TestCase
        cover "ArnoldPipeline::Mcp::Tools::WhatIf*"

        setup do
          @context = Context.new
          @run = PipelineRun.create!(nl_input: "Build a dog walking app")
          @spec = Specification.create!(
            pipeline_run: @run,
            content: "# Dog Walking App\n\n## Purpose\nConnect dog walkers with dog owners.\n\n## Booking\n- Schedule walks\n\n## Messaging\n- In-app chat",
            version: 1,
            structured_data: {
              "personas" => [
                { "name" => "Dog Owner", "description" => "Books walks" },
                { "name" => "Dog Walker", "description" => "Fulfills walks" }
              ],
              "domains" => [
                { "name" => "Booking", "description" => "Walk scheduling" },
                { "name" => "Messaging", "description" => "In-app communication" }
              ]
            }
          )
          @initial_spec_version = @spec.version
          @initial_revision_count = SpecRevision.count

          @llm_response = {
            "interpretation" => "Adding group walks would allow multiple dog owners to join a single walking session.",
            "implications" => {
              "new_domains" => [ "Group Coordination" ],
              "affected_domains" => [
                { "domain" => "Booking", "impact" => "Would need multi-owner booking support" }
              ],
              "new_personas" => [ "Group Organizer" ],
              "affected_personas" => [
                { "persona" => "Dog Owner", "impact" => "Can now join group sessions" },
                { "persona" => "Dog Walker", "impact" => "Must manage multiple dogs simultaneously" }
              ],
              "complexity_assessment" => "High — requires coordination, scheduling conflicts, and group payment splitting",
              "dependencies" => [ "Real-time availability matching", "Group payment processing" ]
            },
            "follow_up_questions" => [
              "What's the maximum group size?",
              "Can walkers opt out of group walks?"
            ],
            "ready_to_propose" => true
          }

          @llm_stub = stub("llm")
          @llm_stub.stubs(:chat_json).returns(@llm_response)
          Providers::Llm.stubs(:build).returns(@llm_stub)
        end

        teardown do
          ArnoldPipeline.reset_configuration!
        end

        test "tool_name returns what_if" do
          assert_equal "what_if", WhatIf.tool_name
        end

        test "description is present and non-empty" do
          assert_kind_of String, WhatIf.description
          refute_empty WhatIf.description
        end

        test "input_schema requires question" do
          schema = WhatIf.input_schema
          assert_equal "object", schema[:type]
          assert schema[:properties].key?(:question)
          assert_includes schema[:required], "question"
        end

        test "returns implications without modifying spec" do
          result = WhatIf.call({ "question" => "what if we added group walks?" }, @context)

          @spec.reload
          assert_equal @initial_spec_version, @spec.version
          assert_kind_of Hash, result[:implications]
        end

        test "no SpecRevision created" do
          WhatIf.call({ "question" => "what if we added group walks?" }, @context)

          assert_equal @initial_revision_count, SpecRevision.count
        end

        test "no change_id generated" do
          result = WhatIf.call({ "question" => "what if we added group walks?" }, @context)

          refute result.key?(:change_id)
        end

        test "affected domains identified" do
          result = WhatIf.call({ "question" => "what if we added group walks?" }, @context)

          affected = result[:implications][:affected_domains]
          assert_kind_of Array, affected
          assert affected.any? { |d| d[:domain] == "Booking" }
        end

        test "new domains suggested" do
          result = WhatIf.call({ "question" => "what if we added group walks?" }, @context)

          assert_includes result[:implications][:new_domains], "Group Coordination"
        end

        test "affected personas identified" do
          result = WhatIf.call({ "question" => "what if we added group walks?" }, @context)

          affected = result[:implications][:affected_personas]
          assert affected.any? { |p| p[:persona] == "Dog Owner" }
          assert affected.any? { |p| p[:persona] == "Dog Walker" }
        end

        test "new personas suggested" do
          result = WhatIf.call({ "question" => "what if we added group walks?" }, @context)

          assert_includes result[:implications][:new_personas], "Group Organizer"
        end

        test "complexity_assessment populated" do
          result = WhatIf.call({ "question" => "what if we added group walks?" }, @context)

          assert_kind_of String, result[:implications][:complexity_assessment]
          assert_includes result[:implications][:complexity_assessment], "High"
        end

        test "dependencies identified" do
          result = WhatIf.call({ "question" => "what if we added group walks?" }, @context)

          deps = result[:implications][:dependencies]
          assert_kind_of Array, deps
          assert deps.any? { |d| d.include?("payment") || d.include?("availability") }
        end

        test "follow_up_questions generated" do
          result = WhatIf.call({ "question" => "what if we added group walks?" }, @context)

          assert_kind_of Array, result[:follow_up_questions]
          assert result[:follow_up_questions].any?
        end

        test "ready_to_propose is true when specific" do
          result = WhatIf.call({ "question" => "what if we added group walks?" }, @context)

          assert_equal true, result[:ready_to_propose]
        end

        test "ready_to_propose is false when vague" do
          @llm_response["ready_to_propose"] = false
          @llm_stub.stubs(:chat_json).returns(@llm_response)

          result = WhatIf.call({ "question" => "what if we made it better?" }, @context)

          assert_equal false, result[:ready_to_propose]
        end

        test "empty question returns error" do
          result = WhatIf.call({ "question" => "" }, @context)
          assert_equal "question is required", result[:error]
        end

        test "nil question returns error" do
          result = WhatIf.call({}, @context)
          assert_equal "question is required", result[:error]
        end

        test "call returns error when no pipeline run found" do
          PipelineRun.destroy_all
          result = WhatIf.call({ "question" => "what if?" }, @context)
          assert_equal "No pipeline run found", result[:error]
        end

        test "call returns error when no specification found" do
          run_no_spec = PipelineRun.create!(nl_input: "no spec")
          result = WhatIf.call(
            { "question" => "what if?", "run_id" => run_no_spec.id.to_s },
            @context
          )
          assert_includes result[:error], "No specification found"
        end

        test "call falls back gracefully when LLM is unavailable" do
          Providers::Llm.stubs(:build).raises(StandardError.new("API unavailable"))

          result = WhatIf.call({ "question" => "what if we added group walks?" }, @context)

          assert_includes result[:interpretation], "group walks"
          assert_equal false, result[:ready_to_propose]
          assert_kind_of Array, result[:implications][:affected_domains]
        end

        test "response has all expected keys" do
          result = WhatIf.call({ "question" => "what if we added group walks?" }, @context)

          assert result.key?(:interpretation)
          assert result.key?(:implications)
          assert result.key?(:follow_up_questions)
          assert result.key?(:ready_to_propose)

          implications = result[:implications]
          assert implications.key?(:new_domains)
          assert implications.key?(:affected_domains)
          assert implications.key?(:new_personas)
          assert implications.key?(:affected_personas)
          assert implications.key?(:complexity_assessment)
          assert implications.key?(:dependencies)
        end
      end
    end
  end
end

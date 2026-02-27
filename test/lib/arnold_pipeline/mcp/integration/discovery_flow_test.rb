require "test_helper"
require "arnold_pipeline/mcp/handler"

module ArnoldPipeline
  module Mcp
    module Integration
      class DiscoveryFlowTest < ActiveSupport::TestCase
        cover "ArnoldPipeline::Mcp*"

        setup do
          @handler = Handler.new

          # Pre-built pipeline run for create_product (orchestrator is stubbed)
          @run = PipelineRun.create!(
            nl_input: "a dog walking app where walkers find clients nearby",
            status: :paused,
            metadata: {
              "library_selections" => {
                "persona" => "Software Architect",
                "recipe" => "Web App",
                "supporting_recipes" => ["API Service"],
                "domain_type" => "SERVICE"
              },
              "paused_at" => "spec"
            }
          )
          @spec = Specification.create!(
            pipeline_run: @run,
            content: "# Dog Walking App\n\n## Purpose\nConnect dog walkers with dog owners for on-demand walks.\n\n## Booking\n- Schedule walks\n- Cancel bookings\n\n## Messaging\n- In-app chat between walker and owner\n- Push notifications",
            version: 1,
            structured_data: {
              "product_name" => "Dog Walking App",
              "summary" => "A platform connecting dog walkers with dog owners",
              "personas" => [
                { "name" => "Dog Owner", "description" => "Books walks for their dogs", "capabilities" => ["book walks", "track walker"] },
                { "name" => "Dog Walker", "description" => "Accepts and fulfills walk requests", "capabilities" => ["accept jobs", "navigate routes"] }
              ],
              "domains" => [
                { "name" => "Booking", "description" => "Walk scheduling and management" },
                { "name" => "Messaging", "description" => "In-app communication between owners and walkers" },
                { "name" => "Payments", "description" => "Payment processing for completed walks" }
              ],
              "open_questions" => ["Should walkers set their own pricing?"]
            }
          )
          @rev1 = SpecRevision.create!(
            specification: @spec,
            version: 1,
            content: @spec.content,
            change_source: "spec_generation",
            created_at: 1.hour.ago
          )

          # Stub orchestrator for create_product
          orchestrator_stub = stub("orchestrator")
          orchestrator_stub.stubs(:call).returns(@run)
          ArnoldPipeline::Orchestrator.stubs(:new).returns(orchestrator_stub)

          # Stub LLM for explore_persona, explore_capability, what_if
          @persona_response = {
            "journey" => "Dog Owner creates account, books first walk, tracks walker, rates experience.",
            "capabilities" => [
              { "description" => "Book walks", "domain" => "Booking", "status" => "defined" },
              { "description" => "Track walker", "domain" => "Booking", "status" => "defined" }
            ],
            "pain_points" => ["Finding reliable walkers nearby"]
          }

          @capability_response = {
            "capability" => "Walk Booking",
            "domain" => "Booking",
            "description" => "Schedule on-demand or future walks with available walkers.",
            "user_flow" => "1. Open app\n2. Select walk type\n3. Choose time\n4. Confirm",
            "personas_involved" => ["Dog Owner", "Dog Walker"],
            "depends_on" => ["User Authentication"],
            "enables" => ["Walk Tracking", "Payments"],
            "open_questions" => ["Can owners book recurring walks?"]
          }

          @what_if_response = {
            "interpretation" => "Adding group walks where multiple owners join one session.",
            "implications" => {
              "new_domains" => ["Group Coordination"],
              "affected_domains" => [{ "domain" => "Booking", "impact" => "Multi-owner booking needed" }],
              "new_personas" => [],
              "affected_personas" => [{ "persona" => "Dog Walker", "impact" => "Must handle multiple dogs" }],
              "complexity_assessment" => "High",
              "dependencies" => ["Group payment splitting"]
            },
            "follow_up_questions" => ["What's the max group size?"],
            "ready_to_propose" => true
          }

          @propose_response = {
            "summary" => "Added GPS tracking for live walk monitoring",
            "deltas" => [{
              "operation" => "added",
              "section" => "Booking",
              "requirement" => "GPS Tracking",
              "content" => "### Requirement: GPS Tracking [REQ-BOOKING-003]",
              "before_content" => "",
              "after_content" => "",
              "rationale" => "Owners want to monitor walks"
            }]
          }

          @llm_stub = stub("llm")
          # Default to persona response — tests override as needed
          @llm_stub.stubs(:chat_json).returns(@persona_response)
          @llm_stub.stubs(:chat).returns(JSON.generate(@propose_response))
          ArnoldPipeline::Providers::Llm.stubs(:build).returns(@llm_stub)

          ArnoldPipeline.configuration.stubs(:openspec_enabled).returns(false)
        end

        teardown do
          ArnoldPipeline.reset_configuration!
          ArnoldPipeline::Mcp::Tools::ProposeChange.clear_proposals!
        end

        # --- Full discovery lifecycle ---

        test "full lifecycle: create -> describe -> explore persona -> explore domain -> explore capability -> what if -> get history" do
          # Step 1: create_product
          create_result = call_and_parse("create_product", {
            "description" => "a dog walking app where walkers find clients nearby"
          })
          assert_equal "Dog Walking App", create_result["product_name"]
          run_id = create_result["run_id"]

          # Step 2: describe_product
          describe_result = call_and_parse("describe_product", { "run_id" => run_id })
          assert_equal "Dog Walking App", describe_result["product_name"]
          assert_equal 2, describe_result["personas"].length

          # Step 3: explore_persona
          @llm_stub.stubs(:chat_json).returns(@persona_response)
          persona_result = call_and_parse("explore_persona", {
            "persona" => "Dog Owner",
            "run_id" => run_id
          })
          assert_equal "Dog Owner", persona_result["persona"]
          assert_kind_of String, persona_result["journey"]

          # Step 4: explore_domain
          domain_result = call_and_parse("explore_domain", {
            "domain" => "Booking",
            "run_id" => run_id
          })
          assert_equal "Booking", domain_result["domain"]

          # Step 5: explore_capability
          @llm_stub.stubs(:chat_json).returns(@capability_response)
          cap_result = call_and_parse("explore_capability", {
            "capability" => "walk booking",
            "run_id" => run_id
          })
          assert_equal "Walk Booking", cap_result["capability"]
          assert_includes cap_result["personas_involved"], "Dog Owner"

          # Step 6: what_if
          @llm_stub.stubs(:chat_json).returns(@what_if_response)
          whatif_result = call_and_parse("what_if", {
            "question" => "what if we added group walks?",
            "run_id" => run_id
          })
          assert_includes whatif_result["interpretation"], "group walks"
          assert_equal true, whatif_result["ready_to_propose"]

          # Step 7: get_history
          history_result = call_and_parse("get_history", { "run_id" => run_id })
          assert history_result["revisions"].any?
          assert_equal "spec_generation", history_result["revisions"].first["change_source"]
        end

        # --- Discovery -> propose -> confirm -> history ---

        test "discovery loop: create -> what_if -> propose -> confirm -> get_history shows change" do
          run_id = @run.id.to_s

          # what_if first to explore
          @llm_stub.stubs(:chat_json).returns(@what_if_response)
          whatif_result = call_and_parse("what_if", {
            "question" => "what if we added GPS tracking?",
            "run_id" => run_id
          })
          assert_equal true, whatif_result["ready_to_propose"]

          # Now propose the change
          @llm_stub.stubs(:chat_json).returns(@propose_response)
          propose_result = call_and_parse("propose_change", {
            "description" => "Add GPS tracking during walks",
            "run_id" => run_id
          })
          change_id = propose_result["change_id"]
          assert_not_nil change_id

          # Confirm the change
          confirm_result = call_and_parse("confirm_change", { "change_id" => change_id })
          assert_equal true, confirm_result["applied"]

          # History should now show 2 revisions
          history_result = call_and_parse("get_history", { "run_id" => run_id })
          assert history_result["revisions"].length >= 2
          sources = history_result["revisions"].map { |r| r["change_source"] }
          assert_includes sources, "spec_generation"
          assert_includes sources, "mcp_confirm"
        end

        # --- create_product returns usable data ---

        test "create_product response feeds into describe_product" do
          create_result = call_and_parse("create_product", {
            "description" => "a dog walking app where walkers find clients nearby"
          })

          describe_result = call_and_parse("describe_product", {
            "run_id" => create_result["run_id"]
          })

          assert_equal create_result["product_name"], describe_result["product_name"]
        end

        # --- what_if is read-only ---

        test "what_if does not modify spec or create revisions" do
          initial_version = @spec.version
          initial_revisions = SpecRevision.count

          @llm_stub.stubs(:chat_json).returns(@what_if_response)
          call_and_parse("what_if", {
            "question" => "what if we added group walks?",
            "run_id" => @run.id.to_s
          })

          @spec.reload
          assert_equal initial_version, @spec.version
          assert_equal initial_revisions, SpecRevision.count
        end

        # --- explore_persona finds personas from create_product output ---

        test "personas from create_product are explorable" do
          create_result = call_and_parse("create_product", {
            "description" => "a dog walking app where walkers find clients nearby"
          })

          @llm_stub.stubs(:chat_json).returns(@persona_response)

          create_result["personas"].each do |persona|
            result = call_and_parse("explore_persona", {
              "persona" => persona["name"],
              "run_id" => create_result["run_id"]
            })
            refute result.key?("error"), "Should find persona '#{persona['name']}'"
            assert_equal persona["name"], result["persona"]
          end
        end

        # --- get_history domain filter ---

        test "get_history with domain filter returns relevant revisions" do
          result = call_and_parse("get_history", {
            "run_id" => @run.id.to_s,
            "domain" => "Booking"
          })

          result["revisions"].each do |rev|
            assert rev["domains_affected"].any? { |d| d.downcase.include?("booking") },
              "Filtered revisions should affect Booking domain"
          end
        end

        private

        def call_and_parse(tool_name, arguments = {})
          result = @handler.call_tool(tool_name, arguments)
          assert result[:content], "Tool #{tool_name} should return content"
          assert_equal "text", result[:content].first[:type]
          JSON.parse(result[:content].first[:text])
        end
      end
    end
  end
end

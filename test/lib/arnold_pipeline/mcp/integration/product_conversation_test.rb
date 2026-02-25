require "test_helper"
require "arnold_pipeline/mcp/handler"

module ArnoldPipeline
  module Mcp
    module Integration
      class ProductConversationTest < ActiveSupport::TestCase
        cover "ArnoldPipeline::Mcp*"

        setup do
          @handler = Handler.new
          @run = PipelineRun.create!(nl_input: "Build a dog walking app with booking and messaging")
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
              "tech_stack" => { "backend" => "Rails 8+", "frontend" => "Hotwire", "database" => "SQLite" }
            }
          )

          # Tasks across tiers
          @task_db = @run.tasks.create!(
            title: "Setup database schema",
            description: "Create core database tables and schema",
            tier: 0, position: 0, status: :pending,
            labels: ["backend", "database"]
          )
          @task_booking = @run.tasks.create!(
            title: "Implement booking API",
            description: "Build booking endpoints for scheduling walks",
            tier: 1, position: 1, status: :pending,
            labels: ["backend", "booking"],
            depends_on: [@task_db.id]
          )
          @task_messaging = @run.tasks.create!(
            title: "Build messaging system",
            description: "Implement in-app chat between users",
            tier: 1, position: 2, status: :pending,
            labels: ["backend", "messaging"],
            depends_on: [@task_db.id]
          )
          @task_payments = @run.tasks.create!(
            title: "Integrate payment processing",
            description: "Handle payments for completed walks",
            tier: 2, position: 3, status: :pending,
            labels: ["backend", "payments"],
            depends_on: [@task_booking.id]
          )

          # Stub LLM for propose_change
          @llm_response = {
            "summary" => "Added GPS tracking for live walk monitoring",
            "deltas" => [
              {
                "operation" => "added",
                "section" => "Booking",
                "requirement" => "GPS Tracking",
                "content" => "### Requirement: GPS Tracking [REQ-BOOKING-003]\nReal-time GPS tracking of active walks.",
                "before_content" => "",
                "after_content" => "",
                "rationale" => "Dog owners want to monitor their dog's walk in real time"
              }
            ]
          }

          @llm_stub = stub("llm")
          @llm_stub.stubs(:chat_json).returns(@llm_response)
          @llm_stub.stubs(:chat).returns(JSON.generate(@llm_response))
          ArnoldPipeline::Providers::Llm.stubs(:build).returns(@llm_stub)

          # Disable OpenSpec to avoid external CLI
          ArnoldPipeline.configuration.stubs(:openspec_enabled).returns(false)
        end

        teardown do
          ArnoldPipeline.reset_configuration!
          ArnoldPipeline::Mcp::Tools::ProposeChange.clear_proposals!
        end

        # --- Full conversation flow ---

        test "full product conversation: describe -> explore -> propose -> confirm" do
          # Step 1: describe_product — get the product overview
          describe_result = call_and_parse("describe_product", { "run_id" => @run.id.to_s })

          assert_equal "Dog Walking App", describe_result["product_name"]
          assert_equal 2, describe_result["personas"].length
          assert_equal 3, describe_result["domains"].length

          # Step 2: explore_domain — drill into a domain from the description
          booking_domain = describe_result["domains"].find { |d| d["name"] == "Booking" }
          assert_not_nil booking_domain, "Booking domain should be in describe_product output"

          explore_result = call_and_parse("explore_domain", {
            "domain" => "Booking",
            "run_id" => @run.id.to_s
          })

          assert_equal "Booking", explore_result["domain"]
          assert_kind_of Array, explore_result["capabilities"]

          # Step 3: propose_change — propose adding GPS tracking
          propose_result = call_and_parse("propose_change", {
            "description" => "Add real-time GPS tracking during walks",
            "run_id" => @run.id.to_s
          })

          assert propose_result["change_id"], "propose_change must return a change_id"
          assert_equal "Added GPS tracking for live walk monitoring", propose_result["summary"]
          assert_kind_of Array, propose_result["impact"]["domains_affected"]

          # Step 4: confirm_change — apply the change
          change_id = propose_result["change_id"]
          confirm_result = call_and_parse("confirm_change", { "change_id" => change_id })

          assert_equal true, confirm_result["applied"]
          assert confirm_result["revision"].to_i > 1, "Spec revision should increment"
        end

        # --- Spec is only modified after confirm, not propose ---

        test "spec is modified only after confirm, not after propose" do
          original_version = @spec.version
          original_content = @spec.content.dup

          # Propose should NOT modify the spec
          propose_result = call_and_parse("propose_change", {
            "description" => "Add GPS tracking",
            "run_id" => @run.id.to_s
          })

          @spec.reload
          assert_equal original_version, @spec.version, "Spec version should not change after propose"
          assert_equal original_content, @spec.content, "Spec content should not change after propose"

          # Confirm SHOULD modify the spec and create SpecRevision
          change_id = propose_result["change_id"]
          call_and_parse("confirm_change", { "change_id" => change_id })

          @spec.reload
          assert @spec.version > original_version, "Spec version should increase after confirm"
          refute_equal original_content, @spec.content, "Spec content should change after confirm"

          # SpecRevision with mcp_confirm change_source should exist
          mcp_revisions = @spec.spec_revisions.where(change_source: "mcp_confirm")
          assert mcp_revisions.any?, "Should have a SpecRevision with mcp_confirm change_source"
        end

        # --- Downstream task invalidation after confirm ---

        test "downstream tasks matching changed domain are invalidated after confirm" do
          # booking task is pending with label matching the "Booking" section in deltas
          assert_equal "pending", @task_booking.status

          propose_result = call_and_parse("propose_change", {
            "description" => "Add GPS tracking to bookings",
            "run_id" => @run.id.to_s
          })

          # After propose, task should still be pending
          @task_booking.reload
          assert_equal "pending", @task_booking.status

          # After confirm, matching tasks become superseded
          change_id = propose_result["change_id"]
          confirm_result = call_and_parse("confirm_change", { "change_id" => change_id })

          @task_booking.reload
          assert_equal "superseded", @task_booking.status, "Booking task should be superseded (label matches changed section)"

          assert confirm_result["tasks_invalidated"] >= 1, "At least one task should be invalidated"
        end

        test "tasks in unrelated domains are not invalidated after confirm" do
          propose_result = call_and_parse("propose_change", {
            "description" => "Add GPS tracking to bookings",
            "run_id" => @run.id.to_s
          })

          change_id = propose_result["change_id"]
          call_and_parse("confirm_change", { "change_id" => change_id })

          # Messaging and database tasks should remain unaffected
          @task_messaging.reload
          @task_db.reload
          assert_equal "pending", @task_messaging.status, "Messaging task should remain pending"
          assert_equal "pending", @task_db.status, "Database task should remain pending"
        end

        test "completed tasks are not invalidated by confirm" do
          @task_booking.update!(status: :completed)

          propose_result = call_and_parse("propose_change", {
            "description" => "Add GPS tracking to bookings",
            "run_id" => @run.id.to_s
          })

          change_id = propose_result["change_id"]
          confirm_result = call_and_parse("confirm_change", { "change_id" => change_id })

          @task_booking.reload
          assert_equal "completed", @task_booking.status, "Completed tasks should not be invalidated"
          assert_equal 0, confirm_result["tasks_invalidated"]
        end

        # --- Domain information is consistent across tools ---

        test "describe_product domains match explore_domain results" do
          describe_result = call_and_parse("describe_product", { "run_id" => @run.id.to_s })
          domain_names = describe_result["domains"].map { |d| d["name"] }

          # Each domain from describe_product should be explorable
          domain_names.each do |domain_name|
            explore_result = call_and_parse("explore_domain", {
              "domain" => domain_name,
              "run_id" => @run.id.to_s
            })

            refute explore_result.key?("error"), "explore_domain should succeed for '#{domain_name}'"
            assert_equal domain_name, explore_result["domain"]
          end
        end

        test "explore_domain returns capabilities derived from tasks" do
          # The booking task should appear as a capability in the Booking domain
          explore_result = call_and_parse("explore_domain", {
            "domain" => "Booking",
            "run_id" => @run.id.to_s
          })

          capabilities = explore_result["capabilities"]
          assert capabilities.any?, "Booking domain should have capabilities from tasks"

          task_titles = capabilities.map { |c| c["description"] }
          assert task_titles.any? { |t| t.include?("booking") || t.include?("Booking") },
            "Capabilities should include the booking task"
        end

        test "propose_change returns affected domains matching explore_domain domains" do
          propose_result = call_and_parse("propose_change", {
            "description" => "Add GPS tracking to booking",
            "run_id" => @run.id.to_s
          })

          affected_domains = propose_result["impact"]["domains_affected"]
          assert affected_domains.any?, "Should have affected domains"

          # The affected domain should match what explore_domain returns
          affected_names = affected_domains.map { |d| d["domain"] }
          affected_names.each do |name|
            explore_result = call_and_parse("explore_domain", {
              "domain" => name,
              "run_id" => @run.id.to_s
            })
            # Either finds the domain or returns a close match
            refute explore_result.key?("error"),
              "Affected domain '#{name}' should be explorable"
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

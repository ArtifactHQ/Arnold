require "test_helper"
require "arnold_pipeline/mcp/handler"

module ArnoldPipeline
  module E2e
    class McpLifecycleTest < ActiveSupport::TestCase
      setup do
        @handler = Mcp::Handler.new

        @run = PipelineRun.create!(nl_input: "Build a dog walking app")
        @spec = Specification.create!(
          pipeline_run: @run,
          content: "# Dog Walking App\n\n## Purpose\nConnect dog walkers with dog owners for on-demand walks.\n\n## Requirements\n### Booking\n- Users can book walks\n- Walkers can accept or decline\n### Payments\n- Process payments via Stripe\n- Track payment history\n### Profiles\n- Manage user profiles\n- Upload profile photos",
          structured_data: {
            "product_name" => "Dog Walking App",
            "personas" => [
              { "name" => "Dog Walker", "description" => "Walks dogs", "capabilities" => ["Accept bookings", "View schedule"] },
              { "name" => "Dog Owner", "description" => "Owns dogs", "capabilities" => ["Book walks", "Track walker"] }
            ],
            "domains" => [
              { "name" => "Booking", "description" => "Walk booking system" },
              { "name" => "Payments", "description" => "Payment processing" }
            ],
            "tech_stack" => { "backend" => "Rails 8", "database" => "SQLite" }
          },
          version: 1
        )
        @revision = SpecRevision.create!(
          specification: @spec,
          version: 1,
          content: @spec.content,
          structured_data: @spec.structured_data,
          change_source: "spec_generation"
        )

        @tier0_task1 = @run.tasks.create!(
          title: "Setup database schema",
          description: "Create users, walks, and bookings tables",
          tier: 0, position: 0, status: :pending,
          labels: ["backend", "database"],
          acceptance_criteria: [{ "description" => "Tables created" }]
        )
        @tier0_task2 = @run.tasks.create!(
          title: "Setup authentication",
          description: "Add Devise authentication for users",
          tier: 0, position: 1, status: :pending,
          labels: ["backend", "auth"],
          acceptance_criteria: [{ "description" => "Auth works" }]
        )
        @tier1_task = @run.tasks.create!(
          title: "Build booking API",
          description: "Create booking endpoints for walk scheduling",
          tier: 1, position: 2, status: :pending,
          labels: ["backend", "api", "booking"],
          depends_on: [@tier0_task1.id, @tier0_task2.id]
        )
      end

      teardown do
        ArnoldPipeline.reset_configuration!
        Mcp::Tools::ProposeChange.clear_proposals!
      end

      test "full pipeline lifecycle via MCP tools" do
        # Step 1: describe_product
        result = call_tool("describe_product", { "run_id" => @run.id.to_s })
        assert_equal "Dog Walking App", result["product_name"]
        assert result["personas"].length >= 2
        assert result["domains"].length >= 1

        # Step 2: get_spec (full)
        result = call_tool("get_spec", { "run_id" => @run.id.to_s, "format" => "full" })
        assert_includes result["spec"], "Dog Walking App"
        assert_equal 3, result["metadata"]["total_tasks"]
        assert_equal 0, result["metadata"]["completed_tasks"]

        # Step 3: get_tasks (tier 0)
        result = call_tool("get_tasks", { "run_id" => @run.id.to_s, "tier" => 0 })
        assert_equal 2, result["tasks"].length
        task_titles = result["tasks"].map { |t| t["title"] }
        assert_includes task_titles, "Setup database schema"
        assert_includes task_titles, "Setup authentication"

        # Step 4: start_task
        result = call_tool("start_task", { "task_id" => @tier0_task1.id.to_s })
        assert_equal "in_progress", result["status"]
        assert @tier0_task1.reload.in_progress?

        # Step 5: complete_task
        result = call_tool("complete_task", {
          "task_id" => @tier0_task1.id.to_s,
          "summary" => "Created users and walks tables",
          "files_changed" => ["db/migrate/001_create_users.rb", "db/migrate/002_create_walks.rb"]
        })
        assert_equal "completed", result["status"]
        assert_equal 0, result["tier_progress"]["tier"]
        assert_equal false, result["tier_progress"]["ready_for_validation"]

        # Step 6: complete second tier 0 task
        call_tool("start_task", { "task_id" => @tier0_task2.id.to_s })
        result = call_tool("complete_task", {
          "task_id" => @tier0_task2.id.to_s,
          "summary" => "Added Devise authentication",
          "files_changed" => ["app/models/user.rb", "config/initializers/devise.rb"]
        })
        assert_equal true, result["tier_progress"]["ready_for_validation"]

        # Step 7: validate_tier
        result = call_tool("validate_tier", { "run_id" => @run.id.to_s, "tier" => 0, "include_drift_check" => false })
        assert_includes %w[pass conditional], result["verdict"]
        assert_equal 0, result["tier"]
        assert result["checks"].any? { |c| c["check"] == "task_completion" && c["result"] == "pass" }

        # Verify next tier info is present
        if result["next_tier"]
          assert_equal 1, result["next_tier"]["tier"]
        end

        # Step 8: get_tasks (tier 1) — verify next tier is available
        result = call_tool("get_tasks", { "run_id" => @run.id.to_s, "tier" => 1 })
        assert_equal 1, result["tasks"].length
        assert_equal "Build booking API", result["tasks"].first["title"]
      end

      test "propose and confirm change modifies spec and invalidates tasks" do
        # Stub LLM for propose_change (SpecIterator)
        llm_response = {
          "summary" => "Added ratings feature to Booking domain",
          "deltas" => [
            {
              "operation" => "added",
              "section" => "Booking",
              "requirement" => "Walk Ratings",
              "content" => "### Requirement: Walk Ratings [REQ-BOOK-003]\nOwners can rate walkers after each walk.",
              "before_content" => "",
              "after_content" => "### Requirement: Walk Ratings [REQ-BOOK-003]\nOwners can rate walkers after each walk.",
              "rationale" => "User requested rating system"
            }
          ]
        }
        llm_stub = stub("llm")
        ArnoldPipeline::Providers::Llm.stubs(:build).returns(llm_stub)
        llm_stub.stubs(:chat_json).returns(llm_response)
        llm_stub.stubs(:chat).returns(JSON.generate(llm_response))

        # Disable openspec to use simple append merge
        ArnoldPipeline.configure { |c| c.openspec_enabled = false }

        # 1. propose_change
        result = call_tool("propose_change", {
          "description" => "Add a ratings system so owners can rate walkers"
        })
        assert result.key?("change_id"), "propose_change should return a change_id"
        change_id = result["change_id"]
        assert_equal "Added ratings feature to Booking domain", result["summary"]

        # Spec should NOT be modified yet
        original_version = @spec.reload.version
        assert_equal 1, original_version

        # 2. confirm_change
        result = call_tool("confirm_change", { "change_id" => change_id })
        assert_equal true, result["applied"]

        # Spec should be updated
        new_version = @spec.reload.version
        assert new_version > original_version, "Spec version should have incremented"

        # A new revision should exist
        assert @spec.spec_revisions.count >= 2
      end

      test "task start provides context from dependencies" do
        # Complete first task to provide prior context
        @tier0_task1.update!(
          status: :completed,
          result_comments: [{ "body" => "Created users table with email and password_digest columns" }]
        )
        @tier0_task2.update!(
          status: :completed,
          result_comments: [{ "body" => "Added Devise auth with JWT tokens" }]
        )

        # Start tier 1 task that depends on tier 0 tasks
        result = call_tool("start_task", { "task_id" => @tier1_task.id.to_s })
        assert_equal "in_progress", result["status"]

        # Should have no warnings since dependencies are completed
        assert_empty result["warnings"]

        # Context should include prior context from dependencies
        assert result.key?("context")
      end

      test "task start warns about incomplete dependencies" do
        # Start tier 1 task while tier 0 tasks are still pending
        result = call_tool("start_task", { "task_id" => @tier1_task.id.to_s })
        assert_equal "in_progress", result["status"]

        # Should have warnings about pending dependencies
        assert result["warnings"].length > 0
        assert result["warnings"].any? { |w| w.include?("not yet completed") }
      end

      test "validate_tier fails when tasks incomplete" do
        # Try to validate tier 0 with all tasks still pending
        result = call_tool("validate_tier", { "run_id" => @run.id.to_s, "tier" => 0 })
        assert_equal "fail", result["verdict"]
        assert result["issues"].any? { |i| i["severity"] == "blocking" }
      end

      test "report_issue records issue and returns resolution guidance" do
        # Start a task first
        call_tool("start_task", { "task_id" => @tier0_task1.id.to_s })

        # Report a spec-related issue
        result = call_tool("report_issue", {
          "task_id" => @tier0_task1.id.to_s,
          "issue" => "The spec is unclear about which database columns the users table needs"
        })

        assert_equal @tier0_task1.id.to_s, result["task_id"]
        assert_equal "spec_change", result["resolution"]
        assert result["actions_taken"].any?

        # Issue should be recorded in task comments
        @tier0_task1.reload
        assert @tier0_task1.result_comments.any? { |c| c["body"].include?("spec is unclear") }

        # Task should still be startable/completable
        result = call_tool("complete_task", {
          "task_id" => @tier0_task1.id.to_s,
          "summary" => "Completed with workaround",
          "files_changed" => ["db/migrate/001_create_users.rb"]
        })
        assert_equal "completed", result["status"]
      end

      test "detect drift finds issues with empty task results" do
        # Create completed tasks, one with diffs and one without
        @tier0_task1.update!(status: :completed, result_diff: "+class User\n+end")
        @tier0_task2.update!(status: :completed, result_diff: nil)

        # Stub LLM for drift detection
        Mcp::Tools::DetectDrift.stubs(:build_llm).returns(stub("llm"))

        result = call_tool("detect_drift", {
          "run_id" => @run.id.to_s,
          "depth" => "structural"
        })

        assert_equal @run.id.to_s, result["run_id"]
        assert_includes %w[clean drift_detected], result["status"]
        assert result.key?("findings")
        assert result.key?("coverage")
        assert result.key?("summary")
      end

      test "resolve drift with accept excludes finding from future checks" do
        # Create a drift finding manually
        finding = DriftFinding.create!(
          pipeline_run: @run,
          spec_revision: @revision,
          drift_type: "structural",
          severity: "warning",
          description: "Empty diff on authentication task",
          recommendation: "review_needed"
        )

        # Resolve with accept
        result = call_tool("resolve_drift", {
          "finding_id" => finding.id.to_s,
          "resolution" => "accept",
          "notes" => "Intentional - auth was handled by generator"
        })

        assert_equal "accepted", result["resolution_applied"]
        assert_equal "resolved", result["status"]

        # Finding should be resolved
        finding.reload
        assert finding.resolved?
        assert_equal "accepted", finding.resolution
      end

      test "resolve drift with update_code creates corrective task" do
        finding = DriftFinding.create!(
          pipeline_run: @run,
          spec_revision: @revision,
          drift_type: "behavioral",
          severity: "critical",
          description: "Payment processing not implemented",
          spec_expectation: "Process payments via Stripe",
          actual_state: "No payment code found"
        )

        result = call_tool("resolve_drift", {
          "finding_id" => finding.id.to_s,
          "resolution" => "update_code"
        })

        assert_equal "update_code", result["resolution_applied"]
        assert_equal "pending_execution", result["status"]
        assert result["tasks_generated"].length > 0

        new_task = @run.tasks.find(result["tasks_generated"].first["task_id"])
        assert_includes new_task.title, "Payment processing"
        assert new_task.pending?
      end

      test "get_spec summary format truncates long specs" do
        long_content = (1..100).map { |i| "## Section #{i}\nContent for section #{i}" }.join("\n\n")
        @spec.update!(content: long_content)

        result = call_tool("get_spec", { "run_id" => @run.id.to_s, "format" => "summary" })
        assert_includes result["spec"], "truncated"
        assert_equal "summary", result["format"]
      end

      test "get_tasks filters by status" do
        @tier0_task1.update!(status: :completed)

        result = call_tool("get_tasks", { "run_id" => @run.id.to_s, "status" => "pending" })
        tasks = result["tasks"]

        # Should not include the completed task
        assert tasks.none? { |t| t["task_id"] == @tier0_task1.id.to_s }
        # Should include remaining pending tasks
        assert tasks.any? { |t| t["task_id"] == @tier0_task2.id.to_s }
      end

      test "complete_task is idempotent for status transitions" do
        # Start the task
        call_tool("start_task", { "task_id" => @tier0_task1.id.to_s })

        # Complete it
        result = call_tool("complete_task", {
          "task_id" => @tier0_task1.id.to_s,
          "summary" => "Done",
          "files_changed" => ["file.rb"]
        })
        assert_equal "completed", result["status"]

        # Trying to complete again should error since status is now completed
        result_raw = @handler.call_tool("complete_task", {
          "task_id" => @tier0_task1.id.to_s,
          "summary" => "Done again",
          "files_changed" => ["file.rb"]
        })
        parsed = JSON.parse(result_raw[:content].first[:text])
        assert parsed.key?("error")
        assert_includes parsed["error"], "cannot be completed"
      end

      test "validate_tier includes drift info when requested" do
        # Complete all tier 0 tasks
        @tier0_task1.update!(status: :completed, result_comments: [{ "body" => "done" }])
        @tier0_task2.update!(status: :completed, result_comments: [{ "body" => "done" }])

        result = call_tool("validate_tier", {
          "run_id" => @run.id.to_s,
          "tier" => 0,
          "include_drift_check" => true
        })

        assert result.key?("drift")
        assert_equal "clean", result["drift"]["status"]
      end

      test "validate_tier returns error for tier with no tasks" do
        result_raw = @handler.call_tool("validate_tier", {
          "run_id" => @run.id.to_s,
          "tier" => 99
        })
        parsed = JSON.parse(result_raw[:content].first[:text])
        assert_equal "No tasks found for tier 99", parsed["error"]
      end

      private

      def call_tool(name, arguments)
        result = @handler.call_tool(name, arguments)
        if result[:error]
          flunk "Tool #{name} returned error: #{result[:error][:message]}"
        end
        JSON.parse(result[:content].first[:text])
      end
    end
  end
end

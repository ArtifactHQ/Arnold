require "test_helper"
require "arnold_pipeline/mcp/handler"

module ArnoldPipeline
  module Mcp
    module Integration
      class IssueResolutionTest < ActiveSupport::TestCase
        cover "ArnoldPipeline::Mcp*"

        setup do
          @handler = Handler.new
          @run = PipelineRun.create!(nl_input: "Build an e-commerce platform")
          @spec = Specification.create!(
            pipeline_run: @run,
            content: "# E-Commerce Platform\n\n## Purpose\nAn online marketplace for buying and selling products.\n\n## Authentication\n- User login and registration\n- OAuth integration\n\n## Products\n- Product catalog\n- Search and filtering\n\n## Orders\n- Shopping cart\n- Checkout flow",
            version: 1,
            structured_data: {
              "product_name" => "E-Commerce Platform",
              "domains" => [
                { "name" => "Authentication", "description" => "User auth" },
                { "name" => "Products", "description" => "Product catalog" },
                { "name" => "Orders", "description" => "Order management" }
              ]
            }
          )

          # Tier 0 - foundation tasks
          @task_db = @run.tasks.create!(
            title: "Setup database schema",
            description: "Create core tables",
            tier: 0, position: 0, status: :completed,
            labels: ["backend", "database"],
            depends_on: [],
            result_comments: [{ "body" => "Schema created" }]
          )
          @task_models = @run.tasks.create!(
            title: "Create models",
            description: "Define ActiveRecord models",
            tier: 0, position: 1, status: :completed,
            labels: ["backend", "models"],
            depends_on: [],
            result_comments: [{ "body" => "Models created" }]
          )

          # Tier 1 - feature tasks
          @task_auth = @run.tasks.create!(
            title: "Implement authentication",
            description: "Build user login, registration, and OAuth",
            tier: 1, position: 2, status: :in_progress,
            labels: ["backend", "authentication"],
            depends_on: [@task_db.id, @task_models.id]
          )
          @task_products = @run.tasks.create!(
            title: "Build product catalog",
            description: "CRUD for products with search",
            tier: 1, position: 3, status: :pending,
            labels: ["backend", "products"],
            depends_on: [@task_models.id]
          )

          # Tier 2 - depends on tier 1
          @task_orders = @run.tasks.create!(
            title: "Implement order processing",
            description: "Shopping cart and checkout",
            tier: 2, position: 4, status: :pending,
            labels: ["backend", "orders"],
            depends_on: [@task_auth.id, @task_products.id]
          )
        end

        teardown do
          ArnoldPipeline.reset_configuration!
        end

        # --- Spec issue resolution ---

        test "report spec issue returns spec_change resolution with detail" do
          # Start the auth task and report a spec ambiguity
          start_result = call_and_parse("start_task", { "task_id" => @task_auth.id.to_s })
          assert_equal "in_progress", start_result["status"]

          issue_result = call_and_parse("report_issue", {
            "task_id" => @task_auth.id.to_s,
            "issue" => "The spec is unclear about which OAuth providers to support"
          })

          assert_equal @task_auth.id.to_s, issue_result["task_id"]
          assert_equal "spec_change", issue_result["resolution"]
          assert_kind_of String, issue_result["detail"]
          assert_includes issue_result["detail"], "spec"
          assert_kind_of Array, issue_result["actions_taken"]
          assert issue_result["actions_taken"].any? { |a| a.include?("spec") },
            "Actions should reference spec review"
        end

        test "spec issue detail references relevant spec sections" do
          issue_result = call_and_parse("report_issue", {
            "task_id" => @task_auth.id.to_s,
            "issue" => "Missing requirement for password reset in the spec"
          })

          assert_equal "spec_change", issue_result["resolution"]
          # Detail should mention relevant sections because task has "authentication" label
          assert_kind_of String, issue_result["detail"]
        end

        test "spec issue records issue in task result_comments" do
          call_and_parse("report_issue", {
            "task_id" => @task_auth.id.to_s,
            "issue" => "The spec is ambiguous about user roles"
          })

          @task_auth.reload
          comments = @task_auth.result_comments
          assert comments.any? { |c| c["body"].include?("spec_change") },
            "Issue should be recorded in result_comments"
          assert comments.any? { |c| c["body"].include?("ambiguous about user roles") },
            "Issue text should be in the comment"
        end

        # --- Dependency issue resolution ---

        test "report dependency issue identifies blocking task" do
          # Start order processing task (has incomplete dependencies)
          @task_orders.update!(status: :in_progress)

          issue_result = call_and_parse("report_issue", {
            "task_id" => @task_orders.id.to_s,
            "issue" => "Blocked by incomplete dependency — auth module not ready"
          })

          assert_equal "dependency_fix", issue_result["resolution"]
          assert_includes issue_result["detail"], "Incomplete dependencies"
          # Should mention the blocking tasks
          assert(
            issue_result["detail"].include?("authentication") ||
            issue_result["detail"].include?("product catalog"),
            "Detail should mention the blocking task(s)"
          )
        end

        test "dependency issue with all deps complete provides different detail" do
          # Complete all dependencies first
          @task_auth.update!(status: :completed)
          @task_products.update!(status: :completed)
          @task_orders.update!(status: :in_progress)

          issue_result = call_and_parse("report_issue", {
            "task_id" => @task_orders.id.to_s,
            "issue" => "Blocked — waiting on upstream data format"
          })

          assert_equal "dependency_fix", issue_result["resolution"]
          assert_includes issue_result["detail"], "All dependency tasks are completed"
        end

        test "dependency issue on task with no deps suggests missing dependency" do
          # task_db has no depends_on
          @task_db.update!(status: :in_progress)

          issue_result = call_and_parse("report_issue", {
            "task_id" => @task_db.id.to_s,
            "issue" => "This task needs a prerequisite that isn't declared"
          })

          assert_equal "dependency_fix", issue_result["resolution"]
          assert_includes issue_result["detail"], "no declared dependencies"
        end

        # --- Task restructure resolution ---

        test "report task issue with suggestion restructures task" do
          issue_result = call_and_parse("report_issue", {
            "task_id" => @task_auth.id.to_s,
            "issue" => "The task description is wrong — should focus on session management",
            "suggestion" => "Implement session-based authentication with secure cookies and CSRF protection"
          })

          assert_equal "task_restructure", issue_result["resolution"]
          assert_not_nil issue_result["revised_task"]

          revised = issue_result["revised_task"]
          assert_equal @task_auth.id.to_s, revised["task_id"]
          assert_equal "Implement authentication", revised["title"]
          assert_includes revised["description"], "session-based authentication"
          assert_kind_of String, revised["previous_description"]

          # Verify the DB was actually updated
          @task_auth.reload
          assert_includes @task_auth.description, "session-based authentication"
        end

        test "report task issue without suggestion asks for one" do
          issue_result = call_and_parse("report_issue", {
            "task_id" => @task_auth.id.to_s,
            "issue" => "The task description should be rewritten"
          })

          assert_equal "task_restructure", issue_result["resolution"]
          assert_nil issue_result["revised_task"]
          assert_includes issue_result["detail"], "provide a suggestion"
        end

        # --- Guidance resolution (fallback) ---

        test "generic issue returns guidance resolution" do
          issue_result = call_and_parse("report_issue", {
            "task_id" => @task_auth.id.to_s,
            "issue" => "I'm having trouble figuring out how to approach this"
          })

          assert_equal "guidance", issue_result["resolution"]
          assert_kind_of String, issue_result["detail"]
          assert_kind_of Array, issue_result["actions_taken"]
        end

        # --- Issue then resume workflow ---

        test "task remains in_progress after reporting an issue" do
          call_and_parse("start_task", { "task_id" => @task_products.id.to_s })

          call_and_parse("report_issue", {
            "task_id" => @task_products.id.to_s,
            "issue" => "The spec is unclear about search filtering requirements"
          })

          @task_products.reload
          assert_equal "in_progress", @task_products.status,
            "Task should remain in_progress after reporting an issue"

          # Can still complete the task after resolving the issue
          complete_result = call_and_parse("complete_task", {
            "task_id" => @task_products.id.to_s,
            "summary" => "Implemented product catalog with basic search",
            "files_changed" => ["app/controllers/products_controller.rb"]
          })

          assert_equal "completed", complete_result["status"]
        end

        test "multiple issues can be reported on the same task" do
          call_and_parse("report_issue", {
            "task_id" => @task_auth.id.to_s,
            "issue" => "Missing requirement for password validation rules in the spec"
          })
          call_and_parse("report_issue", {
            "task_id" => @task_auth.id.to_s,
            "issue" => "The task description should be updated to include 2FA",
            "suggestion" => "Implement auth with login, signup, and optional 2FA"
          })

          @task_auth.reload
          comments = @task_auth.result_comments
          assert comments.length >= 2, "Should have at least 2 issue comments recorded"
          assert comments.any? { |c| c["body"].include?("spec_change") }
          assert comments.any? { |c| c["body"].include?("task_restructure") }
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

require "test_helper"
require "arnold_pipeline/mcp/handler"

module ArnoldPipeline
  module Mcp
    module Integration
      class ExecutionFlowTest < ActiveSupport::TestCase
        cover "ArnoldPipeline::Mcp*"

        setup do
          @handler = Handler.new
          @run = PipelineRun.create!(nl_input: "Build a task management app")
          @spec = Specification.create!(
            pipeline_run: @run,
            content: "# Task Manager\n\n## Purpose\nA simple task management application.\n\n## Requirements\n- Create and manage tasks\n- User authentication\n- Task categories",
            version: 1,
            structured_data: {
              "product_name" => "Task Manager",
              "domains" => [
                { "name" => "Tasks", "description" => "Task CRUD operations" },
                { "name" => "Auth", "description" => "User authentication" }
              ],
              "tech_stack" => { "backend" => "Rails 8+", "database" => "SQLite" }
            }
          )

          # Tier 0 tasks
          @t0_setup_db = @run.tasks.create!(
            title: "Setup database schema",
            description: "Create tables for users, tasks, categories",
            tier: 0, position: 0, status: :pending,
            labels: ["backend", "database"],
            depends_on: []
          )
          @t0_models = @run.tasks.create!(
            title: "Create ActiveRecord models",
            description: "Define User, Task, and Category models",
            tier: 0, position: 1, status: :pending,
            labels: ["backend", "models"],
            depends_on: []
          )

          # Tier 1 tasks (depend on tier 0)
          @t1_api = @run.tasks.create!(
            title: "Build task API endpoints",
            description: "REST API for task CRUD",
            tier: 1, position: 2, status: :pending,
            labels: ["backend", "api"],
            depends_on: [@t0_setup_db.id, @t0_models.id]
          )
          @t1_auth = @run.tasks.create!(
            title: "Implement authentication",
            description: "Login and signup flows",
            tier: 1, position: 3, status: :pending,
            labels: ["backend", "auth"],
            depends_on: [@t0_models.id]
          )

          # Tier 2 task (depends on tier 1)
          @t2_ui = @run.tasks.create!(
            title: "Build task management UI",
            description: "Frontend views for task management",
            tier: 2, position: 4, status: :pending,
            labels: ["frontend", "tasks"],
            depends_on: [@t1_api.id, @t1_auth.id]
          )
        end

        teardown do
          ArnoldPipeline.reset_configuration!
        end

        # --- Full execution flow across a tier ---

        test "full execution flow: get_spec -> get_tasks -> start -> complete -> validate" do
          # Step 1: get_spec — verify spec content returned
          spec_result = call_and_parse("get_spec", { "run_id" => @run.id.to_s })

          assert_equal @run.id.to_s, spec_result["run_id"]
          assert_includes spec_result["spec"], "Task Manager"
          assert_equal 5, spec_result["metadata"]["total_tasks"]

          # Step 2: get_tasks for tier 0
          tasks_result = call_and_parse("get_tasks", { "run_id" => @run.id.to_s, "tier" => 0 })

          assert_equal @run.id.to_s, tasks_result["run_id"]
          tier0_tasks = tasks_result["tasks"]
          assert_equal 2, tier0_tasks.length

          # Step 3: start_task for each tier 0 task
          tier0_tasks.each do |task_data|
            start_result = call_and_parse("start_task", { "task_id" => task_data["task_id"] })

            assert_equal "in_progress", start_result["status"]
            assert_kind_of Array, start_result["warnings"]
          end

          # Verify tasks are in_progress in the DB
          @t0_setup_db.reload
          @t0_models.reload
          assert_equal "in_progress", @t0_setup_db.status
          assert_equal "in_progress", @t0_models.status

          # Step 4: complete_task for each tier 0 task
          complete_result1 = call_and_parse("complete_task", {
            "task_id" => @t0_setup_db.id.to_s,
            "summary" => "Created database schema with users, tasks, and categories tables",
            "files_changed" => ["db/migrate/001_create_users.rb", "db/migrate/002_create_tasks.rb"]
          })

          assert_equal "completed", complete_result1["status"]
          assert_equal 0, complete_result1["tier_progress"]["tier"]
          assert_equal 1, complete_result1["tier_progress"]["completed"]
          assert_equal 2, complete_result1["tier_progress"]["total"]
          assert_equal false, complete_result1["tier_progress"]["ready_for_validation"]

          complete_result2 = call_and_parse("complete_task", {
            "task_id" => @t0_models.id.to_s,
            "summary" => "Created User, Task, Category models with associations",
            "files_changed" => ["app/models/user.rb", "app/models/task.rb", "app/models/category.rb"]
          })

          assert_equal "completed", complete_result2["status"]
          assert_equal 2, complete_result2["tier_progress"]["completed"]
          assert_equal 2, complete_result2["tier_progress"]["total"]
          assert_equal true, complete_result2["tier_progress"]["ready_for_validation"]

          # Step 5: validate_tier 0
          validate_result = call_and_parse("validate_tier", {
            "run_id" => @run.id.to_s,
            "tier" => 0
          })

          assert_equal 0, validate_result["tier"]
          assert_includes ["pass", "conditional"], validate_result["verdict"],
            "Tier 0 should pass or be conditional (all tasks completed)"

          # Next tier info should be populated
          assert_not_nil validate_result["next_tier"], "Should have next tier info when current tier passes"
          assert_equal 1, validate_result["next_tier"]["tier"]
          assert_equal 2, validate_result["next_tier"]["task_count"]
        end

        # --- Task state transitions ---

        test "task state transitions are correct at each step" do
          # Initial state: pending
          assert_equal "pending", @t0_setup_db.status

          # After start_task: in_progress
          call_and_parse("start_task", { "task_id" => @t0_setup_db.id.to_s })
          @t0_setup_db.reload
          assert_equal "in_progress", @t0_setup_db.status

          # After complete_task: completed
          call_and_parse("complete_task", {
            "task_id" => @t0_setup_db.id.to_s,
            "summary" => "Done",
            "files_changed" => ["db/schema.rb"]
          })
          @t0_setup_db.reload
          assert_equal "completed", @t0_setup_db.status
        end

        test "start_task is idempotent for in_progress tasks" do
          call_and_parse("start_task", { "task_id" => @t0_setup_db.id.to_s })
          @t0_setup_db.reload
          assert_equal "in_progress", @t0_setup_db.status

          # Second start should still succeed
          result = call_and_parse("start_task", { "task_id" => @t0_setup_db.id.to_s })
          assert_equal "in_progress", result["status"]
        end

        test "complete_task from pending status transitions directly to completed" do
          # complete_task allows transitioning from pending directly
          result = call_and_parse("complete_task", {
            "task_id" => @t0_setup_db.id.to_s,
            "summary" => "Quickly done",
            "files_changed" => ["db/schema.rb"]
          })

          assert_equal "completed", result["status"]
          @t0_setup_db.reload
          assert_equal "completed", @t0_setup_db.status
        end

        # --- Tier validation checks ---

        test "tier validation fails when not all tasks are complete" do
          # Complete only one of two tier 0 tasks
          @t0_setup_db.update!(status: :completed,
            result_comments: [{ "body" => "Done" }],
            execution_metadata: { "files_changed" => ["db/schema.rb"] })

          validate_result = call_and_parse("validate_tier", {
            "run_id" => @run.id.to_s,
            "tier" => 0
          })

          assert_equal "fail", validate_result["verdict"]
          assert validate_result["issues"].any? { |i| i["severity"] == "blocking" },
            "Should have blocking issues when tasks are incomplete"
          assert_nil validate_result["next_tier"],
            "Should not have next_tier info when validation fails"
        end

        test "tier validation passes when all tasks complete with result data" do
          # Complete all tier 0 tasks with result data
          [@t0_setup_db, @t0_models].each do |task|
            task.update!(
              status: :completed,
              result_comments: [{ "body" => "Completed successfully" }],
              execution_metadata: { "files_changed" => ["some_file.rb"] }
            )
          end

          validate_result = call_and_parse("validate_tier", {
            "run_id" => @run.id.to_s,
            "tier" => 0
          })

          assert_equal "pass", validate_result["verdict"]
          assert_not_nil validate_result["next_tier"]
          assert_equal 1, validate_result["next_tier"]["tier"]
        end

        test "tier validation returns conditional when tasks lack result data" do
          # Complete all tier 0 tasks but without result data
          [@t0_setup_db, @t0_models].each do |task|
            task.update!(status: :completed, result_comments: [], execution_metadata: {})
          end

          validate_result = call_and_parse("validate_tier", {
            "run_id" => @run.id.to_s,
            "tier" => 0
          })

          assert_equal "conditional", validate_result["verdict"]
          assert validate_result["issues"].any? { |i| i["severity"] == "warning" }
        end

        # --- get_tasks filter combinations ---

        test "get_tasks filters by tier correctly" do
          tier0_result = call_and_parse("get_tasks", { "run_id" => @run.id.to_s, "tier" => 0 })
          tier1_result = call_and_parse("get_tasks", { "run_id" => @run.id.to_s, "tier" => 1 })
          tier2_result = call_and_parse("get_tasks", { "run_id" => @run.id.to_s, "tier" => 2 })

          assert_equal 2, tier0_result["tasks"].length
          assert_equal 2, tier1_result["tasks"].length
          assert_equal 1, tier2_result["tasks"].length

          # All tier 0 tasks should have tier=0
          tier0_result["tasks"].each do |t|
            assert_equal 0, t["tier"]
          end
        end

        test "get_tasks filters by status correctly" do
          @t0_setup_db.update!(status: :completed)
          @t0_models.update!(status: :in_progress)

          completed_result = call_and_parse("get_tasks", {
            "run_id" => @run.id.to_s,
            "status" => "completed"
          })
          pending_result = call_and_parse("get_tasks", {
            "run_id" => @run.id.to_s,
            "status" => "pending"
          })

          assert_equal 1, completed_result["tasks"].length
          assert_equal @t0_setup_db.id.to_s, completed_result["tasks"].first["task_id"]

          # Tier 1 and tier 2 tasks are still pending
          assert_equal 3, pending_result["tasks"].length
        end

        test "get_tasks filters by tier AND status combined" do
          @t0_setup_db.update!(status: :completed)

          result = call_and_parse("get_tasks", {
            "run_id" => @run.id.to_s,
            "tier" => 0,
            "status" => "pending"
          })

          assert_equal 1, result["tasks"].length
          assert_equal @t0_models.id.to_s, result["tasks"].first["task_id"]
        end

        test "get_tasks returns all tasks when no filters applied" do
          result = call_and_parse("get_tasks", { "run_id" => @run.id.to_s })
          assert_equal 5, result["tasks"].length
        end

        # --- Cross-tier dependency validation ---

        test "tier 1 validation checks cross-tier dependencies" do
          # Complete tier 0
          [@t0_setup_db, @t0_models].each do |task|
            task.update!(
              status: :completed,
              result_comments: [{ "body" => "Done" }],
              execution_metadata: { "files_changed" => ["file.rb"] }
            )
          end

          # Complete tier 1
          [@t1_api, @t1_auth].each do |task|
            task.update!(
              status: :completed,
              result_comments: [{ "body" => "Done" }],
              execution_metadata: { "files_changed" => ["file.rb"] }
            )
          end

          validate_result = call_and_parse("validate_tier", {
            "run_id" => @run.id.to_s,
            "tier" => 1
          })

          assert_equal "pass", validate_result["verdict"]

          # Dependencies check should pass since tier 0 is complete
          dep_check = validate_result["checks"].find { |c| c["check"] == "dependencies" }
          assert_equal "pass", dep_check["result"]
        end

        test "tier 1 validation fails when tier 0 dependencies incomplete" do
          # Leave tier 0 incomplete
          @t0_setup_db.update!(status: :pending)
          @t0_models.update!(status: :completed)

          # Complete tier 1 (hypothetically started without deps)
          [@t1_api, @t1_auth].each do |task|
            task.update!(
              status: :completed,
              result_comments: [{ "body" => "Done" }],
              execution_metadata: { "files_changed" => ["file.rb"] }
            )
          end

          validate_result = call_and_parse("validate_tier", {
            "run_id" => @run.id.to_s,
            "tier" => 1
          })

          # Should fail because t0_setup_db (dependency of t1_api) is incomplete
          assert_equal "fail", validate_result["verdict"]
          dep_check = validate_result["checks"].find { |c| c["check"] == "dependencies" }
          assert_equal "fail", dep_check["result"]
        end

        # --- Start task dependency warnings ---

        test "start_task warns about incomplete dependencies" do
          # Start tier 1 task without completing tier 0
          result = call_and_parse("start_task", { "task_id" => @t1_api.id.to_s })

          assert_equal "in_progress", result["status"]
          assert result["warnings"].any?, "Should warn about incomplete dependencies"
          assert result["warnings"].any? { |w| w.include?("not yet completed") },
            "Warning should mention incomplete dependency"
        end

        test "start_task has no warnings when dependencies are satisfied" do
          # Complete tier 0 tasks first
          @t0_setup_db.update!(status: :completed)
          @t0_models.update!(status: :completed)

          result = call_and_parse("start_task", { "task_id" => @t1_api.id.to_s })

          assert_equal "in_progress", result["status"]
          assert_empty result["warnings"], "No warnings when all dependencies are satisfied"
        end

        # --- Complete task stores execution data ---

        test "complete_task stores files_changed and summary in execution_metadata" do
          @t0_setup_db.update!(status: :in_progress)

          call_and_parse("complete_task", {
            "task_id" => @t0_setup_db.id.to_s,
            "summary" => "Created database migrations",
            "files_changed" => ["db/migrate/001.rb", "db/schema.rb"],
            "notes" => "Used Rails generators"
          })

          @t0_setup_db.reload
          exec_meta = @t0_setup_db.execution_metadata
          assert_equal ["db/migrate/001.rb", "db/schema.rb"], exec_meta["files_changed"]
          assert_equal "Created database migrations", exec_meta["completion_summary"]

          # Notes should be in result_comments
          comments = @t0_setup_db.result_comments
          assert comments.any? { |c| c["body"].include?("Notes: Used Rails generators") }
        end

        # --- get_spec formats ---

        test "get_spec returns full format by default" do
          result = call_and_parse("get_spec", { "run_id" => @run.id.to_s })

          assert_equal "full", result["format"]
          assert_includes result["spec"], "Task Manager"
          assert_includes result["spec"], "Purpose"
        end

        test "get_spec summary format returns truncated content" do
          result = call_and_parse("get_spec", {
            "run_id" => @run.id.to_s,
            "format" => "summary"
          })

          assert_equal "summary", result["format"]
          assert_kind_of String, result["spec"]
        end

        test "get_spec metadata reflects task completion progress" do
          @t0_setup_db.update!(status: :completed)

          result = call_and_parse("get_spec", { "run_id" => @run.id.to_s })

          assert_equal 5, result["metadata"]["total_tasks"]
          assert_equal 1, result["metadata"]["completed_tasks"]
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

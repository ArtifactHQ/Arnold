require "test_helper"
require "arnold_pipeline/mcp/context"
require "arnold_pipeline/mcp/tools/complete_task"

module ArnoldPipeline
  module Mcp
    module Tools
      class CompleteTaskTest < ActiveSupport::TestCase
        cover "ArnoldPipeline::Mcp::Tools::CompleteTask*"

        setup do
          @context = Context.new
          @run = PipelineRun.create!(nl_input: "Build a todo app")
          @task1 = Task.create!(
            pipeline_run: @run,
            title: "Setup database",
            description: "Create the database schema",
            position: 0,
            tier: 0,
            status: :in_progress,
            labels: ["backend"],
            depends_on: []
          )
          @task2 = Task.create!(
            pipeline_run: @run,
            title: "Build API",
            description: "Create REST endpoints",
            position: 1,
            tier: 0,
            status: :pending,
            labels: ["backend"],
            depends_on: [@task1.id.to_s]
          )
          @task3 = Task.create!(
            pipeline_run: @run,
            title: "Build UI",
            description: "Create frontend",
            position: 2,
            tier: 1,
            status: :pending,
            labels: ["frontend"],
            depends_on: []
          )
        end

        teardown do
          ArnoldPipeline.reset_configuration!
        end

        test "tool_name returns complete_task" do
          assert_equal "complete_task", CompleteTask.tool_name
        end

        test "description is present" do
          assert_kind_of String, CompleteTask.description
          refute_empty CompleteTask.description
        end

        test "input_schema requires task_id, summary, files_changed" do
          schema = CompleteTask.input_schema
          assert_equal "object", schema[:type]
          assert schema[:properties].key?(:task_id)
          assert schema[:properties].key?(:summary)
          assert schema[:properties].key?(:files_changed)
          assert_includes schema[:required], "task_id"
          assert_includes schema[:required], "summary"
          assert_includes schema[:required], "files_changed"
        end

        test "call transitions in_progress task to completed" do
          result = CompleteTask.call({
            "task_id" => @task1.id.to_s,
            "summary" => "Database schema created",
            "files_changed" => ["db/schema.rb", "db/migrate/001_create_tables.rb"]
          }, @context)

          assert_equal @task1.id.to_s, result[:task_id]
          assert_equal "completed", result[:status]
          assert @task1.reload.completed?
        end

        test "call stores summary in result_comments" do
          CompleteTask.call({
            "task_id" => @task1.id.to_s,
            "summary" => "Database schema created",
            "files_changed" => []
          }, @context)

          @task1.reload
          assert_equal 1, @task1.result_comments.length
          assert_includes @task1.result_comments.first["body"], "Database schema created"
        end

        test "call appends to existing result_comments" do
          @task1.update!(result_comments: [{ "body" => "Previous comment" }])

          CompleteTask.call({
            "task_id" => @task1.id.to_s,
            "summary" => "Done",
            "files_changed" => []
          }, @context)

          @task1.reload
          assert_equal 2, @task1.result_comments.length
          assert_equal "Previous comment", @task1.result_comments.first["body"]
          assert_includes @task1.result_comments.last["body"], "Done"
        end

        test "call stores files_changed in execution_metadata" do
          files = ["app/models/user.rb", "db/migrate/001.rb"]
          CompleteTask.call({
            "task_id" => @task1.id.to_s,
            "summary" => "Done",
            "files_changed" => files
          }, @context)

          @task1.reload
          assert_equal files, @task1.execution_metadata["files_changed"]
        end

        test "call stores completion_summary in execution_metadata" do
          CompleteTask.call({
            "task_id" => @task1.id.to_s,
            "summary" => "Schema complete",
            "files_changed" => []
          }, @context)

          @task1.reload
          assert_equal "Schema complete", @task1.execution_metadata["completion_summary"]
          assert @task1.execution_metadata["completed_at"].present?
        end

        test "call includes notes in comment when provided" do
          CompleteTask.call({
            "task_id" => @task1.id.to_s,
            "summary" => "Done",
            "files_changed" => [],
            "notes" => "Used Rails generators"
          }, @context)

          @task1.reload
          assert_includes @task1.result_comments.last["body"], "Used Rails generators"
        end

        test "call returns tier progress" do
          result = CompleteTask.call({
            "task_id" => @task1.id.to_s,
            "summary" => "Done",
            "files_changed" => []
          }, @context)

          progress = result[:tier_progress]
          assert_equal 0, progress[:tier]
          assert_equal 1, progress[:completed]
          assert_equal 2, progress[:total]
          assert_equal false, progress[:ready_for_validation]
        end

        test "call returns ready_for_validation true when all tier tasks completed" do
          @task2.update!(status: :in_progress)
          @task2.update!(status: :completed)

          result = CompleteTask.call({
            "task_id" => @task1.id.to_s,
            "summary" => "Done",
            "files_changed" => []
          }, @context)

          assert_equal true, result[:tier_progress][:ready_for_validation]
          assert_equal 2, result[:tier_progress][:completed]
          assert_equal 2, result[:tier_progress][:total]
        end

        test "call returns error for completed task" do
          @task1.update!(status: :completed)

          result = CompleteTask.call({
            "task_id" => @task1.id.to_s,
            "summary" => "Done",
            "files_changed" => []
          }, @context)

          assert_includes result[:error], "cannot be completed"
        end

        test "call returns error for failed task" do
          @task1.update!(status: :failed)

          result = CompleteTask.call({
            "task_id" => @task1.id.to_s,
            "summary" => "Done",
            "files_changed" => []
          }, @context)

          assert_includes result[:error], "cannot be completed"
        end

        test "call allows completing a pending task directly" do
          result = CompleteTask.call({
            "task_id" => @task2.id.to_s,
            "summary" => "API built",
            "files_changed" => ["app/controllers/api_controller.rb"]
          }, @context)

          assert_equal "completed", result[:status]
          assert @task2.reload.completed?
        end

        test "call returns error for missing task_id" do
          result = CompleteTask.call({ "summary" => "Done", "files_changed" => [] }, @context)
          assert_equal "task_id is required", result[:error]
        end

        test "call returns error for missing summary" do
          result = CompleteTask.call({ "task_id" => @task1.id.to_s, "files_changed" => [] }, @context)
          assert_equal "summary is required", result[:error]
        end

        test "call returns error for nonexistent task" do
          result = CompleteTask.call({
            "task_id" => "99999",
            "summary" => "Done",
            "files_changed" => []
          }, @context)
          assert_includes result[:error], "Task not found"
        end

        test "call returns error when no pipeline run exists" do
          PipelineRun.destroy_all
          result = CompleteTask.call({
            "task_id" => "1",
            "summary" => "Done",
            "files_changed" => []
          }, @context)
          assert_equal "No pipeline run found", result[:error]
        end

        test "call handles nil notes gracefully" do
          result = CompleteTask.call({
            "task_id" => @task1.id.to_s,
            "summary" => "Done",
            "files_changed" => [],
            "notes" => nil
          }, @context)

          assert_equal "completed", result[:status]
          @task1.reload
          refute_includes @task1.result_comments.last["body"], "Notes:"
        end

        test "call tier_progress scopes to correct tier" do
          # task3 is in tier 1, should not affect tier 0 progress
          result = CompleteTask.call({
            "task_id" => @task1.id.to_s,
            "summary" => "Done",
            "files_changed" => []
          }, @context)

          assert_equal 0, result[:tier_progress][:tier]
          assert_equal 2, result[:tier_progress][:total] # only tier 0 tasks
        end
      end
    end
  end
end

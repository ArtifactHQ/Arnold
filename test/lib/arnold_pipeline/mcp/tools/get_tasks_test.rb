require "test_helper"
require "arnold_pipeline/mcp/context"
require "arnold_pipeline/mcp/tools/get_tasks"

module ArnoldPipeline
  module Mcp
    module Tools
      class GetTasksTest < ActiveSupport::TestCase
        cover "ArnoldPipeline::Mcp::Tools::GetTasks*"

        setup do
          @context = Context.new
          @run = PipelineRun.create!(nl_input: "Build a todo app")
          @task1 = Task.create!(
            pipeline_run: @run,
            title: "Setup database",
            description: "Create the database schema",
            position: 0,
            tier: 0,
            status: :completed,
            labels: [ "backend", "database" ],
            depends_on: [],
            acceptance_criteria: [ "Schema created", "Migrations run" ]
          )
          @task2 = Task.create!(
            pipeline_run: @run,
            title: "Build API",
            description: "Create REST endpoints",
            position: 1,
            tier: 1,
            status: :pending,
            labels: [ "backend", "api" ],
            depends_on: [ @task1.id.to_s ],
            acceptance_criteria: [ "CRUD endpoints working" ]
          )
        end

        teardown do
          ArnoldPipeline.reset_configuration!
        end

        test "tool_name returns get_tasks" do
          assert_equal "get_tasks", GetTasks.tool_name
        end

        test "description is present" do
          assert_kind_of String, GetTasks.description
          refute_empty GetTasks.description
        end

        test "input_schema returns valid schema" do
          schema = GetTasks.input_schema
          assert_equal "object", schema[:type]
          assert schema[:properties].key?(:run_id)
          assert schema[:properties].key?(:tier)
          assert schema[:properties].key?(:status)
        end

        test "call returns all tasks for latest run" do
          result = GetTasks.call({}, @context)

          assert_equal @run.id.to_s, result[:run_id]
          assert_equal 2, result[:tasks].length
        end

        test "call returns tasks ordered by position" do
          result = GetTasks.call({}, @context)
          titles = result[:tasks].map { |t| t[:title] }
          assert_equal [ "Setup database", "Build API" ], titles
        end

        test "call filters by tier" do
          result = GetTasks.call({ "tier" => 0 }, @context)
          assert_equal 1, result[:tasks].length
          assert_equal "Setup database", result[:tasks].first[:title]
        end

        test "call filters by status" do
          result = GetTasks.call({ "status" => "pending" }, @context)
          assert_equal 1, result[:tasks].length
          assert_equal "Build API", result[:tasks].first[:title]
        end

        test "call filters by both tier and status" do
          result = GetTasks.call({ "tier" => 1, "status" => "pending" }, @context)
          assert_equal 1, result[:tasks].length
          assert_equal "Build API", result[:tasks].first[:title]
        end

        test "call returns empty tasks when no match" do
          result = GetTasks.call({ "status" => "failed" }, @context)
          assert_equal [], result[:tasks]
        end

        test "call computes current_tier from pending/in_progress tasks" do
          result = GetTasks.call({}, @context)
          assert_equal 1, result[:current_tier]
        end

        test "call returns current_tier 0 when all tasks completed" do
          @task2.update!(status: :completed)
          result = GetTasks.call({}, @context)
          assert_equal 0, result[:current_tier]
        end

        test "call formats task with all expected fields" do
          result = GetTasks.call({}, @context)
          task = result[:tasks].first

          assert_equal @task1.id.to_s, task[:task_id]
          assert_equal "Setup database", task[:title]
          assert_equal "Create the database schema", task[:description]
          assert_equal 0, task[:tier]
          assert_equal "completed", task[:status]
          assert_equal [ "backend", "database" ], task[:labels]
          assert_equal [], task[:dependencies]
          assert_equal [ "Schema created", "Migrations run" ], task[:acceptance_criteria]
          assert_kind_of String, task[:domain]
          assert_kind_of String, task[:persona_context]
        end

        test "call includes dependencies from depends_on" do
          result = GetTasks.call({}, @context)
          api_task = result[:tasks].find { |t| t[:title] == "Build API" }
          assert_equal [ @task1.id.to_s ], api_task[:dependencies]
        end

        test "call returns error when no pipeline run found" do
          PipelineRun.destroy_all
          result = GetTasks.call({}, @context)
          assert_equal "No pipeline run found", result[:error]
        end

        test "call returns specific run by run_id" do
          other_run = PipelineRun.create!(nl_input: "other app")
          Task.create!(pipeline_run: other_run, title: "Other task", position: 0)

          result = GetTasks.call({ "run_id" => other_run.id.to_s }, @context)
          assert_equal other_run.id.to_s, result[:run_id]
          assert_equal 1, result[:tasks].length
          assert_equal "Other task", result[:tasks].first[:title]
        end
      end
    end
  end
end

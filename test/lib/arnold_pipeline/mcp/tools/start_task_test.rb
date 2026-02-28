require "test_helper"
require "arnold_pipeline/mcp/context"
require "arnold_pipeline/mcp/tools/start_task"

module ArnoldPipeline
  module Mcp
    module Tools
      class StartTaskTest < ActiveSupport::TestCase
        cover "ArnoldPipeline::Mcp::Tools::StartTask*"

        setup do
          @context = Context.new
          @run = PipelineRun.create!(nl_input: "Build a web app with authentication")
          @spec = Specification.create!(
            pipeline_run: @run,
            content: "# Web App Spec\n\n## Authentication\n- Login\n- Signup\n\n## Dashboard\n- User dashboard\n",
            version: 1,
            structured_data: {}
          )
          @task1 = Task.create!(
            pipeline_run: @run,
            title: "Setup database",
            description: "Create the database schema",
            position: 0,
            tier: 0,
            status: :completed,
            labels: [ "backend", "database" ],
            depends_on: [],
            result_comments: [ { "body" => "Database schema created successfully" } ]
          )
          @task2 = Task.create!(
            pipeline_run: @run,
            title: "Build authentication",
            description: "Implement login and signup",
            position: 1,
            tier: 1,
            status: :pending,
            labels: [ "backend", "authentication" ],
            depends_on: [ @task1.id.to_s ]
          )
        end

        teardown do
          ArnoldPipeline.reset_configuration!
        end

        test "tool_name returns start_task" do
          assert_equal "start_task", StartTask.tool_name
        end

        test "description is present" do
          assert_kind_of String, StartTask.description
          refute_empty StartTask.description
        end

        test "input_schema requires task_id" do
          schema = StartTask.input_schema
          assert_equal "object", schema[:type]
          assert schema[:properties].key?(:task_id)
          assert_includes schema[:required], "task_id"
        end

        test "call transitions pending task to in_progress" do
          result = StartTask.call({ "task_id" => @task2.id.to_s }, @context)

          assert_equal @task2.id.to_s, result[:task_id]
          assert_equal "in_progress", result[:status]
          assert @task2.reload.in_progress?
        end

        test "call is idempotent for already in_progress task" do
          @task2.update!(status: :in_progress)

          result = StartTask.call({ "task_id" => @task2.id.to_s }, @context)

          assert_equal @task2.id.to_s, result[:task_id]
          assert_equal "in_progress", result[:status]
          assert_nil result[:error]
        end

        test "call returns error for completed task" do
          @task2.update!(status: :in_progress)
          @task2.update!(status: :completed)

          result = StartTask.call({ "task_id" => @task2.id.to_s }, @context)

          assert_includes result[:error], "cannot be started"
          assert_includes result[:error], "completed"
        end

        test "call returns error for failed task" do
          @task2.update!(status: :in_progress)
          @task2.update!(status: :failed)

          result = StartTask.call({ "task_id" => @task2.id.to_s }, @context)

          assert_includes result[:error], "cannot be started"
          assert_includes result[:error], "failed"
        end

        test "call returns error for missing task_id" do
          result = StartTask.call({}, @context)
          assert_equal "task_id is required", result[:error]
        end

        test "call returns error for nonexistent task" do
          result = StartTask.call({ "task_id" => "99999" }, @context)
          assert_includes result[:error], "Task not found"
        end

        test "call returns error when no pipeline run exists" do
          PipelineRun.destroy_all
          result = StartTask.call({ "task_id" => "1" }, @context)
          assert_equal "No pipeline run found", result[:error]
        end

        test "call warns about incomplete dependencies" do
          @task1.update!(status: :in_progress)

          result = StartTask.call({ "task_id" => @task2.id.to_s }, @context)

          assert_equal 1, result[:warnings].length
          assert_includes result[:warnings].first, "Setup database"
          assert_includes result[:warnings].first, "not yet completed"
        end

        test "call returns no warnings when dependencies are completed" do
          result = StartTask.call({ "task_id" => @task2.id.to_s }, @context)
          assert_empty result[:warnings]
        end

        test "call returns no warnings for task with no dependencies" do
          @task1.update!(status: :pending)
          result = StartTask.call({ "task_id" => @task1.id.to_s }, @context)
          assert_empty result[:warnings]
        end

        test "call returns context with spec_excerpt" do
          result = StartTask.call({ "task_id" => @task2.id.to_s }, @context)

          assert_kind_of String, result[:context][:spec_excerpt]
          assert_includes result[:context][:spec_excerpt], "Authentication"
        end

        test "call returns context with prior_context from completed dependencies" do
          result = StartTask.call({ "task_id" => @task2.id.to_s }, @context)

          assert_kind_of String, result[:context][:prior_context]
          assert_includes result[:context][:prior_context], "Setup database"
          assert_includes result[:context][:prior_context], "Database schema created"
        end

        test "call returns empty prior_context when no dependencies" do
          @task1.update!(status: :pending)
          result = StartTask.call({ "task_id" => @task1.id.to_s }, @context)
          assert_equal "", result[:context][:prior_context]
        end

        test "call returns context with persona_guidance" do
          result = StartTask.call({ "task_id" => @task2.id.to_s }, @context)

          assert_kind_of String, result[:context][:persona_guidance]
        end

        test "call returns context with recipe_guidance" do
          result = StartTask.call({ "task_id" => @task2.id.to_s }, @context)

          assert_kind_of String, result[:context][:recipe_guidance]
        end

        test "call uses library_selections from pipeline_run metadata for persona" do
          @run.update!(metadata: {
            "library_selections" => { "persona" => "Software Architect" }
          })

          result = StartTask.call({ "task_id" => @task2.id.to_s }, @context)

          # Should attempt to use the specified persona
          assert_kind_of String, result[:context][:persona_guidance]
        end

        test "call spec_excerpt falls back to truncated spec when no section matches" do
          task = Task.create!(
            pipeline_run: @run,
            title: "Unrelated thing",
            description: "Something with no label match",
            position: 2,
            tier: 0,
            status: :pending,
            labels: [ "zzz_nomatch" ]
          )

          result = StartTask.call({ "task_id" => task.id.to_s }, @context)

          # Falls back to first N lines of spec
          assert_kind_of String, result[:context][:spec_excerpt]
          refute_empty result[:context][:spec_excerpt]
        end

        test "call handles task with empty labels gracefully" do
          task = Task.create!(
            pipeline_run: @run,
            title: "No labels task",
            description: "A task with no labels",
            position: 3,
            tier: 0,
            status: :pending,
            labels: []
          )

          result = StartTask.call({ "task_id" => task.id.to_s }, @context)

          assert_equal "in_progress", result[:status]
          assert_kind_of Hash, result[:context]
        end

        test "call handles run without specification" do
          @spec.destroy!
          result = StartTask.call({ "task_id" => @task2.id.to_s }, @context)

          assert_equal "in_progress", result[:status]
          assert_equal "", result[:context][:spec_excerpt]
        end
      end
    end
  end
end

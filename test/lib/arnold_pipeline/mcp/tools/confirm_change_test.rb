require "test_helper"
require "arnold_pipeline/mcp/context"
require "arnold_pipeline/mcp/tools/propose_change"
require "arnold_pipeline/mcp/tools/confirm_change"

module ArnoldPipeline
  module Mcp
    module Tools
      class ConfirmChangeTest < ActiveSupport::TestCase
        cover "ArnoldPipeline::Mcp::Tools::ConfirmChange*"

        setup do
          @context = Context.new
          @run = PipelineRun.create!(nl_input: "Build a fitness tracking app")
          @spec = Specification.create!(
            pipeline_run: @run,
            content: "# Fitness Tracker\n\n## Purpose\nA fitness app.\n\n## Requirements\n- Track workouts",
            version: 1,
            structured_data: {
              "domains" => [{ "name" => "Workouts" }]
            }
          )

          @change_id = "test-change-id-123"
          @analysis = {
            "summary" => "Added social sharing feature",
            "deltas" => [
              {
                "operation" => "added",
                "section" => "Social",
                "requirement" => "Share Workouts",
                "content" => "### Requirement: Share Workouts [REQ-SOCIAL-001]\nAllow sharing workout results.",
                "before_content" => "",
                "after_content" => "",
                "rationale" => "User requested social features"
              }
            ]
          }

          ProposeChange.proposals[@change_id] = {
            change_id: @change_id,
            run_id: @run.id,
            description: "Add social sharing",
            analysis: @analysis,
            created_at: Time.current
          }

          # Stub OpenSpec to avoid external CLI dependency
          ArnoldPipeline.configuration.stubs(:openspec_enabled).returns(false)
        end

        teardown do
          ArnoldPipeline.reset_configuration!
          ProposeChange.clear_proposals!
        end

        test "tool_name returns confirm_change" do
          assert_equal "confirm_change", ConfirmChange.tool_name
        end

        test "description is present" do
          assert_kind_of String, ConfirmChange.description
          refute_empty ConfirmChange.description
        end

        test "input_schema requires change_id" do
          schema = ConfirmChange.input_schema
          assert_equal "object", schema[:type]
          assert schema[:properties].key?(:change_id)
          assert_includes schema[:required], "change_id"
        end

        test "call applies change and returns success" do
          result = ConfirmChange.call({ "change_id" => @change_id }, @context)

          assert_equal true, result[:applied]
          assert_equal "Added social sharing feature", result[:summary]
          assert result[:revision].to_i > 1
        end

        test "call creates a new spec revision" do
          initial_version = @spec.version

          ConfirmChange.call({ "change_id" => @change_id }, @context)

          @spec.reload
          assert @spec.version > initial_version
          assert @spec.spec_revisions.any? { |r| r.change_source == "mcp_confirm" }
        end

        test "call updates spec content with deltas" do
          ConfirmChange.call({ "change_id" => @change_id }, @context)

          @spec.reload
          assert_includes @spec.content, "Spec Iteration"
        end

        test "call removes consumed proposal" do
          ConfirmChange.call({ "change_id" => @change_id }, @context)
          assert_nil ProposeChange.proposals[@change_id]
        end

        test "call invalidates affected pending tasks" do
          task = Task.create!(
            pipeline_run: @run, title: "Social feature task", position: 0,
            status: :pending, labels: ["social"]
          )

          result = ConfirmChange.call({ "change_id" => @change_id }, @context)

          task.reload
          assert_equal "superseded", task.status
          assert_equal 1, result[:tasks_invalidated]
        end

        test "call does not invalidate completed tasks" do
          task = Task.create!(
            pipeline_run: @run, title: "Social feature task", position: 0,
            status: :completed, labels: ["social"]
          )

          result = ConfirmChange.call({ "change_id" => @change_id }, @context)

          task.reload
          assert_equal "completed", task.status
          assert_equal 0, result[:tasks_invalidated]
        end

        test "call does not invalidate unrelated tasks" do
          task = Task.create!(
            pipeline_run: @run, title: "Database setup", position: 0,
            status: :pending, labels: ["backend"]
          )

          result = ConfirmChange.call({ "change_id" => @change_id }, @context)

          task.reload
          assert_equal "pending", task.status
          assert_equal 0, result[:tasks_invalidated]
        end

        test "call returns ready_for_execution true when no active tasks" do
          result = ConfirmChange.call({ "change_id" => @change_id }, @context)
          assert_equal true, result[:ready_for_execution]
        end

        test "call returns ready_for_execution based on task state" do
          Task.create!(
            pipeline_run: @run, title: "Active task", position: 0,
            status: :in_progress, labels: ["unrelated"]
          )

          result = ConfirmChange.call({ "change_id" => @change_id }, @context)
          # Has active tasks but no tasks were invalidated
          assert_equal true, result[:ready_for_execution]
        end

        test "call returns error when change_id is empty" do
          result = ConfirmChange.call({ "change_id" => "" }, @context)
          assert_equal "change_id is required", result[:error]
        end

        test "call returns error when proposal not found" do
          result = ConfirmChange.call({ "change_id" => "nonexistent-id" }, @context)
          assert_includes result[:error], "No proposal found"
        end

        test "call returns error when pipeline run no longer exists" do
          @run.destroy
          result = ConfirmChange.call({ "change_id" => @change_id }, @context)
          assert_includes result[:error], "no longer exists"
        end

        test "call handles empty deltas gracefully" do
          ProposeChange.proposals[@change_id][:analysis]["deltas"] = []

          result = ConfirmChange.call({ "change_id" => @change_id }, @context)

          assert_equal false, result[:applied]
          assert_equal 0, result[:tasks_invalidated]
          assert_includes result[:summary], "No deltas to apply"
        end

        test "call accepts optional answers parameter" do
          result = ConfirmChange.call({
            "change_id" => @change_id,
            "answers" => { "Is this intended?" => "Yes, proceed" }
          }, @context)

          assert_equal true, result[:applied]
        end

        test "call response has all expected keys" do
          result = ConfirmChange.call({ "change_id" => @change_id }, @context)

          assert result.key?(:applied)
          assert result.key?(:revision)
          assert result.key?(:summary)
          assert result.key?(:tasks_invalidated)
          assert result.key?(:ready_for_execution)
        end

        test "call returns correct revision number" do
          result = ConfirmChange.call({ "change_id" => @change_id }, @context)

          @spec.reload
          assert_equal @spec.version.to_s, result[:revision]
        end
      end
    end
  end
end

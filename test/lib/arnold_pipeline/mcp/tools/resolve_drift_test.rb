require "test_helper"
require "arnold_pipeline/mcp/context"
require "arnold_pipeline/mcp/tools/resolve_drift"

module ArnoldPipeline
  module Mcp
    module Tools
      class ResolveDriftTest < ActiveSupport::TestCase
        cover "ArnoldPipeline::Mcp::Tools::ResolveDrift*"

        setup do
          @context = Context.new
          @run = PipelineRun.create!(nl_input: "Build a todo app")
          @spec = @run.create_specification!(content: "# Todo App\n## Authentication\nLogin and signup", version: 1)
          @revision = @spec.spec_revisions.create!(version: 1, content: @spec.content, change_source: "spec_generation")

          @task = Task.create!(
            pipeline_run: @run,
            title: "Setup auth",
            description: "Build authentication",
            position: 0,
            status: :completed,
            labels: [ "authentication" ]
          )

          @finding = DriftFinding.create!(
            pipeline_run: @run,
            spec_revision: @revision,
            domain: "authentication",
            drift_type: "behavioral",
            severity: "warning",
            description: "Auth missing password reset",
            spec_expectation: "Users can reset passwords",
            actual_state: "No password reset endpoint",
            recommendation: "update_code",
            affected_tasks: [ @task.id.to_s ]
          )
        end

        teardown do
          ArnoldPipeline.reset_configuration!
        end

        test "tool_name returns resolve_drift" do
          assert_equal "resolve_drift", ResolveDrift.tool_name
        end

        test "description is present" do
          assert_kind_of String, ResolveDrift.description
          refute_empty ResolveDrift.description
        end

        test "input_schema requires finding_id and resolution" do
          schema = ResolveDrift.input_schema
          assert_equal "object", schema[:type]
          assert schema[:properties].key?(:finding_id)
          assert schema[:properties].key?(:resolution)
          assert schema[:properties].key?(:notes)
          assert_includes schema[:required], "finding_id"
          assert_includes schema[:required], "resolution"
        end

        # --- update_spec ---

        test "update_spec creates SpecRevision and marks resolved" do
          llm = stub("llm")
          llm.expects(:chat_json).returns({
            "summary" => "Updated spec for password reset",
            "deltas" => [
              {
                "operation" => "added",
                "section" => "Authentication",
                "requirement" => "Password Reset",
                "content" => "Users can reset their password via email",
                "before_content" => "",
                "after_content" => "Users can reset their password via email",
                "rationale" => "Drift detection found missing feature"
              }
            ]
          })
          ResolveDrift.stubs(:build_llm).returns(llm)

          result = ResolveDrift.call({
            "finding_id" => @finding.id.to_s,
            "resolution" => "update_spec"
          }, @context)

          assert_equal @finding.id.to_s, result[:finding_id]
          assert_equal "update_spec", result[:resolution_applied]
          assert_equal "resolved", result[:status]
          assert result[:actions_taken].any? { |a| a.include?("delta") }
          assert_not_nil result[:spec_revision]

          @finding.reload
          assert_equal "update_spec", @finding.resolution
          assert_not_nil @finding.resolved_at
        end

        test "update_spec with empty deltas still resolves finding" do
          llm = stub("llm")
          llm.expects(:chat_json).returns({
            "summary" => "No changes needed",
            "deltas" => []
          })
          ResolveDrift.stubs(:build_llm).returns(llm)

          result = ResolveDrift.call({
            "finding_id" => @finding.id.to_s,
            "resolution" => "update_spec"
          }, @context)

          assert_equal "resolved", result[:status]
          assert_empty result[:tasks_generated]

          @finding.reload
          assert_equal "update_spec", @finding.resolution
        end

        # --- update_code ---

        test "update_code creates new tasks and marks pending_execution" do
          result = ResolveDrift.call({
            "finding_id" => @finding.id.to_s,
            "resolution" => "update_code",
            "notes" => "Creating corrective task"
          }, @context)

          assert_equal @finding.id.to_s, result[:finding_id]
          assert_equal "update_code", result[:resolution_applied]
          assert_equal "pending_execution", result[:status]
          assert_equal 1, result[:tasks_generated].size

          generated = result[:tasks_generated].first
          assert_includes generated[:title], "Fix:"
          assert_includes generated[:description], "Drift Finding"
          assert_includes generated[:description], "Spec Expectation"

          @finding.reload
          assert_equal "update_code", @finding.resolution
          assert_equal "Creating corrective task", @finding.notes
        end

        test "update_code creates task with correct position" do
          ResolveDrift.call({
            "finding_id" => @finding.id.to_s,
            "resolution" => "update_code"
          }, @context)

          new_task = @run.tasks.order(:position).last
          assert_equal 1, new_task.position # After existing task at position 0
          assert new_task.pending?
        end

        # --- accept ---

        test "accept marks resolved and excluded from future checks" do
          result = ResolveDrift.call({
            "finding_id" => @finding.id.to_s,
            "resolution" => "accept",
            "notes" => "This is expected behavior"
          }, @context)

          assert_equal "accepted", result[:resolution_applied]
          assert_equal "resolved", result[:status]
          assert_empty result[:tasks_generated]
          assert_nil result[:spec_revision]
          assert result[:actions_taken].any? { |a| a.include?("excluded from future") }

          @finding.reload
          assert_equal "accepted", @finding.resolution
          assert_equal "This is expected behavior", @finding.notes
          assert_not_nil @finding.resolved_at
        end

        # --- ignore ---

        test "ignore marks resolved but NOT excluded from future checks" do
          result = ResolveDrift.call({
            "finding_id" => @finding.id.to_s,
            "resolution" => "ignore"
          }, @context)

          assert_equal "ignored", result[:resolution_applied]
          assert_equal "resolved", result[:status]
          assert result[:actions_taken].any? { |a| a.include?("may reappear") }

          @finding.reload
          assert_equal "ignored", @finding.resolution
        end

        # --- Error cases ---

        test "invalid finding_id returns error" do
          result = ResolveDrift.call({
            "finding_id" => "999999",
            "resolution" => "accept"
          }, @context)

          assert_includes result[:error], "No drift finding found"
        end

        test "empty finding_id returns error" do
          result = ResolveDrift.call({
            "finding_id" => "",
            "resolution" => "accept"
          }, @context)

          assert_equal "finding_id is required", result[:error]
        end

        test "already-resolved finding returns error" do
          @finding.update!(resolution: "accepted", resolved_at: Time.current)

          result = ResolveDrift.call({
            "finding_id" => @finding.id.to_s,
            "resolution" => "ignore"
          }, @context)

          assert_includes result[:error], "already resolved"
        end

        test "missing resolution returns error" do
          result = ResolveDrift.call({
            "finding_id" => @finding.id.to_s,
            "resolution" => ""
          }, @context)

          assert_equal "resolution is required", result[:error]
        end
      end
    end
  end
end

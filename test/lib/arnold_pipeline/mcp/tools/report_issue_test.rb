require "test_helper"
require "arnold_pipeline/mcp/context"
require "arnold_pipeline/mcp/tools/report_issue"

module ArnoldPipeline
  module Mcp
    module Tools
      class ReportIssueTest < ActiveSupport::TestCase
        cover "ArnoldPipeline::Mcp::Tools::ReportIssue*"

        setup do
          @context = Context.new
          @run = PipelineRun.create!(nl_input: "Build a web app")
          @spec = Specification.create!(
            pipeline_run: @run,
            content: "# Web App Spec\n\n## Authentication\n- Login\n- Signup\n\n## API\n- REST endpoints\n",
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
            labels: ["backend"],
            depends_on: []
          )
          @task2 = Task.create!(
            pipeline_run: @run,
            title: "Build authentication",
            description: "Implement login and signup",
            position: 1,
            tier: 1,
            status: :in_progress,
            labels: ["backend", "authentication"],
            depends_on: [@task1.id.to_s]
          )
        end

        teardown do
          ArnoldPipeline.reset_configuration!
        end

        test "tool_name returns report_issue" do
          assert_equal "report_issue", ReportIssue.tool_name
        end

        test "description is present" do
          assert_kind_of String, ReportIssue.description
          refute_empty ReportIssue.description
        end

        test "input_schema requires task_id and issue" do
          schema = ReportIssue.input_schema
          assert_equal "object", schema[:type]
          assert schema[:properties].key?(:task_id)
          assert schema[:properties].key?(:issue)
          assert schema[:properties].key?(:suggestion)
          assert_includes schema[:required], "task_id"
          assert_includes schema[:required], "issue"
        end

        test "call classifies spec-related issue" do
          result = ReportIssue.call({
            "task_id" => @task2.id.to_s,
            "issue" => "The spec is unclear about what authentication method to use"
          }, @context)

          assert_equal "spec_change", result[:resolution]
          assert_kind_of String, result[:detail]
          assert_kind_of Array, result[:actions_taken]
        end

        test "call classifies dependency-related issue" do
          result = ReportIssue.call({
            "task_id" => @task2.id.to_s,
            "issue" => "This task is blocked because it depends on a missing user model"
          }, @context)

          assert_equal "dependency_fix", result[:resolution]
        end

        test "call classifies task restructure issue" do
          result = ReportIssue.call({
            "task_id" => @task2.id.to_s,
            "issue" => "The task description is wrong, it should be about OAuth not basic auth"
          }, @context)

          assert_equal "task_restructure", result[:resolution]
        end

        test "call defaults to guidance for unclassified issues" do
          result = ReportIssue.call({
            "task_id" => @task2.id.to_s,
            "issue" => "Having trouble with the implementation"
          }, @context)

          assert_equal "guidance", result[:resolution]
        end

        test "call records issue in result_comments" do
          ReportIssue.call({
            "task_id" => @task2.id.to_s,
            "issue" => "Something is wrong"
          }, @context)

          @task2.reload
          assert @task2.result_comments.any?
          assert_includes @task2.result_comments.last["body"], "Something is wrong"
        end

        test "call records suggestion in result_comments when provided" do
          ReportIssue.call({
            "task_id" => @task2.id.to_s,
            "issue" => "Something is wrong",
            "suggestion" => "Try using OAuth"
          }, @context)

          @task2.reload
          assert_includes @task2.result_comments.last["body"], "Try using OAuth"
        end

        test "call appends to existing result_comments" do
          @task2.update!(result_comments: [{ "body" => "Previous comment" }])

          ReportIssue.call({
            "task_id" => @task2.id.to_s,
            "issue" => "New issue"
          }, @context)

          @task2.reload
          assert_equal 2, @task2.result_comments.length
        end

        test "call returns revised_task for task_restructure with suggestion" do
          result = ReportIssue.call({
            "task_id" => @task2.id.to_s,
            "issue" => "The task description is wrong",
            "suggestion" => "Implement OAuth 2.0 authentication with Google provider"
          }, @context)

          assert_equal "task_restructure", result[:resolution]
          assert_not_nil result[:revised_task]
          assert_equal @task2.id.to_s, result[:revised_task][:task_id]
          assert_equal "Implement OAuth 2.0 authentication with Google provider", result[:revised_task][:description]
          assert_equal "Implement login and signup", result[:revised_task][:previous_description]

          @task2.reload
          assert_equal "Implement OAuth 2.0 authentication with Google provider", @task2.description
        end

        test "call returns nil revised_task for task_restructure without suggestion" do
          result = ReportIssue.call({
            "task_id" => @task2.id.to_s,
            "issue" => "The task description is wrong"
          }, @context)

          assert_equal "task_restructure", result[:resolution]
          assert_nil result[:revised_task]
        end

        test "call dependency_fix identifies incomplete dependencies" do
          @task1.update!(status: :in_progress)

          result = ReportIssue.call({
            "task_id" => @task2.id.to_s,
            "issue" => "Blocked because the database depends on something not done"
          }, @context)

          assert_equal "dependency_fix", result[:resolution]
          assert_includes result[:detail], "Setup database"
          assert_includes result[:detail], "in_progress"
        end

        test "call dependency_fix handles all completed dependencies" do
          result = ReportIssue.call({
            "task_id" => @task2.id.to_s,
            "issue" => "I'm blocked by a prerequisite that seems to be missing something"
          }, @context)

          assert_equal "dependency_fix", result[:resolution]
          assert_includes result[:detail], "All dependency tasks are completed"
        end

        test "call dependency_fix handles task with no dependencies" do
          result = ReportIssue.call({
            "task_id" => @task1.id.to_s,
            "issue" => "This depends on something that doesn't exist"
          }, @context)

          assert_equal "dependency_fix", result[:resolution]
          assert_includes result[:detail], "no declared dependencies"
        end

        test "call guidance provides recipe and persona context" do
          result = ReportIssue.call({
            "task_id" => @task2.id.to_s,
            "issue" => "Not sure how to proceed with this"
          }, @context)

          assert_equal "guidance", result[:resolution]
          assert_kind_of String, result[:detail]
          assert result[:actions_taken].length >= 1
        end

        test "call spec_change includes suggestion in detail" do
          result = ReportIssue.call({
            "task_id" => @task2.id.to_s,
            "issue" => "The requirement is unclear",
            "suggestion" => "Add OAuth details to the spec"
          }, @context)

          assert_equal "spec_change", result[:resolution]
          assert_includes result[:detail], "Add OAuth details"
        end

        test "call returns error for missing task_id" do
          result = ReportIssue.call({ "issue" => "problem" }, @context)
          assert_equal "task_id is required", result[:error]
        end

        test "call returns error for missing issue" do
          result = ReportIssue.call({ "task_id" => @task2.id.to_s }, @context)
          assert_equal "issue is required", result[:error]
        end

        test "call returns error for nonexistent task" do
          result = ReportIssue.call({
            "task_id" => "99999",
            "issue" => "problem"
          }, @context)
          assert_includes result[:error], "Task not found"
        end

        test "call returns error when no pipeline run exists" do
          PipelineRun.destroy_all
          result = ReportIssue.call({
            "task_id" => "1",
            "issue" => "problem"
          }, @context)
          assert_equal "No pipeline run found", result[:error]
        end

        test "call always returns task_id in response" do
          result = ReportIssue.call({
            "task_id" => @task2.id.to_s,
            "issue" => "some issue"
          }, @context)

          assert_equal @task2.id.to_s, result[:task_id]
        end
      end
    end
  end
end

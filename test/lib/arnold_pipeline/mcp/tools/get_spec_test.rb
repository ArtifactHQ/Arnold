require "test_helper"
require "arnold_pipeline/mcp/context"
require "arnold_pipeline/mcp/tools/get_spec"

module ArnoldPipeline
  module Mcp
    module Tools
      class GetSpecTest < ActiveSupport::TestCase
        cover "ArnoldPipeline::Mcp::Tools::GetSpec*"

        setup do
          @context = Context.new
          @run = PipelineRun.create!(nl_input: "Build a todo app")
          @spec = Specification.create!(
            pipeline_run: @run,
            content: "# Todo App Spec\n\n## Features\n- Add todos\n- Remove todos",
            version: 2,
            structured_data: {
              "personas" => [{ "name" => "User" }],
              "domains" => [{ "name" => "Tasks" }],
              "recipes" => [{ "name" => "Web App" }]
            }
          )
        end

        teardown do
          ArnoldPipeline.reset_configuration!
        end

        test "tool_name returns get_spec" do
          assert_equal "get_spec", GetSpec.tool_name
        end

        test "description is present" do
          assert_kind_of String, GetSpec.description
          refute_empty GetSpec.description
        end

        test "input_schema returns valid schema" do
          schema = GetSpec.input_schema
          assert_equal "object", schema[:type]
          assert schema[:properties].key?(:run_id)
          assert schema[:properties].key?(:format)
        end

        test "call returns spec for latest run" do
          result = GetSpec.call({}, @context)

          assert_equal @run.id.to_s, result[:run_id]
          assert_equal "2", result[:revision]
          assert_equal "full", result[:format]
          assert_includes result[:spec], "Todo App Spec"
        end

        test "call returns spec for specific run_id" do
          result = GetSpec.call({ "run_id" => @run.id.to_s }, @context)
          assert_equal @run.id.to_s, result[:run_id]
        end

        test "call returns summary format" do
          result = GetSpec.call({ "format" => "summary" }, @context)
          assert_equal "summary", result[:format]
          assert_includes result[:spec], "Todo App Spec"
        end

        test "call truncates long specs in summary mode" do
          long_content = (1..100).map { |i| "Line #{i}" }.join("\n")
          @spec.update!(content: long_content)

          result = GetSpec.call({ "format" => "summary" }, @context)
          assert_includes result[:spec], "truncated"
        end

        test "call includes metadata with personas, domains, recipes" do
          result = GetSpec.call({}, @context)

          assert_equal ["User"], result[:metadata][:personas]
          assert_equal ["Tasks"], result[:metadata][:domains]
          assert_equal ["Web App"], result[:metadata][:recipes]
        end

        test "call includes task counts in metadata" do
          Task.create!(pipeline_run: @run, title: "Task 1", position: 0, status: :completed)
          Task.create!(pipeline_run: @run, title: "Task 2", position: 1, status: :pending)

          result = GetSpec.call({}, @context)

          assert_equal 2, result[:metadata][:total_tasks]
          assert_equal 1, result[:metadata][:completed_tasks]
        end

        test "call returns error when no pipeline run found" do
          PipelineRun.destroy_all
          result = GetSpec.call({}, @context)
          assert_equal "No pipeline run found", result[:error]
        end

        test "call returns error when run has no specification" do
          run_no_spec = PipelineRun.create!(nl_input: "no spec")
          result = GetSpec.call({ "run_id" => run_no_spec.id.to_s }, @context)
          assert_includes result[:error], "No specification found"
        end

        test "call handles nil structured_data gracefully" do
          @spec.update!(structured_data: nil)
          result = GetSpec.call({}, @context)

          assert_equal [], result[:metadata][:personas]
          assert_equal [], result[:metadata][:domains]
          assert_equal [], result[:metadata][:recipes]
        end

        test "call handles empty structured_data gracefully" do
          @spec.update!(structured_data: {})
          result = GetSpec.call({}, @context)

          assert_equal [], result[:metadata][:personas]
          assert_equal [], result[:metadata][:domains]
          assert_equal [], result[:metadata][:recipes]
        end
      end
    end
  end
end

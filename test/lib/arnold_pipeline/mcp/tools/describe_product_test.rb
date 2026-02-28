require "test_helper"
require "arnold_pipeline/mcp/context"
require "arnold_pipeline/mcp/tools/describe_product"

module ArnoldPipeline
  module Mcp
    module Tools
      class DescribeProductTest < ActiveSupport::TestCase
        cover "ArnoldPipeline::Mcp::Tools::DescribeProduct*"

        setup do
          @context = Context.new
          @run = PipelineRun.create!(nl_input: "Build a fitness tracking app")
          @spec = Specification.create!(
            pipeline_run: @run,
            content: "# Fitness Tracker\n\n## Purpose\nA fitness tracking application for health enthusiasts.\n\n## Requirements\n- Track workouts\n- Monitor nutrition",
            version: 1,
            structured_data: {
              "product_name" => "Fitness Tracker Pro",
              "summary" => "A comprehensive fitness tracking application",
              "personas" => [
                { "name" => "Athlete", "description" => "Active sports person", "capabilities" => [ "track workouts", "set goals" ] },
                { "name" => "Coach", "description" => "Fitness instructor", "capabilities" => [ "create plans" ] }
              ],
              "domains" => [
                { "name" => "Workouts", "description" => "Exercise tracking and logging" },
                { "name" => "Nutrition", "description" => "Diet and meal planning" }
              ]
            }
          )
        end

        teardown do
          ArnoldPipeline.reset_configuration!
        end

        test "tool_name returns describe_product" do
          assert_equal "describe_product", DescribeProduct.tool_name
        end

        test "description is present" do
          assert_kind_of String, DescribeProduct.description
          refute_empty DescribeProduct.description
        end

        test "input_schema returns valid schema" do
          schema = DescribeProduct.input_schema
          assert_equal "object", schema[:type]
          assert schema[:properties].key?(:run_id)
        end

        test "call returns product description for latest run" do
          result = DescribeProduct.call({}, @context)

          assert_equal "Fitness Tracker Pro", result[:product_name]
          assert_equal "A comprehensive fitness tracking application", result[:summary]
          assert_equal 2, result[:personas].length
          assert_equal 2, result[:domains].length
        end

        test "call returns product for specific run_id" do
          result = DescribeProduct.call({ "run_id" => @run.id.to_s }, @context)
          assert_equal "Fitness Tracker Pro", result[:product_name]
        end

        test "call returns personas with expected structure" do
          result = DescribeProduct.call({}, @context)
          athlete = result[:personas].find { |p| p[:name] == "Athlete" }

          assert_not_nil athlete
          assert_equal "Active sports person", athlete[:description]
          assert_includes athlete[:capabilities], "track workouts"
        end

        test "call returns domains with status" do
          Task.create!(pipeline_run: @run, title: "Implement workout tracking", position: 0,
                       status: :completed, labels: [ "workouts" ])
          Task.create!(pipeline_run: @run, title: "Build nutrition logger", position: 1,
                       status: :in_progress, labels: [ "nutrition" ])

          result = DescribeProduct.call({}, @context)

          workouts = result[:domains].find { |d| d[:name] == "Workouts" }
          nutrition = result[:domains].find { |d| d[:name] == "Nutrition" }

          assert_equal "complete", workouts[:status]
          assert_equal "in_progress", nutrition[:status]
        end

        test "call returns defined status when no tasks match domain" do
          result = DescribeProduct.call({}, @context)

          workouts = result[:domains].find { |d| d[:name] == "Workouts" }
          assert_equal "defined", workouts[:status]
        end

        test "call falls back to heading for product name when structured_data lacks it" do
          @spec.update!(structured_data: {})
          result = DescribeProduct.call({}, @context)
          assert_equal "Fitness Tracker", result[:product_name]
        end

        test "call falls back to nl_input when no heading or structured data" do
          @spec.update!(structured_data: {}, content: "No heading here\nJust content")
          result = DescribeProduct.call({}, @context)
          assert_includes result[:product_name], "Build a fitness tracking app"
        end

        test "call falls back to purpose section for summary" do
          @spec.update!(structured_data: {})
          result = DescribeProduct.call({}, @context)
          assert_includes result[:summary], "fitness tracking application"
        end

        test "call falls back to nl_input for summary when no purpose section" do
          @spec.update!(structured_data: {}, content: "Just content without purpose")
          result = DescribeProduct.call({}, @context)
          assert_includes result[:summary], "Build a fitness tracking app"
        end

        test "call returns error when no pipeline run found" do
          PipelineRun.destroy_all
          result = DescribeProduct.call({}, @context)
          assert_equal "No pipeline run found", result[:error]
        end

        test "call returns error when run has no specification" do
          run_no_spec = PipelineRun.create!(nl_input: "no spec yet")
          result = DescribeProduct.call({ "run_id" => run_no_spec.id.to_s }, @context)
          assert_includes result[:error], "No specification found"
        end

        test "call handles nil structured_data" do
          @spec.update!(structured_data: nil)
          result = DescribeProduct.call({}, @context)

          assert_kind_of String, result[:product_name]
          assert_kind_of String, result[:summary]
          assert_kind_of Array, result[:personas]
          assert_kind_of Array, result[:domains]
        end

        test "call extracts domains from task labels when structured_data has none" do
          @spec.update!(structured_data: {})
          Task.create!(pipeline_run: @run, title: "Setup auth", position: 0,
                       status: :completed, labels: [ "authentication" ])
          Task.create!(pipeline_run: @run, title: "Build API", position: 1,
                       status: :pending, labels: [ "backend" ])

          result = DescribeProduct.call({}, @context)

          domain_names = result[:domains].map { |d| d[:name] }
          assert_includes domain_names, "Authentication"
          assert_includes domain_names, "Backend"
        end

        test "call response has all expected keys" do
          result = DescribeProduct.call({}, @context)

          assert result.key?(:product_name)
          assert result.key?(:summary)
          assert result.key?(:personas)
          assert result.key?(:domains)
        end

        test "nil run_id falls back to latest run" do
          result = DescribeProduct.call({ "run_id" => nil }, @context)
          assert_equal "Fitness Tracker Pro", result[:product_name]
        end
      end
    end
  end
end

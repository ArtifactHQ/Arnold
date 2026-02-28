require "test_helper"
require "arnold_pipeline/mcp/context"
require "arnold_pipeline/mcp/tools/explore_domain"

module ArnoldPipeline
  module Mcp
    module Tools
      class ExploreDomainTest < ActiveSupport::TestCase
        cover "ArnoldPipeline::Mcp::Tools::ExploreDomain*"

        setup do
          @context = Context.new
          @run = PipelineRun.create!(nl_input: "Build a fitness tracking app")
          @spec = Specification.create!(
            pipeline_run: @run,
            content: "# Fitness Tracker\n\n## Workouts\nTrack exercises and routines.\n\n## Nutrition\nMonitor meals and calories.\n\nWorkouts and Nutrition are closely related for holistic fitness.",
            version: 1,
            structured_data: {
              "personas" => [
                { "name" => "Athlete", "description" => "Tracks workouts and nutrition" },
                { "name" => "Coach", "description" => "Creates training plans" }
              ],
              "domains" => [
                { "name" => "Workouts", "description" => "Exercise tracking and logging" },
                { "name" => "Nutrition", "description" => "Diet and meal planning" }
              ]
            }
          )
          @task1 = Task.create!(
            pipeline_run: @run, title: "Implement workout logging", position: 0,
            tier: 0, status: :completed, labels: [ "workouts" ],
            depends_on: []
          )
          @task2 = Task.create!(
            pipeline_run: @run, title: "Build nutrition tracker", position: 1,
            tier: 1, status: :in_progress, labels: [ "nutrition" ],
            depends_on: [ @task1.id.to_s ]
          )
        end

        teardown do
          ArnoldPipeline.reset_configuration!
        end

        test "tool_name returns explore_domain" do
          assert_equal "explore_domain", ExploreDomain.tool_name
        end

        test "description is present" do
          assert_kind_of String, ExploreDomain.description
          refute_empty ExploreDomain.description
        end

        test "input_schema requires domain" do
          schema = ExploreDomain.input_schema
          assert_equal "object", schema[:type]
          assert schema[:properties].key?(:domain)
          assert_includes schema[:required], "domain"
        end

        test "call returns domain details for exact match" do
          result = ExploreDomain.call({ "domain" => "Workouts" }, @context)

          assert_equal "Workouts", result[:domain]
          assert_equal "Exercise tracking and logging", result[:description]
        end

        test "call performs case-insensitive matching" do
          result = ExploreDomain.call({ "domain" => "workouts" }, @context)
          assert_equal "Workouts", result[:domain]
        end

        test "call performs partial matching" do
          result = ExploreDomain.call({ "domain" => "work" }, @context)
          assert_equal "Workouts", result[:domain]
        end

        test "call returns personas involved" do
          result = ExploreDomain.call({ "domain" => "Workouts" }, @context)
          assert_kind_of Array, result[:personas_involved]
          refute_empty result[:personas_involved]
        end

        test "call returns capabilities with status from tasks" do
          result = ExploreDomain.call({ "domain" => "Workouts" }, @context)

          assert_kind_of Array, result[:capabilities]
          workout_cap = result[:capabilities].find { |c| c[:description].include?("workout") }
          assert_not_nil workout_cap
          assert_equal "complete", workout_cap[:status]
        end

        test "call returns in_progress capability status" do
          result = ExploreDomain.call({ "domain" => "Nutrition" }, @context)

          nutrition_cap = result[:capabilities].find { |c| c[:description].include?("nutrition") }
          assert_not_nil nutrition_cap
          assert_equal "in_progress", nutrition_cap[:status]
        end

        test "call detects dependency relationships" do
          result = ExploreDomain.call({ "domain" => "Nutrition" }, @context)

          workout_rel = result[:relationships].find { |r| r[:domain] == "Workouts" }
          assert_not_nil workout_rel
          assert_equal "depends_on", workout_rel[:relationship]
        end

        test "call detects depended_on_by relationships" do
          result = ExploreDomain.call({ "domain" => "Workouts" }, @context)

          nutrition_rel = result[:relationships].find { |r| r[:domain] == "Nutrition" }
          assert_not_nil nutrition_rel
          assert_equal "depended_on_by", nutrition_rel[:relationship]
        end

        test "call returns error for unknown domain" do
          result = ExploreDomain.call({ "domain" => "nonexistent" }, @context)

          assert_equal "Domain 'nonexistent' not found", result[:error]
          assert_kind_of Array, result[:available_domains]
        end

        test "call returns available domains on not found" do
          result = ExploreDomain.call({ "domain" => "nonexistent" }, @context)
          assert_includes result[:available_domains], "Workouts"
          assert_includes result[:available_domains], "Nutrition"
        end

        test "call returns error when domain is empty" do
          result = ExploreDomain.call({ "domain" => "" }, @context)
          assert_equal "Domain name is required", result[:error]
        end

        test "call returns error when no pipeline run found" do
          PipelineRun.destroy_all
          result = ExploreDomain.call({ "domain" => "Workouts" }, @context)
          assert_equal "No pipeline run found", result[:error]
        end

        test "call returns error when no specification found" do
          run_no_spec = PipelineRun.create!(nl_input: "no spec")
          result = ExploreDomain.call({ "domain" => "Workouts", "run_id" => run_no_spec.id.to_s }, @context)
          assert_includes result[:error], "No specification found"
        end

        test "call returns specific run by run_id" do
          result = ExploreDomain.call({ "domain" => "Workouts", "run_id" => @run.id.to_s }, @context)
          assert_equal "Workouts", result[:domain]
        end

        test "nil run_id falls back to latest run" do
          result = ExploreDomain.call({ "domain" => "Workouts", "run_id" => nil }, @context)
          assert_equal "Workouts", result[:domain]
        end

        test "call response has all expected keys" do
          result = ExploreDomain.call({ "domain" => "Workouts" }, @context)

          assert result.key?(:domain)
          assert result.key?(:description)
          assert result.key?(:personas_involved)
          assert result.key?(:capabilities)
          assert result.key?(:relationships)
        end

        test "call detects related domains from co-occurring content" do
          # Workouts and Nutrition appear together in the spec content paragraph
          @task2.update!(depends_on: [])  # Remove dependency so "related" is the signal

          result = ExploreDomain.call({ "domain" => "Workouts" }, @context)

          nutrition_rel = result[:relationships].find { |r| r[:domain] == "Nutrition" }
          assert_not_nil nutrition_rel
          # Could be "depended_on_by" from tasks or "related" from content
          assert_includes %w[depended_on_by related], nutrition_rel[:relationship]
        end

        test "call falls back to spec content sections when no structured domains" do
          @spec.update!(structured_data: {})

          result = ExploreDomain.call({ "domain" => "Workouts" }, @context)
          assert_equal "Workouts", result[:domain]
          assert_includes result[:description], "Track exercises"
        end
      end
    end
  end
end

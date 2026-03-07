require "test_helper"
require "arnold_pipeline/library/manager"

module ArnoldPipeline
  module Library
    class RecipeContentTest < ActiveSupport::TestCase
      setup do
        @manager = Manager.new
        @recipes = @manager.all_recipes
      end

      test "every recipe has a non-empty verification block" do
        @recipes.each do |recipe|
          assert_kind_of Hash, recipe.verification, "#{recipe.name} verification should be a Hash"
          refute_empty recipe.verification, "#{recipe.name} should have a non-empty verification block"
        end
      end

      test "every recipe has at least one section with tier_placement final" do
        @recipes.each do |recipe|
          has_final = recipe.sections.any? { |s| s["tier_placement"] == "final" }
          assert has_final, "#{recipe.name} should have at least one section with tier_placement: final"
        end
      end

      test "every recipe has a Testing section" do
        @recipes.each do |recipe|
          has_testing = recipe.sections.any? { |s| s["name"] == "Testing" }
          assert has_testing, "#{recipe.name} should have a Testing section"
        end
      end

      test "every recipe has a Local Development section" do
        @recipes.each do |recipe|
          has_local_dev = recipe.sections.any? { |s| s["name"] == "Local Development" }
          assert has_local_dev, "#{recipe.name} should have a Local Development section"
        end
      end

      test "deployment-type sections have phase post_pipeline" do
        deployment_names = [
          "Deployment & Infrastructure",
          "Deployment & Operations",
          "Distribution & Packaging",
          "Configuration & Deployment",
          "Deployment",
          "Distribution"
        ]

        @recipes.each do |recipe|
          recipe.sections.each do |section|
            if deployment_names.include?(section["name"])
              assert_equal "post_pipeline", section["phase"],
                "#{recipe.name} section '#{section['name']}' should have phase: post_pipeline"
            end
          end
        end
      end

      test "every recipe has a non-empty finalization block with commands" do
        @recipes.each do |recipe|
          assert_kind_of Hash, recipe.finalization, "#{recipe.name} finalization should be a Hash"
          refute_empty recipe.finalization, "#{recipe.name} should have a non-empty finalization block"
          commands = recipe.finalization["commands"]
          assert_kind_of Array, commands, "#{recipe.name} finalization.commands should be an Array"
          refute_empty commands, "#{recipe.name} should have at least one finalization command"
          commands.each do |cmd|
            assert_kind_of String, cmd, "#{recipe.name} finalization commands should all be Strings"
          end
        end
      end

      test "web_app recipe has verification checks including solid_stack" do
        recipe = @recipes.find { |r| r.type == "web_app" }
        checks = recipe.verification.fetch("checks", [])
        solid_stack = checks.find { |c| c["type"] == "solid_stack" }
        assert_not_nil solid_stack, "web_app recipe should have solid_stack check"
        assert solid_stack["required"], "solid_stack should be required"
      end

      test "web_app recipe has finalization checks including boot" do
        recipe = @recipes.find { |r| r.type == "web_app" }
        checks = recipe.finalization.fetch("checks", [])
        boot = checks.find { |c| c["type"] == "custom" }
        assert_not_nil boot, "web_app recipe should have a finalization boot check"
      end

      test "cli_tool recipe has no verification checks" do
        recipe = @recipes.find { |r| r.type == "cli_tool" }
        checks = recipe.verification.fetch("checks", [])
        assert_empty checks, "cli_tool recipe should have no verification checks"
      end

      test "all recipes with solid_stack check mark it as required" do
        @recipes.each do |recipe|
          checks = recipe.verification.fetch("checks", [])
          solid_stack = checks.find { |c| c["type"] == "solid_stack" }
          next unless solid_stack
          assert solid_stack["required"], "#{recipe.type}: solid_stack check should be required"
        end
      end

      test "no section has an unrecognized phase value" do
        recognized_phases = [ nil, "pipeline", "post_pipeline" ]

        @recipes.each do |recipe|
          recipe.sections.each do |section|
            assert_includes recognized_phases, section["phase"],
              "#{recipe.name} section '#{section['name']}' has unrecognized phase: #{section['phase']}"
          end
        end
      end
    end
  end
end

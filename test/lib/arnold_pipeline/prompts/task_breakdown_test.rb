require "test_helper"
require "arnold_pipeline/prompts/task_breakdown"
require "arnold_pipeline/library/manager"

module ArnoldPipeline
  module Prompts
    class TaskBreakdownTest < ActiveSupport::TestCase
      setup do
        @manager = Library::Manager.new
        @recipe = @manager.find_recipe("Build a responsive web dashboard")
      end

      test "system_prompt includes base structure without recipe" do
        prompt = TaskBreakdown.system_prompt
        assert_includes prompt, "technical project manager"
        assert_includes prompt, "Expected Spec Structure"
        assert_includes prompt, "Output Format"
        assert_includes prompt, "position"
        assert_includes prompt, "depends_on"
      end

      test "system_prompt includes prescriptive task rules" do
        prompt = TaskBreakdown.system_prompt
        assert_includes prompt, "WRONG:"
        assert_includes prompt, "RIGHT:"
        assert_includes prompt, "specific tools, gems, generators"
        assert_includes prompt, "bootstrap task (position 0) MUST name"
      end

      test "system_prompt omits technology context when recipe is nil" do
        prompt = TaskBreakdown.system_prompt
        refute_includes prompt, "Technology Context"
        refute_includes prompt, "Framework stack:"
      end

      test "system_prompt includes technology context section with recipe" do
        prompt = TaskBreakdown.system_prompt(recipe: @recipe)
        assert_includes prompt, "# Technology Context"
        assert_includes prompt, "Recipe: #{@recipe.name}"
        assert_includes prompt, @recipe.type
      end

      test "system_prompt includes framework stack from recipe" do
        prompt = TaskBreakdown.system_prompt(recipe: @recipe)
        assert_includes prompt, "Framework stack:"
        assert_includes prompt, "Rails 8+"
      end

      test "system_prompt includes section tools from recipe" do
        prompt = TaskBreakdown.system_prompt(recipe: @recipe)
        assert_includes prompt, "Tools:"
        assert_includes prompt, "ActiveRecord (models, migrations, associations)"
      end

      test "system_prompt includes implementation guidance from recipe" do
        prompt = TaskBreakdown.system_prompt(recipe: @recipe)
        assert_includes prompt, "Implementation guidance:"
        assert_includes prompt, "Define all models with explicit validations"
      end

      test "system_prompt includes supporting recipes" do
        supporting = [@manager.find_recipe("Create a REST API with JSON endpoints")]
        prompt = TaskBreakdown.system_prompt(recipe: @recipe, supporting_recipes: supporting)
        assert_includes prompt, "Supporting recipes"
        assert_includes prompt, "API Service"
      end

      test "system_prompt omits supporting recipes when empty" do
        prompt = TaskBreakdown.system_prompt(recipe: @recipe, supporting_recipes: [])
        refute_includes prompt, "Supporting recipes"
      end

      test "system_prompt handles recipe with empty framework" do
        recipe = Library::Recipe.new(name: "Test", type: "test", keywords: [], description: "A test", framework: {}, sections: [], verification: {})
        prompt = TaskBreakdown.system_prompt(recipe: recipe)
        assert_includes prompt, "# Technology Context"
        assert_includes prompt, "Recipe: Test"
        refute_includes prompt, "Framework stack:"
      end

      test "system_prompt includes recipe description" do
        prompt = TaskBreakdown.system_prompt(recipe: @recipe)
        assert_includes prompt, @recipe.description.strip
      end

      test "system_prompt includes usage instruction for recipe tools" do
        prompt = TaskBreakdown.system_prompt(recipe: @recipe)
        assert_includes prompt, "Use these tools, gems, generators, and framework patterns"
      end

      test "system_prompt references OpenSpec requirement format" do
        prompt = TaskBreakdown.system_prompt
        assert_includes prompt, "### Requirement:"
        assert_includes prompt, "#### Scenario:"
        assert_includes prompt, "GIVEN/WHEN/THEN"
        assert_includes prompt, "[Area Name] > [Requirement Name]"
      end

      test "system_prompt renders tools key for cli recipe" do
        cli_recipe = @manager.find_recipe("Build a command line utility tool")
        prompt = TaskBreakdown.system_prompt(recipe: cli_recipe)
        assert_includes prompt, "Tools:"
        assert_includes prompt, "Thor (command DSL, argument parsing, help generation)"
      end

      test "system_prompt excludes post_pipeline sections" do
        recipe = Library::Recipe.new(
          name: "Test", type: "test", keywords: [], description: "A test",
          framework: {}, verification: {},
          sections: [
            { "name" => "Core", "description" => "Core stuff" },
            { "name" => "Deploy", "description" => "Deploy stuff", "phase" => "post_pipeline" }
          ]
        )
        prompt = TaskBreakdown.system_prompt(recipe: recipe)
        assert_includes prompt, "### Core"
        refute_includes prompt, "### Deploy"
      end

      test "system_prompt includes sections without phase key" do
        prompt = TaskBreakdown.system_prompt(recipe: @recipe)
        assert_includes prompt, "### Models & Database"
        assert_includes prompt, "### Controllers & Routing"
      end

      test "system_prompt renders tier_placement hint" do
        recipe = Library::Recipe.new(
          name: "Test", type: "test", keywords: [], description: "A test",
          framework: {}, verification: {},
          sections: [
            { "name" => "Testing", "description" => "Tests", "tier_placement" => "final" }
          ]
        )
        prompt = TaskBreakdown.system_prompt(recipe: recipe)
        assert_includes prompt, "Tier placement: final (tasks from this section should be placed in the final execution tier)"
      end

      test "system_prompt includes verification context" do
        prompt = TaskBreakdown.system_prompt(recipe: @recipe)
        assert_includes prompt, "## Verification"
        assert_includes prompt, "Setup: `bin/setup`"
        assert_includes prompt, "Run: `bin/dev`"
        assert_includes prompt, "Health check: `http://localhost:3000/up`"
      end

      test "system_prompt includes local execution requirements" do
        prompt = TaskBreakdown.system_prompt
        assert_includes prompt, "immediately runnable"
        assert_includes prompt, "SQLite for the development database"
        assert_includes prompt, "Solid Queue, Solid Cache, Solid Cable"
      end
    end
  end
end

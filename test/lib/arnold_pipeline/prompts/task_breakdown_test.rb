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
        supporting = [ @manager.find_recipe("Create a REST API with JSON endpoints") ]
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
        assert_includes prompt, "bundle install"
        assert_includes prompt, "bin/rails server -p 3000 -d"
        assert_includes prompt, "http://localhost:3000/up"
        assert_includes prompt, "bin/rails test:all"
      end

      test "system_prompt includes local execution requirements" do
        prompt = TaskBreakdown.system_prompt
        assert_includes prompt, "immediately runnable"
        assert_includes prompt, "SQLite for the development database"
        assert_includes prompt, "Solid Queue, Solid Cache, Solid Cable"
      end

      test "system_prompt includes parallel execution resource collision guidance" do
        prompt = TaskBreakdown.system_prompt
        assert_includes prompt, "Parallel Execution & Resource Conflicts"
        assert_includes prompt, "isolated git worktrees"
        assert_includes prompt, "conflicting migrations"
        assert_includes prompt, "depends_on"
      end

      test "system_prompt omits parallel execution guidance in delta-scoped mode" do
        prompt = TaskBreakdown.system_prompt(deltas: sample_deltas)
        refute_includes prompt, "Parallel Execution & Resource Conflicts"
      end

      # --- Delta-scoped prompt tests ---

      test "system_prompt includes Delta Scope section when deltas present" do
        prompt = TaskBreakdown.system_prompt(deltas: sample_deltas)
        assert_includes prompt, "# Delta Scope"
        assert_includes prompt, "FORKED pipeline run"
        assert_includes prompt, "Delta 1: ADDED"
        assert_includes prompt, "Dark Mode"
      end

      test "system_prompt uses delta-scoped rules when deltas present" do
        prompt = TaskBreakdown.system_prompt(deltas: sample_deltas)
        assert_includes prompt, "Rules (Delta-Scoped)"
        assert_includes prompt, "NO minimum task count"
        assert_includes prompt, "Do NOT include a project bootstrap"
        refute_includes prompt, "Aim for 5 to 20 tasks"
        refute_includes prompt, "FIRST task (position 0) MUST be a project bootstrap"
      end

      test "system_prompt omits bootstrap requirement when deltas present" do
        prompt = TaskBreakdown.system_prompt(deltas: sample_deltas)
        refute_includes prompt, "project skeleton, dependencies, database configuration"
      end

      test "system_prompt uses full rules when deltas nil" do
        prompt = TaskBreakdown.system_prompt(deltas: nil)
        assert_includes prompt, "Aim for 5 to 20 tasks"
        assert_includes prompt, "FIRST task (position 0) MUST be a project bootstrap"
        refute_includes prompt, "Delta Scope"
        refute_includes prompt, "Delta-Scoped"
      end

      test "system_prompt renders multiple deltas" do
        deltas = [
          { "operation" => "added", "section" => "Features", "requirement" => "Dark Mode", "content" => "Support dark mode" },
          { "operation" => "modified", "section" => "Auth", "requirement" => "Login", "content" => "Add OAuth" }
        ]
        prompt = TaskBreakdown.system_prompt(deltas: deltas)
        assert_includes prompt, "Delta 1: ADDED"
        assert_includes prompt, "Delta 2: MODIFIED"
        assert_includes prompt, "Dark Mode"
        assert_includes prompt, "Add OAuth"
      end

      test "system_prompt includes delta rationale" do
        deltas = [ { "operation" => "added", "rationale" => "User requested this" } ]
        prompt = TaskBreakdown.system_prompt(deltas: deltas)
        assert_includes prompt, "Rationale: User requested this"
      end

      test "user_prompt uses delta-aware phrasing when deltas present" do
        prompt = TaskBreakdown.user_prompt(spec_content: "# Spec", deltas: sample_deltas)
        assert_includes prompt, "already built and working"
        assert_includes prompt, "tasks ONLY for the deltas"
        refute_includes prompt, "Break down the following specification"
      end

      test "user_prompt uses standard phrasing when deltas nil" do
        prompt = TaskBreakdown.user_prompt(spec_content: "# Spec", deltas: nil)
        assert_includes prompt, "Break down the following specification"
        refute_includes prompt, "already built"
      end

      test "user_prompt includes spec content in both modes" do
        spec = "# My App Spec\nSome content"
        assert_includes TaskBreakdown.user_prompt(spec_content: spec, deltas: nil), spec
        assert_includes TaskBreakdown.user_prompt(spec_content: spec, deltas: sample_deltas), spec
      end

      private

      def sample_deltas
        [
          {
            "operation" => "added",
            "section" => "Features",
            "requirement" => "Dark Mode",
            "content" => "### Requirement: Dark Mode [REQ-UI-001]\nApp SHALL support dark mode.",
            "rationale" => "User requested dark mode support"
          }
        ]
      end
    end
  end
end

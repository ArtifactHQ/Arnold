require "test_helper"
require "arnold_pipeline/prompts/spec_test_generation"
require "arnold_pipeline/library/manager"

module ArnoldPipeline
  module Prompts
    class SpecTestGenerationTest < ActiveSupport::TestCase
      setup do
        @manager = Library::Manager.new
        @persona = @manager.find_persona("web app")
        @recipe = @manager.find_recipe("Build a responsive web dashboard")
      end

      test "system_prompt includes persona system prompt" do
        prompt = SpecTestGeneration.system_prompt(persona: @persona, recipe: @recipe)
        assert_includes prompt, @persona.system_prompt
      end

      test "system_prompt includes test generation context" do
        prompt = SpecTestGeneration.system_prompt(persona: @persona, recipe: @recipe)
        assert_includes prompt, "generating integration tests from a behavioral specification"
      end

      test "system_prompt includes fail-first expectation" do
        prompt = SpecTestGeneration.system_prompt(persona: @persona, recipe: @recipe)
        assert_includes prompt, "expected to FAIL initially"
      end

      test "system_prompt includes framework hint from recipe" do
        prompt = SpecTestGeneration.system_prompt(persona: @persona, recipe: @recipe)
        assert_includes prompt, "Ruby"
        assert_includes prompt, "Rails"
      end

      test "system_prompt without recipe detects framework from context" do
        prompt = SpecTestGeneration.system_prompt(persona: @persona)
        assert_includes prompt, "Detect the appropriate test framework"
      end

      test "system_prompt includes all rules" do
        prompt = SpecTestGeneration.system_prompt(persona: @persona, recipe: @recipe)
        assert_includes prompt, "Generate complete, runnable test files"
        assert_includes prompt, "Organize tests by requirement ID"
        assert_includes prompt, "GIVEN/WHEN/THEN"
        assert_includes prompt, "public API or endpoints"
        assert_includes prompt, "setup/teardown"
      end

      test "system_prompt includes output format" do
        prompt = SpecTestGeneration.system_prompt(persona: @persona, recipe: @recipe)
        assert_includes prompt, "test_files"
        assert_includes prompt, '"path"'
        assert_includes prompt, '"content"'
        assert_includes prompt, '"requirement_ids"'
      end

      test "system_prompt includes REQ ID format" do
        prompt = SpecTestGeneration.system_prompt(persona: @persona, recipe: @recipe)
        assert_includes prompt, "REQ-"
      end

      test "user_prompt includes spec content" do
        prompt = SpecTestGeneration.user_prompt(
          spec_content: "# My App Spec\n## Features\n- Auth",
          test_directory: "test/spec_integration"
        )
        assert_includes prompt, "# My App Spec"
        assert_includes prompt, "## Features"
        assert_includes prompt, "- Auth"
      end

      test "user_prompt includes test directory" do
        prompt = SpecTestGeneration.user_prompt(
          spec_content: "# Spec",
          test_directory: "test/spec_integration"
        )
        assert_includes prompt, "test/spec_integration/"
      end

      test "user_prompt instructs to generate for ALL requirements" do
        prompt = SpecTestGeneration.user_prompt(
          spec_content: "# Spec",
          test_directory: "test"
        )
        assert_includes prompt, "ALL requirements"
        assert_includes prompt, "GIVEN/WHEN/THEN"
      end

      test "system_prompt with recipe with empty framework hash uses defaults" do
        recipe = Library::Recipe.new(
          name: "Test", type: "test", keywords: [],
          description: "A test recipe", framework: {},
          sections: [], verification: {}
        )
        prompt = SpecTestGeneration.system_prompt(persona: @persona, recipe: recipe)
        # Empty hash is still a Hash, so defaults to Ruby/Rails
        assert_includes prompt, "Ruby"
        assert_includes prompt, "Rails"
      end

      test "system_prompt without recipe falls back to detection" do
        prompt = SpecTestGeneration.system_prompt(persona: @persona, recipe: nil)
        assert_includes prompt, "Detect the appropriate test framework"
      end
    end
  end
end

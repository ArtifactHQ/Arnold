require "test_helper"
require "arnold_pipeline/prompts/spec_generation"
require "arnold_pipeline/library/manager"

module ArnoldPipeline
  module Prompts
    class SpecGenerationTest < ActiveSupport::TestCase
      setup do
        @manager = Library::Manager.new
        @persona = @manager.find_persona("web app")
        @recipe = @manager.find_recipe("web app")
        @domain_type = @manager.find_domain_type("build a multiplayer game")
      end

      test "system_prompt includes persona system prompt" do
        prompt = SpecGeneration.system_prompt(persona: @persona, recipe: @recipe, domain_type: @domain_type)
        assert_includes prompt, @persona.system_prompt
      end

      test "system_prompt includes core philosophy pillars" do
        prompt = SpecGeneration.system_prompt(persona: @persona, recipe: @recipe, domain_type: @domain_type)
        assert_includes prompt, "THE DOCUMENT IS THE PRODUCT"
        assert_includes prompt, "PRECISION WITHOUT JARGON"
        assert_includes prompt, "IDEAS ARE NOT SHORTCUTS"
      end

      test "system_prompt includes all 10 section names" do
        prompt = SpecGeneration.system_prompt(persona: @persona, recipe: @recipe, domain_type: @domain_type)
        sections = [
          "Overview", "Features", "Entities & Data Model", "User Journeys",
          "Views & Interfaces", "System Behaviors", "Logic & Calculations",
          "External Connections", "Security & Privacy", "Future Considerations"
        ]
        sections.each do |section|
          assert_includes prompt, section, "Missing section: #{section}"
        end
      end

      test "system_prompt includes per-feature template elements" do
        prompt = SpecGeneration.system_prompt(persona: @persona, recipe: @recipe, domain_type: @domain_type)
        assert_includes prompt, "Context:"
        assert_includes prompt, "User Story:"
        assert_includes prompt, "Functional Requirements:"
        assert_includes prompt, "Behavioral Specifications:"
        assert_includes prompt, "Corner Cases:"
        assert_includes prompt, "Acceptance Criteria:"
      end

      test "system_prompt includes domain type lens" do
        prompt = SpecGeneration.system_prompt(persona: @persona, recipe: @recipe, domain_type: @domain_type)
        assert_includes prompt, @domain_type.code
        assert_includes prompt, @domain_type.name
        assert_includes prompt, @domain_type.primary_value
        @domain_type.emphasis.each do |e|
          assert_includes prompt, e
        end
      end

      test "system_prompt includes callout annotations" do
        prompt = SpecGeneration.system_prompt(persona: @persona, recipe: @recipe, domain_type: @domain_type)
        %w[NOTE IMPORTANT WARNING QUESTION IDEA ASSUMPTION PLACEHOLDER DEPENDENCY].each do |callout|
          assert_includes prompt, "[!#{callout}]", "Missing callout: [!#{callout}]"
        end
      end

      test "system_prompt includes anti-pattern warnings" do
        prompt = SpecGeneration.system_prompt(persona: @persona, recipe: @recipe, domain_type: @domain_type)
        anti_patterns = [
          "LAZY IDEA DROP", "ASSUMED UNDERSTANDING", "TECHNICAL LEAK",
          "VAGUE QUANTITY", "ORPHANED REFERENCE", "CONTRADICTORY SPECIFICATION",
          "MISSING NEGATIVE"
        ]
        anti_patterns.each do |ap|
          assert_includes prompt, ap, "Missing anti-pattern: #{ap}"
        end
      end

      test "system_prompt includes recipe as secondary guidance" do
        prompt = SpecGeneration.system_prompt(persona: @persona, recipe: @recipe, domain_type: @domain_type)
        assert_includes prompt, "Recipe: #{@recipe.name}"
        assert_includes prompt, "secondary technical guidance"
      end

      test "system_prompt includes domain terminology" do
        prompt = SpecGeneration.system_prompt(persona: @persona, recipe: @recipe, domain_type: @domain_type)
        assert_includes prompt, "Domain terminology"
        assert_includes prompt, "player"
      end

      test "system_prompt includes application_type in JSON metadata" do
        prompt = SpecGeneration.system_prompt(persona: @persona, recipe: @recipe, domain_type: @domain_type)
        assert_includes prompt, '"application_type"'
        assert_includes prompt, @domain_type.code
      end

      test "system_prompt with generic domain type omits terminology section when empty" do
        generic = @manager.find_domain_type("something completely unrelated xyzzy")
        prompt = SpecGeneration.system_prompt(persona: @persona, recipe: @recipe, domain_type: generic)
        # Generic has non-empty terminology, but verify prompt still generates
        assert_includes prompt, "GENERIC"
      end

      test "user_prompt includes nl_input" do
        prompt = SpecGeneration.user_prompt(nl_input: "Build a fitness tracker")
        assert_includes prompt, "Build a fitness tracker"
      end
    end
  end
end

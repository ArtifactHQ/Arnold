require "test_helper"
require "arnold_pipeline/services/claude_md_generator"
require "arnold_pipeline/library/persona"
require "arnold_pipeline/library/recipe"
require "arnold_pipeline/library/domain_type"

module ArnoldPipeline
  module Services
    class ClaudeMdGeneratorTest < ActiveSupport::TestCase
      setup do
        @recipe = ArnoldPipeline::Library::Recipe.new(
          name: "Web App", type: "web_app", keywords: [],
          description: "Full-stack web application",
          framework: { "primary" => "Rails 8+", "frontend" => "Hotwire", "css" => "Tailwind CSS" },
          sections: [
            { "name" => "Local Development", "phase" => "pipeline",
              "guidance" => ["Use bin/dev to start", "SQLite for development"] }
          ],
          verification: {
            "test_command" => "bin/rails test:all",
            "setup_commands" => ["bundle install", "bin/rails db:prepare"],
            "boot_command" => "bin/rails server -p 3000 -d",
            "health_checks" => [{ "url" => "http://localhost:3000/up", "expected_status" => 200 }]
          }
        )

        @domain_type = ArnoldPipeline::Library::DomainType.new(
          code: "GAME", name: "Game / Interactive Entertainment",
          keywords: [], description: "Game apps",
          primary_value: "Fun, engagement",
          emphasis: ["Progression systems", "Difficulty curves"],
          document_focus: ["Win/loss conditions"],
          watch_for: ["Game balance"],
          terminology: { "user" => "player", "account" => "profile" }
        )

        @persona = ArnoldPipeline::Library::Persona.new(
          name: "Software Architect", role: "system_design",
          keywords: [], description: "Designs architectures",
          system_prompt: "You are a Software Architect"
        )
      end

      test "call returns a string" do
        result = ClaudeMdGenerator.call(persona: @persona, recipe: @recipe, domain_type: @domain_type)
        assert_kind_of String, result
      end

      test "includes tech stack from recipe framework" do
        result = ClaudeMdGenerator.call(persona: @persona, recipe: @recipe, domain_type: @domain_type)
        assert_includes result, "Rails 8+"
        assert_includes result, "Hotwire"
        assert_includes result, "Tailwind CSS"
      end

      test "includes conventions from recipe sections guidance" do
        result = ClaudeMdGenerator.call(persona: @persona, recipe: @recipe, domain_type: @domain_type)
        assert_includes result, "Use bin/dev to start"
        assert_includes result, "SQLite for development"
      end

      test "includes testing from recipe verification" do
        result = ClaudeMdGenerator.call(persona: @persona, recipe: @recipe, domain_type: @domain_type)
        assert_includes result, "bin/rails test:all"
        assert_includes result, "bundle install"
      end

      test "includes domain context" do
        result = ClaudeMdGenerator.call(persona: @persona, recipe: @recipe, domain_type: @domain_type)
        assert_includes result, "Game / Interactive Entertainment"
        assert_includes result, "Progression systems"
      end

      test "includes terminology mappings" do
        result = ClaudeMdGenerator.call(persona: @persona, recipe: @recipe, domain_type: @domain_type)
        assert_includes result, "player"
        assert_includes result, "profile"
      end

      test "includes watch_for items" do
        result = ClaudeMdGenerator.call(persona: @persona, recipe: @recipe, domain_type: @domain_type)
        assert_includes result, "Game balance"
      end

      test "handles nil persona gracefully" do
        result = ClaudeMdGenerator.call(persona: nil, recipe: @recipe, domain_type: @domain_type)
        assert_kind_of String, result
      end

      test "handles nil recipe gracefully" do
        result = ClaudeMdGenerator.call(persona: @persona, recipe: nil, domain_type: @domain_type)
        assert_kind_of String, result
        refute_includes result, "Tech Stack"
      end

      test "handles nil domain_type gracefully" do
        result = ClaudeMdGenerator.call(persona: @persona, recipe: @recipe, domain_type: nil)
        assert_kind_of String, result
        refute_includes result, "Domain Context"
      end

      test "handles all-nil inputs" do
        result = ClaudeMdGenerator.call(persona: nil, recipe: nil, domain_type: nil)
        assert_kind_of String, result
        assert_includes result, "# Project Instructions"
      end

      test "omits empty sections" do
        empty_recipe = ArnoldPipeline::Library::Recipe.new(
          name: "Generic", type: "generic", keywords: [],
          description: "Generic", framework: {},
          sections: [], verification: {}
        )
        result = ClaudeMdGenerator.call(persona: @persona, recipe: empty_recipe, domain_type: @domain_type)
        refute_includes result, "## Tech Stack"
        refute_includes result, "## Conventions"
      end
    end
  end
end

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
              "guidance" => [ "Use bin/dev to start", "SQLite for development" ] }
          ],
          verification: {
            "test_command" => "bin/rails test:all",
            "setup_commands" => [ "bundle install", "bin/rails db:prepare" ],
            "boot_command" => "bin/rails server -p 3000 -d",
            "health_checks" => [ { "url" => "http://localhost:3000/up", "expected_status" => 200 } ]
          }
        )

        @domain_type = ArnoldPipeline::Library::DomainType.new(
          code: "GAME", name: "Game / Interactive Entertainment",
          keywords: [], description: "Game apps",
          primary_value: "Fun, engagement",
          emphasis: [ "Progression systems", "Difficulty curves" ],
          document_focus: [ "Win/loss conditions" ],
          watch_for: [ "Game balance" ],
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

      test "includes schema section when repo_path has db/schema.rb" do
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, "db"))
          File.write(File.join(dir, "db", "schema.rb"), <<~SCHEMA)
            ActiveRecord::Schema[8.0].define(version: 2026_02_21) do
              enable_extension "plpgsql"

              create_table "users", force: :cascade do |t|
                t.string "email", null: false
                t.string "name"
                t.timestamps
              end

              create_table "posts", force: :cascade do |t|
                t.references "user", null: false
                t.string "title"
                t.timestamps
              end
            end
          SCHEMA

          result = ClaudeMdGenerator.call(
            persona: @persona, recipe: @recipe, domain_type: @domain_type,
            repo_path: dir
          )
          assert_includes result, "## Current Database Schema"
          assert_includes result, "create_table \"users\""
          assert_includes result, "create_table \"posts\""
          refute_includes result, "enable_extension"
          refute_includes result, "ActiveRecord::Schema"
        end
      end

      test "includes routes section when repo_path has config/routes.rb" do
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, "config"))
          File.write(File.join(dir, "config", "routes.rb"), <<~ROUTES)
            Rails.application.routes.draw do
              resources :users
              resources :posts
              root "pages#home"
            end
          ROUTES

          result = ClaudeMdGenerator.call(
            persona: @persona, recipe: @recipe, domain_type: @domain_type,
            repo_path: dir
          )
          assert_includes result, "## Current Routes"
          assert_includes result, "resources :users"
          assert_includes result, "root \"pages#home\""
        end
      end

      test "includes Gemfile section when repo_path has Gemfile" do
        Dir.mktmpdir do |dir|
          File.write(File.join(dir, "Gemfile"), <<~GEMFILE)
            source "https://rubygems.org"

            # Rails framework
            gem "rails", "~> 8.0"
            gem "sqlite3"

            # Authentication
            gem "bcrypt", "~> 3.1.7"
          GEMFILE

          result = ClaudeMdGenerator.call(
            persona: @persona, recipe: @recipe, domain_type: @domain_type,
            repo_path: dir
          )
          assert_includes result, "## Current Gemfile"
          assert_includes result, 'gem "rails"'
          assert_includes result, 'gem "bcrypt"'
          refute_includes result, "# Rails framework"
          refute_includes result, "# Authentication"
        end
      end

      test "includes migration guidance when schema.rb has tables" do
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, "db"))
          File.write(File.join(dir, "db", "schema.rb"), <<~SCHEMA)
            ActiveRecord::Schema[8.0].define(version: 2026_02_21) do
              create_table "users", force: :cascade do |t|
                t.string "email"
                t.timestamps
              end

              create_table "posts", force: :cascade do |t|
                t.string "title"
                t.timestamps
              end
            end
          SCHEMA

          result = ClaudeMdGenerator.call(
            persona: @persona, recipe: @recipe, domain_type: @domain_type,
            repo_path: dir
          )
          assert_includes result, "## Migration Rules"
          assert_includes result, "- `users`"
          assert_includes result, "- `posts`"
          assert_includes result, "DO NOT"
        end
      end

      test "omits migration guidance when schema.rb is absent" do
        Dir.mktmpdir do |dir|
          result = ClaudeMdGenerator.call(
            persona: @persona, recipe: @recipe, domain_type: @domain_type,
            repo_path: dir
          )
          refute_includes result, "Migration Rules"
        end
      end

      test "omits migration guidance when schema.rb has no tables" do
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, "db"))
          File.write(File.join(dir, "db", "schema.rb"), <<~SCHEMA)
            ActiveRecord::Schema[8.0].define(version: 2026_02_21) do
              enable_extension "plpgsql"
            end
          SCHEMA

          result = ClaudeMdGenerator.call(
            persona: @persona, recipe: @recipe, domain_type: @domain_type,
            repo_path: dir
          )
          refute_includes result, "Migration Rules"
        end
      end

      test "omits migration guidance when repo_path is nil" do
        result = ClaudeMdGenerator.call(
          persona: @persona, recipe: @recipe, domain_type: @domain_type,
          repo_path: nil
        )
        refute_includes result, "Migration Rules"
      end

      test "omits project state sections when repo_path is nil" do
        result = ClaudeMdGenerator.call(
          persona: @persona, recipe: @recipe, domain_type: @domain_type,
          repo_path: nil
        )
        refute_includes result, "Current Database Schema"
        refute_includes result, "Current Routes"
        refute_includes result, "Current Gemfile"
      end

      test "omits missing files gracefully" do
        Dir.mktmpdir do |dir|
          result = ClaudeMdGenerator.call(
            persona: @persona, recipe: @recipe, domain_type: @domain_type,
            repo_path: dir
          )
          refute_includes result, "Current Database Schema"
          refute_includes result, "Current Routes"
          refute_includes result, "Current Gemfile"
        end
      end

      test "schema truncation strips indexes and version info" do
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, "db"))
          File.write(File.join(dir, "db", "schema.rb"), <<~SCHEMA)
            ActiveRecord::Schema[8.0].define(version: 2026_02_21) do
              enable_extension "plpgsql"

              create_table "users", force: :cascade do |t|
                t.string "email"
                t.index ["email"], name: "index_users_on_email", unique: true
                t.timestamps
              end
            end
          SCHEMA

          result = ClaudeMdGenerator.call(
            persona: @persona, recipe: @recipe, domain_type: @domain_type,
            repo_path: dir
          )
          assert_includes result, "create_table \"users\""
          assert_includes result, "t.string \"email\""
          refute_includes result, "t.index"
        end
      end
    end
  end
end

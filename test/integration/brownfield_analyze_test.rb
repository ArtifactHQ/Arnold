require "test_helper"
require "arnold_pipeline/orchestrator"
require "tmpdir"

module ArnoldPipeline
  class BrownfieldAnalyzeIntegrationTest < ActiveSupport::TestCase
    setup do
      ArnoldPipeline.reset_configuration!
      ArnoldPipeline.configure do |c|
        c.brownfield_scan_budget = 100_000
        c.health_baseline_timeout = 10
      end

      @fixture_path = create_rails_fixture
    end

    teardown do
      ArnoldPipeline.reset_configuration!
      FileUtils.rm_rf(@fixture_path) if @fixture_path
    end

    test "full analyze_codebase! flow with parallel agents" do
      null_logger = Logger.new(IO::NULL)

      # Single shared LLM mock — all agents created by orchestrator use default Providers::Llm.build
      llm = mock("llm")
      Providers::Llm.stubs(:build).returns(llm)

      infra_result = {
        "conventions" => {
          "naming_conventions" => "snake_case",
          "architecture_pattern" => "MVC",
          "test_framework" => "minitest",
          "code_style" => "standard ruby",
          "dependency_management" => "bundler",
          "error_handling" => "rescue blocks",
          "configuration_approach" => "Rails credentials"
        },
        "infrastructure" => [
          { "area" => "web_server", "description" => "Puma", "status" => "configured", "files" => [] }
        ],
        "concerns" => [
          { "concern_id" => "auth", "status" => "present", "implementation" => "has_secure_password", "files" => [ "app/models/user.rb" ], "notes" => "Built-in Rails auth" },
          { "concern_id" => "data_layer", "status" => "present", "implementation" => "active_record", "files" => [ "db/schema.rb" ], "notes" => "Standard AR" },
          { "concern_id" => "api_layer", "status" => "present", "implementation" => "rails_controllers", "files" => [ "config/routes.rb" ], "notes" => "RESTful" }
        ]
      }

      data_result = {
        "entities" => [
          { "name" => "User", "table" => "users", "file" => "app/models/user.rb",
            "attributes" => [ { "name" => "email", "type" => "string" } ],
            "associations" => [], "validations" => [], "callbacks" => [],
            "scopes" => [], "business_methods" => [], "status" => "implemented" }
        ],
        "relationships" => []
      }

      biz_result = { "services" => [] }

      ctrl_result = {
        "endpoints" => [
          { "verb" => "GET", "path" => "/", "controller" => "HomeController", "action" => "index",
            "description" => "Landing page", "access_control" => "public",
            "side_effects" => [], "error_handling" => "default",
            "input_params" => [], "output_format" => "html", "status" => "implemented" }
        ]
      }

      view_result = { "pages" => [] }

      # Use stubs (not expects) since thread execution order is non-deterministic
      llm.stubs(:chat_json).returns(infra_result)
      llm.stubs(:chat_json).returns(infra_result, data_result, biz_result, ctrl_result, view_result)

      spec_content = "# Test App — As-Built Specification\n\n## Purpose\nA test app.\n\n```json\n{\"project_name\": \"Test App\", \"total_features\": 1}\n```"
      llm.stubs(:chat).returns(spec_content)

      Brownfield::TestNameCollector.stubs(:call).returns(
        { test_names: [], grouped_by_concern: {}, framework: nil }
      )

      # Build orchestrator — Providers::Llm.build already stubbed above
      orchestrator = Orchestrator.new(logger: null_logger)

      profile = orchestrator.analyze_codebase!(
        repo_path: @fixture_path,
        description: "A sample Rails app"
      )

      # Assertions
      assert profile.is_a?(CodebaseProfile)
      assert profile.persisted?
      assert_equal "ruby", profile.stack_language
      assert_equal "rails", profile.stack_framework
      assert profile.confidence >= 50
      assert profile.analyzed_at.present?

      # Pipeline run should be completed
      run = profile.pipeline_run
      assert_equal "completed", run.status

      # Specification should exist with as_built type
      spec = run.specification
      assert spec.present?
      assert_equal "as_built", spec.spec_type

      # Feature inventories stored as agent outputs
      assert profile.feature_inventories.is_a?(Array)
      agent_names = profile.feature_inventories.map { |i| i["agent"] }
      assert_includes agent_names, "infrastructure"

      # Events should be recorded
      events = run.pipeline_events
      brownfield_events = events.select { |e| e.stage == "brownfield" }
      assert brownfield_events.size >= 6 # stack_detection, file_manifest, route_table, git_activity, test_names, parallel_agents, as_built_spec, health_baseline
    end

    private

    def create_rails_fixture
      dir = Dir.mktmpdir("brownfield_test_")

      FileUtils.mkdir_p(File.join(dir, "app/models"))
      FileUtils.mkdir_p(File.join(dir, "app/controllers"))
      FileUtils.mkdir_p(File.join(dir, "config"))
      FileUtils.mkdir_p(File.join(dir, "db/migrate"))
      FileUtils.mkdir_p(File.join(dir, "bin"))
      FileUtils.mkdir_p(File.join(dir, "test"))

      File.write(File.join(dir, "Gemfile"), "source 'https://rubygems.org'\ngem 'rails', '~> 8.0'")
      File.write(File.join(dir, "config/application.rb"), "module TestApp; class Application < Rails::Application; end; end")
      File.write(File.join(dir, "config/routes.rb"), "Rails.application.routes.draw { root to: 'home#index' }")
      File.write(File.join(dir, "config/database.yml"), "development:\n  adapter: sqlite3\n  database: db/development.sqlite3")
      File.write(File.join(dir, "db/schema.rb"), "ActiveRecord::Schema.define(version: 2024_01_01) { create_table(:users) { |t| t.string :email } }")
      File.write(File.join(dir, "bin/rails"), "#!/usr/bin/env ruby")
      File.write(File.join(dir, "Rakefile"), "require_relative 'config/application'")
      File.write(File.join(dir, "app/models/user.rb"), "class User < ApplicationRecord; has_secure_password; end")

      Open3.capture3("git init && git config user.email 'test@test.com' && git config user.name 'Test' && git add -A && git commit -m 'init'", chdir: dir)

      dir
    end
  end
end

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

    test "full analyze_codebase! flow with stubbed LLM" do
      llm = mock("llm")

      # Concern mapping response
      concern_json = JSON.generate({
        concerns: {
          auth: { status: "present", implementation: "has_secure_password", files: ["app/models/user.rb"], notes: "Built-in Rails auth" },
          data_layer: { status: "present", implementation: "active_record", files: ["db/schema.rb"], notes: "Standard AR" },
          api_layer: { status: "present", implementation: "rails_controllers", files: ["config/routes.rb"], notes: "RESTful" },
          background_jobs: { status: "absent" },
          realtime: { status: "absent" },
          testing: { status: "partial", implementation: "minitest", files: ["test/"], notes: "Some tests" },
          deployment: { status: "absent" }
        }
      })

      # Convention extraction response
      convention_json = JSON.generate({
        naming_conventions: "snake_case",
        architecture_pattern: "MVC",
        test_framework: "minitest",
        code_style: "standard ruby",
        dependency_management: "bundler",
        error_handling: "rescue blocks",
        configuration_approach: "Rails credentials"
      })

      # Feature extraction response
      feature_json = JSON.generate({
        concern_id: "auth",
        features: [
          { name: "User Registration", description: "Users can sign up", status: "implemented", files: ["app/models/user.rb"], dependencies: [] }
        ]
      })

      # As-built spec response
      spec_content = "# Test App — As-Built Specification\n\n## Purpose\nA test app.\n\n```json\n{\"project_name\": \"Test App\", \"total_features\": 1}\n```"

      # LLM calls: concern_mapping, convention_extraction, change_surface (description provided), then feature extraction per present concern, then as-built spec
      llm.stubs(:chat).returns(concern_json, convention_json, concern_json, feature_json, feature_json, feature_json, spec_content)

      null_logger = Logger.new(IO::NULL)

      # Stub the LLM agents
      brownfield_analyzer = Agents::BrownfieldAnalyzer.new(llm:, logger: null_logger)
      feature_extractor = Agents::FeatureExtractor.new(llm:, logger: null_logger)
      as_built_agent = Agents::AsBuiltSpec.new(llm:, logger: null_logger)

      # Build orchestrator with stubbed LLM to avoid API key requirement
      orchestrator = Orchestrator.new(
        spec_generator: Agents::SpecGenerator.new(llm:, logger: null_logger),
        task_breaker: Agents::TaskBreaker.new(llm:, logger: null_logger),
        analyzer: Agents::Analyzer.new(llm:, logger: null_logger),
        tier_gate_check: Agents::TierGateCheck.new(llm:, logger: null_logger),
        spec_iterator: Agents::SpecIterator.new(llm:, logger: null_logger),
        logger: null_logger
      )

      Agents::BrownfieldAnalyzer.stubs(:new).returns(brownfield_analyzer)
      Agents::FeatureExtractor.stubs(:new).returns(feature_extractor)
      Agents::AsBuiltSpec.stubs(:new).returns(as_built_agent)

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

      # Events should be recorded
      events = run.pipeline_events
      brownfield_events = events.select { |e| e.stage == "brownfield" }
      assert brownfield_events.size >= 4 # stack_detection, codebase_profiling, feature_extraction, as_built_spec_generated, health_baseline
    end

    private

    def create_rails_fixture
      dir = Dir.mktmpdir("brownfield_test_")

      # Create Rails-like structure
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

      # Init git repo for git_status check
      Open3.capture3("git init && git config user.email 'test@test.com' && git config user.name 'Test' && git add -A && git commit -m 'init'", chdir: dir)

      dir
    end
  end
end

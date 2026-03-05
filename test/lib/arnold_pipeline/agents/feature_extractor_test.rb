require "test_helper"
require "arnold_pipeline/agents/feature_extractor"

module ArnoldPipeline
  module Agents
    class FeatureExtractorTest < ActiveSupport::TestCase
      setup do
        @llm = mock("llm")
        @agent = FeatureExtractor.new(llm: @llm)
        @stack_fingerprint = { language: "ruby", framework: "rails" }
        @artifacts = [
          { role: "schema", path: "db/schema.rb", content: "create_table :users", format: "ruby" }
        ]
        ArnoldPipeline.configure { |c| c.brownfield_scan_budget = 100_000 }
      end

      teardown do
        ArnoldPipeline.reset_configuration!
      end

      test "extracts features for present concerns" do
        recipe_alignment = {
          "concerns" => {
            "auth" => { "status" => "present", "implementation" => "devise", "files" => ["db/schema.rb"] },
            "realtime" => { "status" => "absent" }
          }
        }

        feature_json = '{"concern_id": "auth", "features": [{"name": "Login", "description": "User login", "status": "implemented", "files": ["app/models/user.rb"], "dependencies": []}]}'
        @llm.expects(:chat).once.returns(feature_json)

        result = @agent.call(
          recipe_alignment:,
          artifacts: @artifacts,
          stack_fingerprint: @stack_fingerprint
        )

        assert_equal 1, result.size
        assert_equal "auth", result.first["concern_id"]
        assert_equal "Login", result.first["features"].first["name"]
      end

      test "skips absent concerns" do
        recipe_alignment = {
          "concerns" => {
            "realtime" => { "status" => "absent" }
          }
        }

        @llm.expects(:chat).never

        result = @agent.call(
          recipe_alignment:,
          artifacts: @artifacts,
          stack_fingerprint: @stack_fingerprint
        )

        assert_empty result
      end

      test "respects deep_dive_domains filter" do
        ArnoldPipeline.configure { |c| c.brownfield_deep_dive_domains = ["auth"] }

        recipe_alignment = {
          "concerns" => {
            "auth" => { "status" => "present", "files" => ["db/schema.rb"] },
            "data_layer" => { "status" => "present", "files" => ["db/schema.rb"] }
          }
        }

        feature_json = '{"concern_id": "auth", "features": []}'
        @llm.expects(:chat).once.returns(feature_json)

        result = @agent.call(
          recipe_alignment:,
          artifacts: @artifacts,
          stack_fingerprint: @stack_fingerprint
        )

        assert_equal 1, result.size
        assert_equal "auth", result.first["concern_id"]
      end

      test "skips concerns with no resolvable files" do
        recipe_alignment = {
          "concerns" => {
            "auth" => { "status" => "present", "files" => ["nonexistent/file.rb"] }
          }
        }

        @llm.expects(:chat).never

        result = @agent.call(
          recipe_alignment:,
          artifacts: @artifacts,
          stack_fingerprint: @stack_fingerprint
        )

        assert_empty result
      end

      test "passes reference_materials through to prompt" do
        recipe_alignment = {
          "concerns" => {
            "auth" => { "status" => "present", "implementation" => "devise", "files" => ["db/schema.rb"] }
          }
        }

        reference_materials = [
          { path: "docs/FEATURES.md", content: "# Features\n\nUser login with SSO support" }
        ]

        feature_json = '{"concern_id": "auth", "features": [{"name": "Login", "description": "User login", "status": "implemented", "files": ["app/models/user.rb"], "dependencies": []}]}'
        @llm.expects(:chat).once.with { |messages:, **| messages.first[:content].include?("Reference Documentation") }.returns(feature_json)

        result = @agent.call(
          recipe_alignment:,
          artifacts: @artifacts,
          stack_fingerprint: @stack_fingerprint,
          reference_materials:
        )

        assert_equal 1, result.size
      end

      test "works without reference_materials (backward compatible)" do
        recipe_alignment = {
          "concerns" => {
            "auth" => { "status" => "present", "files" => ["db/schema.rb"] }
          }
        }

        feature_json = '{"concern_id": "auth", "features": []}'
        @llm.expects(:chat).once.with { |messages:, **| !messages.first[:content].include?("Reference Documentation") }.returns(feature_json)

        result = @agent.call(
          recipe_alignment:,
          artifacts: @artifacts,
          stack_fingerprint: @stack_fingerprint
        )

        assert_equal 1, result.size
      end
    end
  end
end

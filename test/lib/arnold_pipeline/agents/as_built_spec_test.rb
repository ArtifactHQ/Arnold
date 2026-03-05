require "test_helper"
require "arnold_pipeline/agents/as_built_spec"

module ArnoldPipeline
  module Agents
    class AsBuiltSpecTest < ActiveSupport::TestCase
      setup do
        @llm = mock("llm")
        @agent = AsBuiltSpec.new(llm: @llm)
      end

      test "generates as-built spec from feature inventories" do
        inventories = [
          {
            "concern_id" => "auth",
            "features" => [
              { "name" => "Login", "description" => "User login via email/password", "status" => "implemented", "files" => ["app/models/user.rb"], "dependencies" => [] }
            ]
          }
        ]

        spec_content = <<~MARKDOWN
          # MyApp — As-Built Specification

          ## Purpose
          A web application with user authentication.

          ## Requirements

          ### Requirement: User Login [EXISTING] [REQ-AUTH-001]
          [IMPLEMENTED] The system SHALL allow users to log in via email and password.

          #### Scenario: Successful Login
          - GIVEN a registered user
          - WHEN they submit valid credentials
          - THEN they are logged in

          ```json
          {"project_name": "MyApp", "total_features": 1, "implemented": 1, "partial": 0, "stubbed": 0}
          ```
        MARKDOWN

        @llm.expects(:chat).once.returns(spec_content)

        result = @agent.call(
          feature_inventories: inventories,
          stack_fingerprint: { language: "ruby", framework: "rails" },
          project_name: "MyApp"
        )

        assert_includes result[:content], "As-Built Specification"
        assert result[:structured_data].is_a?(Hash)
        assert_equal "MyApp", result[:structured_data]["project_name"]
      end

      test "handles response without JSON metadata gracefully" do
        @llm.expects(:chat).once.returns("# MyApp\n\nJust plain markdown, no JSON block")

        result = @agent.call(
          feature_inventories: [],
          stack_fingerprint: { language: "ruby", framework: "rails" },
          project_name: "MyApp"
        )

        assert_includes result[:content], "MyApp"
        assert_equal({}, result[:structured_data])
      end

      test "includes reference_materials in prompt" do
        inventories = [
          {
            "concern_id" => "auth",
            "features" => [
              { "name" => "Login", "description" => "User login", "status" => "implemented", "files" => [], "dependencies" => [] }
            ]
          }
        ]

        reference_materials = [
          { path: "docs/ARCHITECTURE.md", content: "# Architecture\n\nMicroservices with event sourcing" }
        ]

        @llm.expects(:chat).once.with { |messages:, **| messages.first[:content].include?("Reference Documentation") }.returns("# MyApp\n```json\n{}\n```")

        result = @agent.call(
          feature_inventories: inventories,
          stack_fingerprint: { language: "ruby", framework: "rails" },
          project_name: "MyApp",
          reference_materials:
        )

        assert_includes result[:content], "MyApp"
      end

      test "works without reference_materials (backward compatible)" do
        @llm.expects(:chat).once.with { |messages:, **| !messages.first[:content].include?("Reference Documentation") }.returns("# MyApp\n```json\n{}\n```")

        result = @agent.call(
          feature_inventories: [],
          stack_fingerprint: { language: "ruby", framework: "rails" },
          project_name: "MyApp"
        )

        assert_includes result[:content], "MyApp"
      end
    end
  end
end

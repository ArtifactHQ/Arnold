require "test_helper"
require "arnold_pipeline/agents/brownfield/synthesis_agent"
require "arnold_pipeline/brownfield/parallel_agent_runner"

module ArnoldPipeline
  module Agents
    module Brownfield
      class SynthesisAgentTest < ActiveSupport::TestCase
        setup do
          @llm = mock("llm")
          @logger = Logger.new(IO::NULL)
          @agent = SynthesisAgent.new(llm: @llm, logger: @logger)

          @stack_fingerprint = { language: "ruby", framework: "rails" }
          @concerns = {
            "auth" => { "status" => "present", "implementation" => "devise" },
            "data_layer" => { "status" => "present", "implementation" => "active_record" }
          }
        end

        test "returns content structured_data and review_data from synthesis" do
          spec_content = <<~SPEC
            # MyApp — As-Built Specification

            ## 1. Overview
            A web application for managing users.

            ## 2. Features

            ### Requirement: User Authentication [REQ-AUTH-001]
            Users SHALL be able to log in with email and password.

            > [!CONFIRMED] — Route, controller, and view all present.

            ```json
            {"application_type": "GENERIC", "features": ["auth"], "tech_stack": {}, "data_models": [{"name": "User", "attributes": ["email", "password"]}], "recipe_type": "web_app", "supporting_recipe_types": [], "as_built_metadata": {"original_stack": {"language": "ruby", "framework": "rails"}, "confirmed": 1, "inferred": 0, "gaps": 0}}
            ```
          SPEC

          @llm.expects(:chat).returns(spec_content)

          result = @agent.call(
            agent_results: build_agent_results,
            concerns: @concerns,
            stack_fingerprint: @stack_fingerprint,
            project_name: "MyApp"
          )

          assert_equal spec_content, result[:content]
          assert result[:structured_data].is_a?(Hash)
          assert_equal "GENERIC", result[:structured_data]["application_type"]
          assert_equal "web_app", result[:structured_data]["recipe_type"]
          assert_equal [ { "name" => "User", "attributes" => [ "email", "password" ] } ], result[:structured_data]["data_models"]
          assert result[:review_data].is_a?(Hash)
          assert result[:tokens_used] > 0
        end

        test "extracts review data from response with markers" do
          spec_content = <<~SPEC
            # MyApp — As-Built Specification

            ## 2. Features

            ### Requirement: Login [REQ-AUTH-001]
            Users SHALL log in.

            ```json
            {"application_type": "GENERIC", "features": ["auth"], "tech_stack": {}, "data_models": [], "recipe_type": null, "supporting_recipe_types": []}
            ```

            ## 11. Review
            <!-- REVIEW_SECTION_START -->

            ### Open Questions
            - **[OQ-001]** Which auth provider should be used?
              - Context: Multiple auth approaches detected
            - **[OQ-002]** Are social logins required?

            ### Conflicts
            - **[CONFLICT-001]** Data model agent says User has role field, controller agent shows no role-based routing
              - Agent A says: User model has role attribute
              - Agent B says: No role-gated endpoints found

            ### Risk Register
            - **[RISK-001]** No password reset flow detected — Severity: HIGH
              - Evidence: No reset tokens or mailer found

            <!-- REVIEW_SECTION_END -->
          SPEC

          @llm.expects(:chat).returns(spec_content)

          result = @agent.call(
            agent_results: build_agent_results,
            concerns: @concerns,
            stack_fingerprint: @stack_fingerprint,
            project_name: "MyApp"
          )

          review = result[:review_data]
          assert_equal 2, review["open_questions"].size
          assert_equal "OQ-001", review["open_questions"].first["id"]
          assert_equal 1, review["conflicts"].size
          assert_equal "CONFLICT-001", review["conflicts"].first["id"]
          assert_equal 1, review["risks"].size
          assert_equal "RISK-001", review["risks"].first["id"]
        end

        test "review_data defaults to empty hash when no review section" do
          plain_spec = "# MyApp\n\n## 2. Features\n\nJust features.\n\n```json\n{}\n```"
          @llm.expects(:chat).returns(plain_spec)

          result = @agent.call(
            agent_results: build_agent_results,
            concerns: @concerns,
            stack_fingerprint: @stack_fingerprint,
            project_name: "MyApp"
          )

          assert_equal({}, result[:review_data])
        end

        test "handles response without JSON metadata" do
          plain_spec = "# MyApp — As-Built Specification\n\n## 1. Overview\nJust a spec with no JSON."
          @llm.expects(:chat).returns(plain_spec)

          result = @agent.call(
            agent_results: build_agent_results,
            concerns: @concerns,
            stack_fingerprint: @stack_fingerprint,
            project_name: "MyApp"
          )

          assert_equal plain_spec, result[:content]
          assert_equal({}, result[:structured_data])
          assert_equal({}, result[:review_data])
        end

        test "passes reference materials to prompt" do
          @llm.expects(:chat).with { |messages:, system:|
            messages.first[:content].include?("README.md")
          }.returns("# Spec\n```json\n{}\n```")

          @agent.call(
            agent_results: build_agent_results,
            concerns: @concerns,
            stack_fingerprint: @stack_fingerprint,
            project_name: "MyApp",
            reference_materials: [ { path: "README.md", content: "# My App\nA great app." } ]
          )
        end

        test "works with empty agent results" do
          @llm.expects(:chat).returns("# Spec\n\nMinimal.\n```json\n{}\n```")

          result = @agent.call(
            agent_results: [],
            concerns: @concerns,
            stack_fingerprint: @stack_fingerprint,
            project_name: "MyApp"
          )

          assert result[:content].present?
        end

        test "works with partial agent results (some nil outputs)" do
          results = [
            ArnoldPipeline::Brownfield::ParallelAgentRunner::AgentResult.new(
              agent_name: "infrastructure",
              output: { "conventions" => {}, "infrastructure" => [], "concerns" => [] },
              error: nil, duration_ms: 100, tokens_used: 50
            ),
            ArnoldPipeline::Brownfield::ParallelAgentRunner::AgentResult.new(
              agent_name: "data_model",
              output: nil,
              error: "LLM timeout", duration_ms: 5000, tokens_used: 0
            )
          ]

          @llm.expects(:chat).returns("# Spec\n```json\n{}\n```")

          result = @agent.call(
            agent_results: results,
            concerns: @concerns,
            stack_fingerprint: @stack_fingerprint,
            project_name: "MyApp"
          )

          assert result[:content].present?
        end

        test "prompt includes stack-agnostic instructions" do
          @llm.expects(:chat).with { |messages:, system:|
            content = messages.first[:content]
            content.include?("stack-agnostic") &&
              content.include?("NEVER mention specific libraries") &&
              content.include?("CONFIRMED") &&
              content.include?("INFERRED") &&
              content.include?("GAP")
          }.returns("# Spec\n```json\n{}\n```")

          @agent.call(
            agent_results: build_agent_results,
            concerns: @concerns,
            stack_fingerprint: @stack_fingerprint,
            project_name: "MyApp"
          )
        end

        test "prompt requests OpenSpec-compatible format with REQ IDs" do
          @llm.expects(:chat).with { |messages:, system:|
            content = messages.first[:content]
            content.include?("[REQ-{DOMAIN}-{NNN}]") &&
              content.include?("GIVEN") &&
              content.include?("WHEN") &&
              content.include?("THEN") &&
              content.include?("recipe_type")
          }.returns("# Spec\n```json\n{}\n```")

          @agent.call(
            agent_results: build_agent_results,
            concerns: @concerns,
            stack_fingerprint: @stack_fingerprint,
            project_name: "MyApp"
          )
        end

        private

        def build_agent_results
          [
            ArnoldPipeline::Brownfield::ParallelAgentRunner::AgentResult.new(
              agent_name: "infrastructure",
              output: {
                "conventions" => {
                  "naming_conventions" => "snake_case",
                  "architecture_pattern" => "MVC",
                  "test_framework" => "minitest",
                  "code_style" => "standard",
                  "dependency_management" => "bundler",
                  "error_handling" => "rescue",
                  "configuration_approach" => "credentials"
                },
                "infrastructure" => [],
                "concerns" => []
              },
              error: nil, duration_ms: 500, tokens_used: 100
            ),
            ArnoldPipeline::Brownfield::ParallelAgentRunner::AgentResult.new(
              agent_name: "data_model",
              output: {
                "entities" => [
                  { "name" => "User", "table" => "users", "status" => "implemented" }
                ],
                "relationships" => []
              },
              error: nil, duration_ms: 800, tokens_used: 200
            ),
            ArnoldPipeline::Brownfield::ParallelAgentRunner::AgentResult.new(
              agent_name: "business_logic",
              output: { "services" => [] },
              error: nil, duration_ms: 300, tokens_used: 80
            )
          ]
        end
      end
    end
  end
end

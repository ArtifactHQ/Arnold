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

        test "returns content and structured_data from synthesis" do
          spec_content = <<~SPEC
            # MyApp — As-Built Specification

            ## Purpose
            A web application for managing users.

            ## Requirements

            ### Requirement: User Authentication [EXISTING] [REQ-AUTH-001]
            [IMPLEMENTED] The system SHALL authenticate users via Devise.

            ```json
            {"project_name": "MyApp", "total_features": 5, "implemented": 4, "partial": 1, "stubbed": 0, "agents_contributing": 3}
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
          assert_equal "MyApp", result[:structured_data]["project_name"]
          assert result[:tokens_used] > 0
        end

        test "handles response without JSON metadata" do
          plain_spec = "# MyApp — As-Built Specification\n\n## Purpose\nJust a spec with no JSON."
          @llm.expects(:chat).returns(plain_spec)

          result = @agent.call(
            agent_results: build_agent_results,
            concerns: @concerns,
            stack_fingerprint: @stack_fingerprint,
            project_name: "MyApp"
          )

          assert_equal plain_spec, result[:content]
          assert_equal({}, result[:structured_data])
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
            reference_materials: [{ path: "README.md", content: "# My App\nA great app." }]
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

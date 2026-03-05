require "arnold_pipeline/agents/base_agent"
require "arnold_pipeline/prompts/brownfield/infrastructure"

module ArnoldPipeline
  module Agents
    module Brownfield
      class InfrastructureAgent < BaseAgent
        SCHEMA = {
          name: "infrastructure_analysis",
          schema: {
            type: "object", additionalProperties: false,
            required: %w[conventions infrastructure concerns],
            properties: {
              conventions: {
                type: "object", additionalProperties: false,
                required: %w[naming_conventions architecture_pattern test_framework code_style dependency_management error_handling configuration_approach],
                properties: {
                  naming_conventions: { type: "string" },
                  architecture_pattern: { type: "string" },
                  test_framework: { type: "string" },
                  code_style: { type: "string" },
                  dependency_management: { type: "string" },
                  error_handling: { type: "string" },
                  configuration_approach: { type: "string" }
                }
              },
              infrastructure: {
                type: "array",
                items: {
                  type: "object", additionalProperties: false,
                  required: %w[area description status files],
                  properties: {
                    area: { type: "string" },
                    description: { type: "string" },
                    status: { type: "string", enum: %w[configured partial missing] },
                    files: { type: "array", items: { type: "string" } }
                  }
                }
              },
              concerns: {
                type: "array",
                items: {
                  type: "object", additionalProperties: false,
                  required: %w[concern_id status implementation files notes],
                  properties: {
                    concern_id: { type: "string" },
                    status: { type: "string", enum: %w[present partial absent] },
                    implementation: { anyOf: [{ type: "string" }, { type: "null" }] },
                    files: { type: "array", items: { type: "string" } },
                    notes: { type: "string" }
                  }
                }
              }
            }
          }
        }.freeze

        def call(context:, file_cache:)
          files = Prompts::Brownfield::Infrastructure.select_files(context)
          contents = file_cache.read_batch(files)
          prompt = Prompts::Brownfield::Infrastructure.prompt(context:, file_contents: contents)
          result = chat_json(messages: [{ role: "user", content: prompt }], schema: SCHEMA)
          tokens_used = estimate_tokens(prompt, result)
          { data: result, tokens_used: }
        end

        private

        def estimate_tokens(prompt, result)
          prompt_tokens = prompt.to_s.length / 4
          response_tokens = (result.is_a?(Hash) ? JSON.generate(result) : result.to_s).length / 4
          prompt_tokens + response_tokens
        end
      end
    end
  end
end

require "arnold_pipeline/agents/base_agent"
require "arnold_pipeline/prompts/brownfield/business_logic"

module ArnoldPipeline
  module Agents
    module Brownfield
      class BusinessLogicAgent < BaseAgent
        SCHEMA = {
          name: "business_logic_analysis",
          schema: {
            type: "object", additionalProperties: false,
            required: [ "services" ],
            properties: {
              services: {
                type: "array",
                items: {
                  type: "object", additionalProperties: false,
                  required: %w[name file purpose rules state_transitions side_effects error_handling dependencies status],
                  properties: {
                    name: { type: "string" },
                    file: { type: "string" },
                    purpose: { type: "string" },
                    rules: { type: "array", items: { type: "string" } },
                    state_transitions: { type: "array", items: { type: "string" } },
                    side_effects: { type: "array", items: { type: "string" } },
                    error_handling: { type: "string" },
                    dependencies: { type: "array", items: { type: "string" } },
                    status: { type: "string", enum: %w[implemented partial stubbed] }
                  }
                }
              }
            }
          }
        }.freeze

        def call(context:, file_cache:)
          files = Prompts::Brownfield::BusinessLogic.select_files(context)
          contents = file_cache.read_batch(files)
          prompt = Prompts::Brownfield::BusinessLogic.prompt(context:, file_contents: contents)
          result = chat_json(messages: [ { role: "user", content: prompt } ], schema: SCHEMA)
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

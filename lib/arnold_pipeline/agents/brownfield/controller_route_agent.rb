require "arnold_pipeline/agents/base_agent"
require "arnold_pipeline/prompts/brownfield/controller_route"

module ArnoldPipeline
  module Agents
    module Brownfield
      class ControllerRouteAgent < BaseAgent
        SCHEMA = {
          name: "controller_route_analysis",
          schema: {
            type: "object", additionalProperties: false,
            required: [ "endpoints" ],
            properties: {
              endpoints: {
                type: "array",
                items: {
                  type: "object", additionalProperties: false,
                  required: %w[verb path controller action description access_control side_effects error_handling input_params output_format status feature_domain],
                  properties: {
                    verb: { type: "string" },
                    path: { type: "string" },
                    controller: { type: "string" },
                    action: { type: "string" },
                    description: { type: "string" },
                    access_control: { type: "string" },
                    side_effects: { type: "array", items: { type: "string" } },
                    error_handling: { type: "string" },
                    input_params: { type: "array", items: { type: "string" } },
                    output_format: { type: "string" },
                    status: { type: "string", enum: %w[implemented partial stubbed] },
                    feature_domain: { type: "string" }
                  }
                }
              }
            }
          }
        }.freeze

        def call(context:, file_cache:)
          files = select_files(context)
          contents = file_cache.read_batch(files)
          prompt = Prompts::Brownfield::ControllerRoute.prompt(context:, file_contents: contents)
          result = chat_json(messages: [ { role: "user", content: prompt } ], schema: SCHEMA)
          tokens_used = estimate_tokens(prompt, result)
          { data: result, tokens_used: }
        end

        private

        def select_files(context)
          require "arnold_pipeline/brownfield/stack_aware_file_selector"
          ArnoldPipeline::Brownfield::StackAwareFileSelector.select_files(context, "controller_route") ||
            legacy_select_files(context)
        end

        def legacy_select_files(context)
          manifest = context.file_manifest || {}
          manifest.keys.select { |path| path.match?(%r{\Aapp/controllers/.*\.rb\z}) }
        end

        def estimate_tokens(prompt, result)
          prompt_tokens = prompt.to_s.length / 4
          response_tokens = (result.is_a?(Hash) ? JSON.generate(result) : result.to_s).length / 4
          prompt_tokens + response_tokens
        end
      end
    end
  end
end

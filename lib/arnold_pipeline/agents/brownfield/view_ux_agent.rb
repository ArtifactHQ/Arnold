require "arnold_pipeline/agents/base_agent"
require "arnold_pipeline/prompts/brownfield/view_ux"

module ArnoldPipeline
  module Agents
    module Brownfield
      class ViewUxAgent < BaseAgent
        SCHEMA = {
          name: "view_ux_analysis",
          schema: {
            type: "object", additionalProperties: false,
            required: ["pages"],
            properties: {
              pages: {
                type: "array",
                items: {
                  type: "object", additionalProperties: false,
                  required: %w[name path description data_displayed actions role_adaptations layout javascript_controllers status],
                  properties: {
                    name: { type: "string" },
                    path: { type: "string" },
                    description: { type: "string" },
                    data_displayed: { type: "array", items: { type: "string" } },
                    actions: { type: "array", items: { type: "string" } },
                    role_adaptations: { type: "array", items: { type: "string" } },
                    layout: { type: "string" },
                    javascript_controllers: { type: "array", items: { type: "string" } },
                    status: { type: "string", enum: %w[implemented partial stubbed] }
                  }
                }
              }
            }
          }
        }.freeze

        FILE_PATTERNS = [
          %r{\Aapp/views/},
          %r{\Aapp/helpers/.*\.rb\z},
          %r{\Aapp/javascript/controllers/},
          %r{\Aapp/components/}
        ].freeze

        def call(context:, file_cache:)
          files = select_files(context)
          contents = file_cache.read_batch(files)
          prompt = Prompts::Brownfield::ViewUx.prompt(context:, file_contents: contents)
          result = chat_json(messages: [{ role: "user", content: prompt }], schema: SCHEMA)
          tokens_used = estimate_tokens(prompt, result)
          { data: result, tokens_used: }
        end

        private

        def select_files(context)
          manifest = context.file_manifest || {}
          manifest.keys.select { |path| FILE_PATTERNS.any? { |pattern| path.match?(pattern) } }
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

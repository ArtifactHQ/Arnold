require "arnold_pipeline/agents/base_agent"
require "arnold_pipeline/prompts/brownfield/data_model"

module ArnoldPipeline
  module Agents
    module Brownfield
      class DataModelAgent < BaseAgent
        SCHEMA = {
          name: "data_model_analysis",
          schema: {
            type: "object", additionalProperties: false,
            required: %w[entities relationships],
            properties: {
              entities: {
                type: "array",
                items: {
                  type: "object", additionalProperties: false,
                  required: %w[name table file attributes associations validations callbacks scopes business_methods status feature_domain],
                  properties: {
                    name: { type: "string" },
                    table: { type: "string" },
                    file: { type: "string" },
                    feature_domain: { type: "string" },
                    attributes: {
                      type: "array",
                      items: {
                        type: "object", additionalProperties: false,
                        required: %w[name type],
                        properties: {
                          name: { type: "string" },
                          type: { type: "string" }
                        }
                      }
                    },
                    associations: {
                      type: "array",
                      items: {
                        type: "object", additionalProperties: false,
                        required: %w[type name],
                        properties: {
                          type: { type: "string" },
                          name: { type: "string" }
                        }
                      }
                    },
                    validations: { type: "array", items: { type: "string" } },
                    callbacks: { type: "array", items: { type: "string" } },
                    scopes: { type: "array", items: { type: "string" } },
                    business_methods: {
                      type: "array",
                      items: {
                        type: "object", additionalProperties: false,
                        required: %w[name description],
                        properties: {
                          name: { type: "string" },
                          description: { type: "string" }
                        }
                      }
                    },
                    status: { type: "string", enum: %w[implemented partial stubbed] }
                  }
                }
              },
              relationships: {
                type: "array",
                items: {
                  type: "object", additionalProperties: false,
                  required: %w[from to type through],
                  properties: {
                    from: { type: "string" },
                    to: { type: "string" },
                    type: { type: "string" },
                    through: { anyOf: [ { type: "string" }, { type: "null" } ] }
                  }
                }
              }
            }
          }
        }.freeze

        def call(context:, file_cache:)
          files = Prompts::Brownfield::DataModel.select_files(context)
          contents = file_cache.read_batch(files)
          prompt = Prompts::Brownfield::DataModel.prompt(context:, file_contents: contents)
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

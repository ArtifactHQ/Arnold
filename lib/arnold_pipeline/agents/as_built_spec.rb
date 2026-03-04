require "arnold_pipeline/agents/base_agent"
require "arnold_pipeline/prompts/as_built_spec"

module ArnoldPipeline
  module Agents
    class AsBuiltSpec < BaseAgent
      def call(feature_inventories:, stack_fingerprint:, project_name:)
        prompt = Prompts::AsBuiltSpec.generation_prompt(
          feature_inventories:,
          stack_fingerprint:,
          project_name:
        )

        response = chat(messages: [{ role: "user", content: prompt }])
        structured_data = extract_structured_data(response)

        {
          content: response,
          structured_data:
        }
      end

      private

      def extract_structured_data(response)
        parse_json(response)
      rescue Agents::LlmParseError
        # If no JSON block found, return minimal metadata
        {}
      end
    end
  end
end

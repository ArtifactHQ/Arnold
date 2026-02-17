require_relative "base_agent"
require "arnold_pipeline/prompts/spec_generation"

module ArnoldPipeline
  module Agents
    class SpecGenerator < BaseAgent
      def call(nl_input:, persona:, recipe:, supporting_recipes: [], domain_type:)
        logger.info { "Generating spec for: #{nl_input.truncate(80)}" }
        logger.info { "Domain type: #{domain_type.code} — #{domain_type.name}" }

        system = Prompts::SpecGeneration.system_prompt(persona:, recipe:, supporting_recipes:, domain_type:)
        user = Prompts::SpecGeneration.user_prompt(nl_input:)

        response = chat(
          messages: [{ role: :user, content: user }],
          system: system
        )

        structured_data = extract_structured_data(response)

        {
          content: response,
          structured_data: structured_data
        }
      end

      private

      def extract_structured_data(response)
        parse_json(response)
      rescue LlmParseError
        logger.warn { "Could not extract structured data from spec response" }
        nil
      end
    end
  end
end

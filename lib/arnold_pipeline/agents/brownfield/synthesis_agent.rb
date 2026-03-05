require "arnold_pipeline/agents/base_agent"
require "arnold_pipeline/prompts/brownfield/synthesis"

module ArnoldPipeline
  module Agents
    module Brownfield
      class SynthesisAgent < BaseAgent
        def call(agent_results:, concerns:, stack_fingerprint:, project_name:, reference_materials: [])
          prompt = Prompts::Brownfield::Synthesis.prompt(
            agent_results:,
            concerns:,
            stack_fingerprint:,
            project_name:,
            reference_materials:
          )

          response = chat(messages: [{ role: "user", content: prompt }])
          structured_data = extract_structured_data(response)
          tokens_used = estimate_tokens(prompt, response)

          {
            content: response,
            structured_data:,
            tokens_used:
          }
        end

        private

        def extract_structured_data(response)
          parse_json(response)
        rescue Agents::LlmParseError
          {}
        end

        def estimate_tokens(prompt, response)
          (prompt.to_s.length / 4) + (response.to_s.length / 4)
        end
      end
    end
  end
end

require "arnold_pipeline/agents/base_agent"
require "arnold_pipeline/prompts/brownfield/synthesis"

module ArnoldPipeline
  module Agents
    module Brownfield
      class SynthesisAgent < BaseAgent
        REVIEW_SECTION_PATTERN = /<!-- REVIEW_SECTION_START -->(.*?)<!-- REVIEW_SECTION_END -->/m
        TAGGED_ITEM_PATTERN = /\*\*\[(%{prefix}-\d+)\]\*\*\s*(.+?)(?=\n\s*\*\*\[|<!-- REVIEW_SECTION_END -->|\z)/m

        def call(agent_results:, concerns:, stack_fingerprint:, project_name:, reference_materials: [])
          prompt = Prompts::Brownfield::Synthesis.prompt(
            agent_results:,
            concerns:,
            stack_fingerprint:,
            project_name:,
            reference_materials:
          )

          response = chat(messages: [ { role: "user", content: prompt } ])
          structured_data = extract_structured_data(response)
          review_data = extract_review_data(response)
          tokens_used = estimate_tokens(prompt, response)

          {
            content: response,
            structured_data:,
            review_data:,
            tokens_used:
          }
        end

        private

        def extract_structured_data(response)
          parse_json(response)
        rescue Agents::LlmParseError
          {}
        end

        def extract_review_data(response)
          review_match = response.match(REVIEW_SECTION_PATTERN)
          return {} unless review_match

          review_text = review_match[1]
          {
            "open_questions" => extract_tagged_items(review_text, "OQ"),
            "conflicts" => extract_tagged_items(review_text, "CONFLICT"),
            "risks" => extract_tagged_items(review_text, "RISK")
          }
        end

        def extract_tagged_items(text, prefix)
          pattern = Regexp.new(
            "\\*\\*\\[(#{Regexp.escape(prefix)}-\\d+)\\]\\*\\*\\s*(.+?)(?=\\n\\s*-\\s*\\*\\*\\[#{Regexp.escape(prefix)}-|\\z)",
            Regexp::MULTILINE
          )
          text.scan(pattern).map { |id, body| { "id" => id, "summary" => body.strip.lines.first&.strip } }
        end

        def estimate_tokens(prompt, response)
          (prompt.to_s.length / 4) + (response.to_s.length / 4)
        end
      end
    end
  end
end

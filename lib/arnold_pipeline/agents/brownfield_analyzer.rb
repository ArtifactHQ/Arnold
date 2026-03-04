require "yaml"
require "arnold_pipeline/agents/base_agent"
require "arnold_pipeline/prompts/brownfield_analysis"

module ArnoldPipeline
  module Agents
    class BrownfieldAnalyzer < BaseAgent
      CONCERNS_PATH = File.expand_path("../brownfield/data/concerns.yml", __dir__)

      def call(repo_path:, stack_fingerprint:, artifacts:, overlay:, concerns: nil, reference_materials: [], change_request: nil)
        @token_budget = ArnoldPipeline.configuration.brownfield_scan_budget
        @tokens_used = 0
        concerns ||= load_concerns

        # Pass 1: Concern mapping
        recipe_alignment = run_concern_mapping(concerns, overlay, artifacts, stack_fingerprint)

        # Pass 2: Convention extraction
        conventions = run_convention_extraction(artifacts, stack_fingerprint, overlay)

        # Pass 3: Documentation fidelity (optional)
        documentation_fidelity = nil
        if reference_materials.any? && budget_remaining?
          documentation_fidelity = run_doc_fidelity(reference_materials, artifacts)
        end

        # Pass 4: Change surface (optional)
        change_surface = nil
        if change_request && budget_remaining?
          change_surface = run_change_surface(recipe_alignment, conventions, change_request)
        end

        {
          recipe_alignment:,
          conventions:,
          documentation_fidelity:,
          change_surface:,
          token_budget_used: @tokens_used
        }
      end

      private

      def run_concern_mapping(concerns, overlay, artifacts, stack_fingerprint)
        prompt = Prompts::BrownfieldAnalysis.concern_mapping_prompt(
          concerns:, overlay:, artifacts:, stack_fingerprint:
        )

        response = chat(messages: [{ role: "user", content: prompt }])
        track_tokens(prompt, response)
        parse_json(response)
      end

      def run_convention_extraction(artifacts, stack_fingerprint, overlay)
        prompt = Prompts::BrownfieldAnalysis.convention_extraction_prompt(
          artifacts:, stack_fingerprint:, overlay:
        )

        response = chat(messages: [{ role: "user", content: prompt }])
        track_tokens(prompt, response)
        parse_json(response)
      end

      def run_doc_fidelity(reference_materials, artifacts)
        prompt = Prompts::BrownfieldAnalysis.doc_fidelity_prompt(
          reference_materials:, artifacts:
        )

        response = chat(messages: [{ role: "user", content: prompt }])
        track_tokens(prompt, response)
        parse_json(response)
      end

      def run_change_surface(recipe_alignment, conventions, change_request)
        prompt = Prompts::BrownfieldAnalysis.change_surface_prompt(
          recipe_alignment:, conventions:, change_request:
        )

        response = chat(messages: [{ role: "user", content: prompt }])
        track_tokens(prompt, response)
        parse_json(response)
      end

      def load_concerns
        YAML.safe_load_file(CONCERNS_PATH)["concerns"]
      end

      def track_tokens(prompt, response)
        prompt_tokens = prompt.to_s.length / 4
        response_tokens = response.to_s.length / 4
        @tokens_used += prompt_tokens + response_tokens
      end

      def budget_remaining?
        @tokens_used < @token_budget
      end
    end
  end
end

require_relative "base_agent"
require "arnold_pipeline/prompts/analysis"

module ArnoldPipeline
  module Agents
    class Analyzer < BaseAgent
      VALID_DECISIONS = %w[done iterate_tasks iterate_spec].freeze

      def call(spec_content:, diffs:, iteration_number:, persona:)
        logger.info { "Analyzing iteration #{iteration_number}" }

        system = Prompts::Analysis.system_prompt(persona:)
        user = Prompts::Analysis.user_prompt(
          spec_content:,
          diffs:,
          iteration_number:
        )

        response = chat(
          messages: [{ role: :user, content: user }],
          system: system
        )

        result = parse_json(response)
        validate_result!(result)
        result
      end

      private

      def validate_result!(result)
        raise Error, "Expected hash result, got #{result.class}" unless result.is_a?(Hash)

        decision = result["decision"]
        unless VALID_DECISIONS.include?(decision)
          raise Error, "Invalid decision: #{decision}. Must be one of: #{VALID_DECISIONS.join(', ')}"
        end

        confidence = result["confidence"]
        unless confidence.is_a?(Numeric) && confidence.between?(0, 100)
          raise Error, "Invalid confidence: #{confidence}. Must be 0-100."
        end

        validate_completeness_scores(result["completeness_scores"]) if result.key?("completeness_scores")
      end

      def validate_completeness_scores(scores)
        return unless scores

        unless scores.is_a?(Hash)
          logger.warn { "completeness_scores is not a hash, ignoring" }
          return
        end

        %w[new_reader_test coding_agent_test change_request_test].each do |key|
          next unless scores.key?(key)
          value = scores[key]
          unless value.is_a?(Numeric) && value.between?(0, 100)
            logger.warn { "completeness_scores.#{key} is invalid (#{value}), ignoring" }
          end
        end
      end
    end
  end
end

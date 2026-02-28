require_relative "base_agent"
require "arnold_pipeline/prompts/spec_iteration"

module ArnoldPipeline
  module Agents
    class SpecIterator < BaseAgent
      SCHEMA = {
        name: "spec_iteration_result",
        schema: {
          type: "object",
          additionalProperties: false,
          properties: {
            summary: { type: "string" },
            deltas: {
              type: "array",
              items: {
                type: "object",
                additionalProperties: false,
                properties: {
                  operation: { type: "string", enum: %w[added modified removed] },
                  section: { type: "string" },
                  requirement: { type: "string" },
                  content: { type: "string" },
                  before_content: { type: "string" },
                  after_content: { type: "string" },
                  rationale: { type: "string" }
                },
                required: %w[operation section requirement content before_content after_content rationale]
              }
            }
          },
          required: %w[summary deltas]
        }
      }.freeze

      def call(spec_content:, change_request:)
        logger.info { "Iterating spec for change request: #{change_request.truncate(80)}" }

        system = Prompts::SpecIteration.system_prompt
        user = Prompts::SpecIteration.user_prompt(spec_content:, change_request:)

        result = chat_json(
          messages: [ { role: :user, content: user } ],
          system:,
          schema: SCHEMA
        )

        validate_deltas!(result)
        result
      end

      private

      def validate_deltas!(result)
        deltas = result["deltas"] || []
        deltas.each_with_index do |delta, i|
          op = delta["operation"]
          unless %w[added modified removed].include?(op)
            raise ArgumentError, "Delta #{i}: invalid operation '#{op}'"
          end

          if op == "added" && delta["content"].blank?
            raise ArgumentError, "Delta #{i}: 'added' operation requires 'content'"
          end

          if op == "modified" && delta["after_content"].blank?
            raise ArgumentError, "Delta #{i}: 'modified' operation requires 'after_content'"
          end

          if %w[modified removed].include?(op) && delta["requirement"].blank?
            raise ArgumentError, "Delta #{i}: '#{op}' operation requires 'requirement'"
          end
        end
      end
    end
  end
end

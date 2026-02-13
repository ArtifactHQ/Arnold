require_relative "base_agent"
require "arnold_pipeline/prompts/analysis"

module ArnoldPipeline
  module Agents
    class Analyzer < BaseAgent
      VALID_DECISIONS = %w[done iterate_tasks iterate_spec].freeze

      RESPONSE_SCHEMA = {
        name: "analysis_result",
        schema: {
          type: "object", additionalProperties: false,
          required: ["decision", "confidence", "reasoning", "completeness_scores", "anti_patterns_found", "corrective_data", "requirement_coverage"],
          properties: {
            decision: { type: "string" },
            confidence: { type: "integer" },
            reasoning: { type: "string" },
            completeness_scores: {
              type: "object", additionalProperties: false,
              required: ["new_reader_test", "coding_agent_test", "change_request_test"],
              properties: {
                new_reader_test: { type: "integer" },
                coding_agent_test: { type: "integer" },
                change_request_test: { type: "integer" }
              }
            },
            anti_patterns_found: { type: "array", items: { type: "string" } },
            corrective_data: {
              type: "object", additionalProperties: false,
              required: ["tasks", "deltas"],
              properties: {
                tasks: {
                  anyOf: [
                    { type: "array", items: {
                      type: "object", additionalProperties: false,
                      required: ["title", "description", "priority", "labels", "depends_on"],
                      properties: {
                        title: { type: "string" },
                        description: { type: "string" },
                        priority: { type: "integer" },
                        labels: { type: "array", items: { type: "string" } },
                        depends_on: { type: "array", items: { type: "integer" } }
                      }
                    } },
                    { type: "null" }
                  ]
                },
                deltas: {
                  anyOf: [
                    { type: "array", items: {
                      type: "object", additionalProperties: false,
                      required: ["operation", "section", "requirement", "content", "before_content", "after_content", "rationale"],
                      properties: {
                        operation: { type: "string" },
                        section: { type: "string" },
                        requirement: { anyOf: [{ type: "string" }, { type: "null" }] },
                        content: { anyOf: [{ type: "string" }, { type: "null" }] },
                        before_content: { anyOf: [{ type: "string" }, { type: "null" }] },
                        after_content: { anyOf: [{ type: "string" }, { type: "null" }] },
                        rationale: { type: "string" }
                      }
                    } },
                    { type: "null" }
                  ]
                }
              }
            },
            requirement_coverage: {
              anyOf: [
                { type: "array", items: {
                  type: "object", additionalProperties: false,
                  required: ["id", "status", "notes"],
                  properties: {
                    id: { type: "string" },
                    status: { type: "string" },
                    notes: { type: "string" }
                  }
                } },
                { type: "null" }
              ]
            }
          }
        }
      }.freeze

      def call(spec_content:, diffs:, iteration_number:, persona:, comments: "", spec_test_progress_summary: nil)
        logger.info { "Analyzing iteration #{iteration_number}" }

        system = Prompts::Analysis.system_prompt(persona:)
        user = Prompts::Analysis.user_prompt(
          spec_content:,
          diffs:,
          iteration_number:,
          comments:,
          spec_test_progress_summary:
        )

        result = chat_json(
          messages: [{ role: :user, content: user }],
          system: system,
          schema: RESPONSE_SCHEMA
        )

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

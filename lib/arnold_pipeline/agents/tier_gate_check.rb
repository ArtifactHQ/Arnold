require_relative "base_agent"
require "arnold_pipeline/prompts/tier_gate"

module ArnoldPipeline
  module Agents
    class TierGateCheck < BaseAgent
      RESPONSE_SCHEMA = {
        name: "tier_gate_result",
        schema: {
          type: "object", additionalProperties: false,
          required: ["pass", "issues", "context_summary", "corrective_tasks"],
          properties: {
            pass: { type: "boolean" },
            issues: { type: "array", items: { type: "string" } },
            context_summary: { type: "string" },
            corrective_tasks: { type: "array", items: {
              type: "object", additionalProperties: false,
              required: ["title", "description", "labels"],
              properties: {
                title: { type: "string" },
                description: { type: "string" },
                labels: { type: "array", items: { type: "string" } }
              }
            } }
          }
        }
      }.freeze

      def call(tier_number:, task_summaries:, diffs:, comments: "", repo_context: nil,
               acceptance_criteria_summary: nil, verification_results: nil,
               spec_test_progress_summary: nil)
        logger.info { "Running tier gate check for tier #{tier_number}" }

        system = Prompts::TierGate.system_prompt
        user = Prompts::TierGate.user_prompt(
          tier_number:,
          task_summaries:,
          diffs:,
          comments:,
          repo_context:,
          acceptance_criteria_summary:,
          verification_results:,
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

        unless [true, false].include?(result["pass"])
          raise Error, "Invalid pass value: #{result['pass'].inspect}. Must be boolean."
        end

        summary = result["context_summary"]
        unless summary.is_a?(String) && !summary.strip.empty?
          raise Error, "context_summary must be a non-empty string."
        end

        if result.key?("corrective_tasks") && result["corrective_tasks"]
          tasks = result["corrective_tasks"]
          raise Error, "corrective_tasks must be an array." unless tasks.is_a?(Array)

          tasks.each_with_index do |task, i|
            raise Error, "corrective_tasks[#{i}] must be a hash." unless task.is_a?(Hash)
            raise Error, "corrective_tasks[#{i}] must have a title." unless task["title"].is_a?(String) && !task["title"].strip.empty?
          end
        end
      end
    end
  end
end

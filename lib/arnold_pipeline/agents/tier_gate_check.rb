require_relative "base_agent"
require "arnold_pipeline/prompts/tier_gate"

module ArnoldPipeline
  module Agents
    class TierGateCheck < BaseAgent
      def call(tier_number:, task_summaries:, diffs:, comments: "")
        logger.info { "Running tier gate check for tier #{tier_number}" }

        system = Prompts::TierGate.system_prompt
        user = Prompts::TierGate.user_prompt(
          tier_number:,
          task_summaries:,
          diffs:,
          comments:
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

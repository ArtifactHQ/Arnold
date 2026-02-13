require_relative "base_agent"
require "arnold_pipeline/prompts/task_breakdown"

module ArnoldPipeline
  module Agents
    class TaskBreaker < BaseAgent
      MIN_TASKS = 5
      MAX_TASKS = 20

      RESPONSE_SCHEMA = {
        name: "task_breakdown_result",
        schema: {
          type: "object", additionalProperties: false, required: ["tasks"],
          properties: {
            tasks: { type: "array", items: {
              type: "object", additionalProperties: false,
              required: ["title", "description", "priority", "labels", "position", "depends_on", "section_ref", "acceptance_criteria"],
              properties: {
                title: { type: "string" },
                description: { type: "string" },
                priority: { type: "integer" },
                labels: { type: "array", items: { type: "string" } },
                position: { type: "integer" },
                depends_on: { type: "array", items: { type: "integer" } },
                section_ref: { type: "string" },
                acceptance_criteria: { type: "array", items: {
                  type: "object", additionalProperties: false,
                  required: ["type", "description", "params"],
                  properties: {
                    type: { type: "string", enum: %w[file_exists test_exists model_has route_exists http command_exits] },
                    description: { type: "string" },
                    params: { type: "string", description: "JSON-encoded parameters object" }
                  }
                } }
              }
            } }
          }
        }
      }.freeze

      def call(spec_content:, recipe: nil, supporting_recipes: [])
        if recipe
          logger.info { "Breaking spec into tasks (recipe: #{recipe.name})" }
        else
          logger.info { "Breaking spec into tasks" }
        end

        system = Prompts::TaskBreakdown.system_prompt(recipe:, supporting_recipes:)
        user = Prompts::TaskBreakdown.user_prompt(spec_content:)

        result = chat_json(
          messages: [{ role: :user, content: user }],
          system: system,
          schema: RESPONSE_SCHEMA
        )

        tasks = result["tasks"]
        decode_criteria_params!(tasks)
        validate_tasks!(tasks)
        tasks
      end

      private

      def decode_criteria_params!(tasks)
        tasks.each do |task|
          (task["acceptance_criteria"] || []).each do |ac|
            next unless ac["params"].is_a?(String)
            ac["params"] = JSON.parse(ac["params"])
          rescue JSON::ParserError
            ac["params"] = {}
          end
        end
      end

      def validate_tasks!(tasks)
        raise Error, "Expected array of tasks, got #{tasks.class}" unless tasks.is_a?(Array)

        if tasks.size < MIN_TASKS || tasks.size > MAX_TASKS
          logger.warn { "Task count #{tasks.size} outside expected range #{MIN_TASKS}-#{MAX_TASKS}" }
        end

        tasks.each_with_index do |task, i|
          raise Error, "Task #{i} missing title" unless task["title"]
          raise Error, "Task #{i} missing position" unless task["position"]
        end

        validate_dependency_order!(tasks)
      end

      def validate_dependency_order!(tasks)
        positions = tasks.map { |t| t["position"] }.to_set

        tasks.each do |task|
          deps = task["depends_on"] || []
          deps.each do |dep|
            unless positions.include?(dep)
              raise Error, "Task '#{task['title']}' depends on non-existent position #{dep}"
            end
            if dep >= task["position"]
              raise Error, "Task '#{task['title']}' at position #{task['position']} depends on later position #{dep}"
            end
          end
        end
      end
    end
  end
end

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
          type: "object", additionalProperties: false, required: [ "tasks" ],
          properties: {
            tasks: { type: "array", items: {
              type: "object", additionalProperties: false,
              required: [ "title", "description", "priority", "labels", "position", "depends_on", "section_ref", "acceptance_criteria" ],
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
                  required: [ "type", "description", "params" ],
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

      def call(spec_content:, recipe: nil, supporting_recipes: [], deltas: nil)
        if deltas.present?
          logger.info { "Breaking spec into delta-scoped tasks (#{deltas.size} deltas)" }
        elsif recipe
          logger.info { "Breaking spec into tasks (recipe: #{recipe.name})" }
        else
          logger.info { "Breaking spec into tasks" }
        end

        system = Prompts::TaskBreakdown.system_prompt(recipe:, supporting_recipes:, deltas:)
        user = Prompts::TaskBreakdown.user_prompt(spec_content:, deltas:)

        result = chat_json(
          messages: [ { role: :user, content: user } ],
          system: system,
          schema: RESPONSE_SCHEMA
        )

        tasks = result["tasks"]
        raise Error, "LLM returned no tasks (got #{result.keys.inspect})" unless tasks.is_a?(Array)

        decode_criteria_params!(tasks)
        validate_tasks!(tasks, delta_scoped: deltas.present?)
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

      def validate_tasks!(tasks, delta_scoped: false)
        raise Error, "Expected array of tasks, got #{tasks.class}" unless tasks.is_a?(Array)

        min = delta_scoped ? 1 : MIN_TASKS
        if tasks.size < min || tasks.size > MAX_TASKS
          logger.warn { "Task count #{tasks.size} outside expected range #{min}-#{MAX_TASKS}" }
        end

        tasks.each_with_index do |task, i|
          raise Error, "Task #{i} missing title" unless task["title"]
          raise Error, "Task #{i} missing position" unless task["position"]
        end

        validate_dependency_order!(tasks)
      end

      def validate_dependency_order!(tasks)
        positions = tasks.map { |t| t["position"] }.to_set

        # Strip references to non-existent positions
        tasks.each do |task|
          task["depends_on"] = (task["depends_on"] || []).select { |dep| positions.include?(dep) }
        end

        # Check for backwards dependencies and auto-repair if needed
        needs_reorder = tasks.any? do |task|
          task["depends_on"].any? { |dep| dep >= task["position"] }
        end

        repair_dependency_order!(tasks) if needs_reorder
      end

      def repair_dependency_order!(tasks)
        logger.info { "[Arnold] Repairing task dependency order via topological sort" }

        by_pos = tasks.index_by { |t| t["position"] }

        # Kahn's algorithm for topological sort
        in_degree = {}
        tasks.each { |t| in_degree[t["position"]] = 0 }
        tasks.each do |t|
          t["depends_on"].each { |dep| in_degree[t["position"]] += 1 }
        end

        queue = tasks.select { |t| in_degree[t["position"]].zero? }
                     .sort_by { |t| t["position"] }
        sorted = []

        until queue.empty?
          task = queue.shift
          sorted << task

          tasks.each do |other|
            next unless other["depends_on"].include?(task["position"])
            in_degree[other["position"]] -= 1
            queue << other if in_degree[other["position"]].zero?
          end
          queue.sort_by! { |t| t["position"] }
        end

        if sorted.size < tasks.size
          # Cycle detected — fall back to original order and strip circular deps
          logger.warn { "[Arnold] Dependency cycle detected, stripping circular dependencies" }
          tasks.each { |t| t["depends_on"] = [] }
          return
        end

        # Build position mapping: old_position → new_position
        pos_map = {}
        sorted.each_with_index do |task, i|
          new_pos = i + 1
          pos_map[task["position"]] = new_pos
        end

        # Apply new positions and remap dependencies
        sorted.each_with_index do |task, i|
          task["depends_on"] = task["depends_on"].map { |dep| pos_map[dep] }
          task["position"] = i + 1
        end

        # Replace tasks array contents in-place
        tasks.replace(sorted)
      end
    end
  end
end

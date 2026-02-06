require_relative "base_agent"
require "arnold_pipeline/prompts/task_breakdown"

module ArnoldPipeline
  module Agents
    class TaskBreaker < BaseAgent
      MIN_TASKS = 5
      MAX_TASKS = 20

      def call(spec_content:)
        logger.info { "Breaking spec into tasks" }

        system = Prompts::TaskBreakdown.system_prompt
        user = Prompts::TaskBreakdown.user_prompt(spec_content:)

        response = chat(
          messages: [{ role: :user, content: user }],
          system: system
        )

        tasks = parse_json(response)
        validate_tasks!(tasks)
        tasks
      end

      private

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

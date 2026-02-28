module ArnoldPipeline
  module Mcp
    module Tools
      class GetTasks < Base
        def self.tool_name
          "get_tasks"
        end

        def self.description
          "Pull the task list for a pipeline run. Tasks are ordered by tier and include dependencies."
        end

        def self.input_schema
          {
            type: "object",
            properties: {
              run_id: {
                type: %w[string null],
                description: "Pipeline run ID. Defaults to the latest run if not provided."
              },
              tier: {
                type: %w[integer null],
                description: "Filter to a specific tier number."
              },
              status: {
                type: %w[string null],
                enum: %w[pending in_progress completed failed superseded],
                description: "Filter tasks by status."
              }
            },
            required: []
          }
        end

        def self.call(params, context)
          run_id = params["run_id"]
          tier = params["tier"]
          status = params["status"]

          run = context.pipeline_run(run_id: run_id)
          unless run
            return { error: "No pipeline run found" }
          end

          tasks = run.tasks.ordered
          tasks = tasks.in_tier(tier) if tier
          tasks = tasks.where(status: status) if status

          current_tier = run.tasks.where(status: %i[in_progress pending])
                            .order(:tier).pick(:tier) || 0

          {
            run_id: run.id.to_s,
            current_tier: current_tier,
            tasks: tasks.map { |t| format_task(t) }
          }
        end

        private_class_method def self.format_task(task)
          {
            task_id: task.id.to_s,
            title: task.title,
            description: task.description.to_s,
            tier: task.tier || 0,
            status: task.status,
            labels: task.labels || [],
            dependencies: task.depends_on || [],
            acceptance_criteria: task.acceptance_criteria || [],
            domain: (task.labels || []).first.to_s,
            persona_context: ""
          }
        end
      end
    end
  end
end

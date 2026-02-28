module ArnoldPipeline
  module Mcp
    module Tools
      class CompleteTask < Base
        def self.tool_name
          "complete_task"
        end

        def self.description
          "Report that a task has been completed. Stores the summary and files changed, and returns tier progress."
        end

        def self.input_schema
          {
            type: "object",
            properties: {
              task_id: {
                type: "string",
                description: "The ID of the task to complete."
              },
              summary: {
                type: "string",
                description: "Summary of what was accomplished."
              },
              files_changed: {
                type: "array",
                items: { type: "string" },
                description: "List of files that were created or modified."
              },
              notes: {
                type: %w[string null],
                description: "Optional additional notes."
              }
            },
            required: %w[task_id summary files_changed]
          }
        end

        def self.call(params, context)
          task_id = params["task_id"]
          summary = params["summary"]
          files_changed = params["files_changed"] || []
          notes = params["notes"]

          return { error: "task_id is required" } unless task_id
          return { error: "summary is required" } unless summary

          run = context.pipeline_run
          return { error: "No pipeline run found" } unless run

          task = run.tasks.find_by(id: task_id)
          return { error: "Task not found: #{task_id}" } unless task

          unless task.in_progress? || task.pending?
            return { error: "Task cannot be completed — current status is '#{task.status}'" }
          end

          # Build completion comment
          comment_body = "Completed: #{summary}"
          comment_body += "\n\nNotes: #{notes}" if notes.present?

          comments = (task.result_comments || []).dup
          comments << {
            "body" => comment_body,
            "created_at" => Time.current.iso8601
          }

          # Store files_changed in execution_metadata
          exec_meta = (task.execution_metadata || {}).merge(
            "files_changed" => files_changed,
            "completed_at" => Time.current.iso8601,
            "completion_summary" => summary
          )

          task.update!(
            status: :completed,
            result_comments: comments,
            execution_metadata: exec_meta
          )

          # Calculate tier progress
          tier_num = task.tier || 0
          tier_tasks = run.tasks.in_tier(tier_num)
          total = tier_tasks.count
          completed = tier_tasks.where(status: :completed).count
          ready_for_validation = (completed == total)

          {
            task_id: task.id.to_s,
            status: "completed",
            tier_progress: {
              tier: tier_num,
              completed: completed,
              total: total,
              ready_for_validation: ready_for_validation
            }
          }
        end
      end
    end
  end
end

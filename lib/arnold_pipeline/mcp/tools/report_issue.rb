module ArnoldPipeline
  module Mcp
    module Tools
      class ReportIssue < Base
        SPEC_PATTERNS = /\b(spec|requirement|unclear|ambiguous|missing requirement|undefined|underspecified)\b/i
        DEPENDENCY_PATTERNS = /\b(depends|blocked|prerequisite|dependency|waiting on|needs.*first|upstream)\b/i
        TASK_PATTERNS = /\b(task description|wrong|should be|incorrect|task.*unclear|restructure|rewrite)\b/i

        def self.tool_name
          "report_issue"
        end

        def self.description
          "Report an issue that prevents task completion. Arnold analyzes the issue and suggests a resolution."
        end

        def self.input_schema
          {
            type: "object",
            properties: {
              task_id: {
                type: "string",
                description: "The ID of the task with the issue."
              },
              issue: {
                type: "string",
                description: "Description of the problem encountered."
              },
              suggestion: {
                type: %w[string null],
                description: "Optional suggestion for how to resolve the issue."
              }
            },
            required: %w[task_id issue]
          }
        end

        def self.call(params, context)
          task_id = params["task_id"]
          issue = params["issue"]
          suggestion = params["suggestion"]

          return { error: "task_id is required" } unless task_id
          return { error: "issue is required" } unless issue

          run = context.pipeline_run
          return { error: "No pipeline run found" } unless run

          task = run.tasks.find_by(id: task_id)
          return { error: "Task not found: #{task_id}" } unless task

          # Classify the issue
          resolution_type = classify_issue(issue)

          # Build resolution based on type
          detail, actions_taken, revised_task = resolve_issue(
            resolution_type, task, issue, suggestion, run, context
          )

          # Record issue in result_comments
          record_issue(task, issue, suggestion, resolution_type)

          {
            task_id: task.id.to_s,
            resolution: resolution_type,
            detail: detail,
            actions_taken: actions_taken,
            revised_task: revised_task
          }
        end

        private_class_method def self.classify_issue(issue)
          if issue.match?(SPEC_PATTERNS)
            "spec_change"
          elsif issue.match?(DEPENDENCY_PATTERNS)
            "dependency_fix"
          elsif issue.match?(TASK_PATTERNS)
            "task_restructure"
          else
            "guidance"
          end
        end

        private_class_method def self.resolve_issue(type, task, issue, suggestion, run, context)
          case type
          when "spec_change"
            resolve_spec_change(task, issue, suggestion, run)
          when "dependency_fix"
            resolve_dependency_fix(task, issue, run)
          when "task_restructure"
            resolve_task_restructure(task, issue, suggestion)
          else
            resolve_guidance(task, issue, run, context)
          end
        end

        private_class_method def self.resolve_spec_change(task, issue, suggestion, run)
          spec = run.specification
          detail = "The issue suggests a spec clarification is needed."

          if spec&.content
            # Try to identify the relevant spec section
            labels = task.labels || []
            sections = spec.content.split(/^(## .+)$/)
            relevant = sections.select do |s|
              labels.any? { |l| s.downcase.include?(l.downcase) }
            end

            if relevant.any?
              detail += " Relevant spec sections: #{relevant.map(&:strip).reject(&:empty?).first(3).join(', ')}"
            end
          end

          if suggestion.present?
            detail += " Suggestion: #{suggestion}"
          end

          actions = [ "Identified issue as spec-related", "Flagged for spec review" ]
          [ detail, actions, nil ]
        end

        private_class_method def self.resolve_dependency_fix(task, issue, run)
          dep_ids = task.depends_on || []
          actions = [ "Analyzed dependency chain" ]

          if dep_ids.any?
            deps = run.tasks.where(id: dep_ids)
            incomplete = deps.reject(&:completed?)

            if incomplete.any?
              names = incomplete.map { |d| "#{d.title} (#{d.status})" }.join(", ")
              detail = "Incomplete dependencies: #{names}. These must be completed before this task can proceed."
              actions << "Identified #{incomplete.size} incomplete dependency task(s)"
            else
              detail = "All dependency tasks are completed. The reported blocking issue may be about missing output from a dependency."
              actions << "All dependencies verified as completed"
            end
          else
            detail = "This task has no declared dependencies. The issue may indicate a missing dependency that should be added."
            actions << "No dependencies found — may need task restructuring"
          end

          [ detail, actions, nil ]
        end

        private_class_method def self.resolve_task_restructure(task, issue, suggestion)
          original_description = task.description.to_s
          actions = [ "Analyzed task for restructuring" ]

          revised = nil
          if suggestion.present?
            new_description = suggestion
            task.update!(description: new_description)
            actions << "Updated task description based on suggestion"
            revised = {
              task_id: task.id.to_s,
              title: task.title,
              description: new_description,
              previous_description: original_description
            }
            detail = "Task description has been updated based on your suggestion."
          else
            detail = "Task may need restructuring. Please provide a suggestion for what the task description should be."
          end

          [ detail, actions, revised ]
        end

        private_class_method def self.resolve_guidance(task, issue, run, context)
          actions = [ "Gathered context for guidance" ]
          parts = []

          # Provide spec context
          spec = run.specification
          if spec&.content
            parts << "Spec is available for reference."
          end

          # Provide recipe guidance
          manager = context.library_manager
          recipe = manager.find_recipe(run.nl_input)
          if recipe
            parts << "Recipe '#{recipe.name}': #{recipe.description}"
            actions << "Retrieved recipe guidance"
          end

          # Provide persona guidance
          persona = manager.find_persona(run.nl_input)
          if persona
            parts << "Persona '#{persona.name}' (#{persona.role}) recommends: #{persona.description}"
            actions << "Retrieved persona guidance"
          end

          detail = parts.any? ? parts.join("\n") : "No additional context available. Consider breaking the issue into smaller parts."
          [ detail, actions, nil ]
        end

        private_class_method def self.record_issue(task, issue, suggestion, resolution_type)
          comments = (task.result_comments || []).dup
          comment = {
            "body" => "Issue reported (#{resolution_type}): #{issue}",
            "created_at" => Time.current.iso8601
          }
          comment["body"] += "\nSuggestion: #{suggestion}" if suggestion.present?
          comments << comment

          task.update!(result_comments: comments)
        end
      end
    end
  end
end

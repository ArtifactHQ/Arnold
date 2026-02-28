require "arnold_pipeline/delta_merger"
require_relative "base"

module ArnoldPipeline
  module Mcp
    module Tools
      class ConfirmChange < Base
        CHANGE_SOURCE = "mcp_confirm"

        def self.tool_name
          "confirm_change"
        end

        def self.description
          "Applies a previously proposed change to the specification. " \
            "Requires a change_id from a prior propose_change call. " \
            "Creates a new spec revision and optionally invalidates affected tasks."
        end

        def self.input_schema
          {
            type: "object",
            properties: {
              change_id: {
                type: "string",
                description: "The change_id returned from a prior propose_change call."
              },
              answers: {
                type: "object",
                description: "Optional answers to questions raised during the proposal. Keys are question strings, values are answer strings.",
                additionalProperties: { type: "string" }
              }
            },
            required: [ "change_id" ]
          }
        end

        def self.call(params, context)
          change_id = params["change_id"].to_s.strip
          answers = params["answers"] || {}

          if change_id.empty?
            return { error: "change_id is required" }
          end

          proposal = ProposeChange.proposals[change_id]
          unless proposal
            return { error: "No proposal found for change_id '#{change_id}'. It may have expired or been already applied." }
          end

          run = context.pipeline_run(run_id: proposal[:run_id])
          unless run
            return { error: "Pipeline run ##{proposal[:run_id]} no longer exists" }
          end

          spec = run.specification
          unless spec
            return { error: "No specification found for pipeline run ##{run.id}" }
          end

          # Apply the deltas from the analysis
          analysis = proposal[:analysis]
          raw_deltas = analysis["deltas"] || []

          if raw_deltas.empty?
            # Remove the proposal since it's been consumed
            ProposeChange.proposals.delete(change_id)
            return {
              applied: false,
              revision: spec.version.to_s,
              summary: "No deltas to apply. The proposal contained no concrete changes.",
              tasks_invalidated: 0,
              ready_for_execution: false
            }
          end

          # Apply deltas using the DeltaMerger
          merger = ArnoldPipeline::DeltaMerger.new(logger: Logger.new(File::NULL))
          result = merger.apply!(
            spec: spec,
            raw_deltas: raw_deltas,
            change_source: CHANGE_SOURCE,
            pipeline_run: run
          )

          # Invalidate (supersede) tasks affected by the changed sections
          tasks_invalidated = invalidate_affected_tasks(run, raw_deltas)

          # Remove the consumed proposal
          ProposeChange.proposals.delete(change_id)

          has_active_tasks = run.tasks.where(status: %i[pending in_progress]).any?

          {
            applied: true,
            revision: spec.reload.version.to_s,
            summary: analysis["summary"] || "Changes applied successfully",
            tasks_invalidated: tasks_invalidated,
            ready_for_execution: !has_active_tasks || tasks_invalidated == 0
          }
        end

        private_class_method def self.invalidate_affected_tasks(run, raw_deltas)
          changed_sections = raw_deltas.map { |d| d["section"] }.compact.uniq
          return 0 if changed_sections.empty?

          tasks_to_invalidate = run.tasks.where(status: %i[pending]).select { |task|
            task_labels = (task.labels || []).map(&:downcase)
            task_title = task.title.to_s.downcase
            task_desc = task.description.to_s.downcase

            changed_sections.any? { |section|
              section_lower = section.downcase
              task_labels.any? { |l| l.include?(section_lower) || section_lower.include?(l) } ||
                task_title.include?(section_lower) ||
                task_desc.include?(section_lower)
            }
          }

          count = 0
          tasks_to_invalidate.each do |task|
            task.update!(status: :superseded)
            count += 1
          end

          count
        end
      end
    end
  end
end

require "arnold_pipeline/agents/spec_iterator"
require "arnold_pipeline/delta_merger"
require_relative "base"

module ArnoldPipeline
  module Mcp
    module Tools
      class ResolveDrift < Base
        CHANGE_SOURCE = "drift_resolution"

        def self.tool_name
          "resolve_drift"
        end

        def self.description
          "Resolve a drift finding by updating the spec, creating corrective tasks, accepting, or ignoring it."
        end

        def self.input_schema
          {
            type: "object",
            properties: {
              finding_id: {
                type: "string",
                description: "The ID of the drift finding to resolve."
              },
              resolution: {
                type: "string",
                enum: %w[update_spec update_code accept ignore],
                description: "How to resolve: update_spec (modify spec), update_code (create tasks), accept (acknowledge), ignore (dismiss)."
              },
              notes: {
                type: %w[string null],
                description: "Optional notes about the resolution."
              }
            },
            required: %w[finding_id resolution]
          }
        end

        def self.call(params, context)
          finding_id = params["finding_id"].to_s.strip
          resolution = params["resolution"].to_s.strip
          notes = params["notes"]

          return { error: "finding_id is required" } if finding_id.empty?
          return { error: "resolution is required" } if resolution.empty?

          finding = DriftFinding.find_by(id: finding_id)
          return { error: "No drift finding found with ID '#{finding_id}'" } unless finding
          return { error: "Finding is already resolved (#{finding.resolution})" } if finding.resolved?

          case resolution
          when "update_spec"
            handle_update_spec(finding, notes)
          when "update_code"
            handle_update_code(finding, notes)
          when "accept"
            handle_accept(finding, notes)
          when "ignore"
            handle_ignore(finding, notes)
          else
            { error: "Invalid resolution: #{resolution}. Must be one of: update_spec, update_code, accept, ignore" }
          end
        end

        private_class_method def self.handle_update_spec(finding, notes)
          run = finding.pipeline_run
          spec = run.specification
          return { error: "No specification found for pipeline run ##{run.id}" } unless spec

          # Use SpecIterator to generate deltas from the finding
          change_request = build_spec_change_request(finding)

          iterator = Agents::SpecIterator.new(
            llm: build_llm,
            logger: Logger.new(File::NULL)
          )

          result = iterator.call(spec_content: spec.content, change_request: change_request)
          raw_deltas = result["deltas"] || []

          if raw_deltas.empty?
            finding.resolve!("update_spec", notes: notes)
            return {
              finding_id: finding.id.to_s,
              resolution_applied: "update_spec",
              actions_taken: [ "No deltas generated - finding resolved without spec changes" ],
              spec_revision: spec.version.to_s,
              tasks_generated: [],
              status: "resolved"
            }
          end

          # Apply deltas via DeltaMerger
          merger = DeltaMerger.new(logger: Logger.new(File::NULL))
          merger.apply!(
            spec: spec,
            raw_deltas: raw_deltas,
            change_source: CHANGE_SOURCE,
            pipeline_run: run
          )

          finding.resolve!("update_spec", notes: notes)

          {
            finding_id: finding.id.to_s,
            resolution_applied: "update_spec",
            actions_taken: [
              "Generated #{raw_deltas.size} delta(s) from finding",
              "Applied deltas to specification",
              "Created spec revision v#{spec.reload.version}"
            ],
            spec_revision: spec.reload.version.to_s,
            tasks_generated: [],
            status: "resolved"
          }
        end

        private_class_method def self.handle_update_code(finding, notes)
          run = finding.pipeline_run

          # Determine next position for new tasks
          max_position = run.tasks.maximum(:position) || -1

          task = run.tasks.create!(
            title: "Fix: #{finding.description.truncate(80)}",
            description: build_corrective_description(finding),
            position: max_position + 1,
            status: :pending,
            labels: [ finding.domain ].compact,
            depends_on: finding.affected_tasks || []
          )

          finding.resolve!("update_code", notes: notes)

          {
            finding_id: finding.id.to_s,
            resolution_applied: "update_code",
            actions_taken: [ "Created corrective task ##{task.id}" ],
            spec_revision: nil,
            tasks_generated: [
              {
                task_id: task.id.to_s,
                title: task.title,
                description: task.description
              }
            ],
            status: "pending_execution"
          }
        end

        private_class_method def self.handle_accept(finding, notes)
          finding.resolve!("accepted", notes: notes)

          {
            finding_id: finding.id.to_s,
            resolution_applied: "accepted",
            actions_taken: [ "Finding accepted - will be excluded from future drift checks for this spec revision" ],
            spec_revision: nil,
            tasks_generated: [],
            status: "resolved"
          }
        end

        private_class_method def self.handle_ignore(finding, notes)
          finding.resolve!("ignored", notes: notes)

          {
            finding_id: finding.id.to_s,
            resolution_applied: "ignored",
            actions_taken: [ "Finding ignored - may reappear on future drift checks" ],
            spec_revision: nil,
            tasks_generated: [],
            status: "resolved"
          }
        end

        private_class_method def self.build_llm
          Providers::Llm.build
        rescue => e
          nil
        end

        private_class_method def self.build_spec_change_request(finding)
          parts = [ "Drift finding requires spec update:" ]
          parts << "Type: #{finding.drift_type}"
          parts << "Severity: #{finding.severity}"
          parts << "Description: #{finding.description}"
          parts << "Spec expectation: #{finding.spec_expectation}" if finding.spec_expectation.present?
          parts << "Actual state: #{finding.actual_state}" if finding.actual_state.present?
          parts << "Please update the spec to reflect the actual state of the codebase."
          parts.join("\n")
        end

        private_class_method def self.build_corrective_description(finding)
          parts = []
          parts << "## Drift Finding"
          parts << "**Type:** #{finding.drift_type}"
          parts << "**Severity:** #{finding.severity}"
          parts << "**Description:** #{finding.description}"
          parts << ""
          if finding.spec_expectation.present?
            parts << "## Spec Expectation"
            parts << finding.spec_expectation
            parts << ""
          end
          if finding.actual_state.present?
            parts << "## Actual State"
            parts << finding.actual_state
            parts << ""
          end
          parts << "## Action Required"
          parts << "Update the code to match the spec expectation described above."
          parts.join("\n")
        end
      end
    end
  end
end

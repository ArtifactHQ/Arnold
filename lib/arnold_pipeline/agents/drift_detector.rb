require_relative "base_agent"

module ArnoldPipeline
  module Agents
    class DriftDetector < BaseAgent
      BEHAVIORAL_SCHEMA = {
        name: "behavioral_drift_result",
        schema: {
          type: "object", additionalProperties: false,
          required: %w[findings],
          properties: {
            findings: {
              type: "array",
              items: {
                type: "object", additionalProperties: false,
                required: %w[domain drift_type severity description spec_expectation actual_state recommendation],
                properties: {
                  domain: { type: "string" },
                  drift_type: { type: "string", enum: %w[behavioral] },
                  severity: { type: "string", enum: %w[critical warning info] },
                  description: { type: "string" },
                  spec_expectation: { type: "string" },
                  actual_state: { type: "string" },
                  files_examined: { type: "array", items: { type: "string" } },
                  affected_tasks: { type: "array", items: { type: "string" } },
                  recommendation: { type: "string", enum: %w[update_spec update_code review_needed] }
                }
              }
            }
          }
        }
      }.freeze

      INTENT_SCHEMA = {
        name: "intent_drift_result",
        schema: {
          type: "object", additionalProperties: false,
          required: %w[findings],
          properties: {
            findings: {
              type: "array",
              items: {
                type: "object", additionalProperties: false,
                required: %w[domain drift_type severity description spec_expectation actual_state recommendation],
                properties: {
                  domain: { type: "string" },
                  drift_type: { type: "string", enum: %w[intent] },
                  severity: { type: "string", enum: %w[critical warning info] },
                  description: { type: "string" },
                  spec_expectation: { type: "string" },
                  actual_state: { type: "string" },
                  files_examined: { type: "array", items: { type: "string" } },
                  affected_tasks: { type: "array", items: { type: "string" } },
                  recommendation: { type: "string", enum: %w[update_spec update_code review_needed] }
                }
              }
            }
          }
        }
      }.freeze

      def call(spec_content:, tasks:, scope: "full", target: nil, depth: "full")
        filtered_tasks = filter_tasks(tasks, scope, target)
        findings = []

        if %w[structural full].include?(depth)
          findings.concat(detect_structural_drift(spec_content, filtered_tasks))
        end

        if %w[behavioral full].include?(depth)
          findings.concat(detect_behavioral_drift(spec_content, filtered_tasks))
        end

        if depth == "full"
          findings.concat(detect_intent_drift(spec_content, filtered_tasks))
        end

        findings
      end

      private

      def filter_tasks(tasks, scope, target)
        case scope
        when "domain"
          return tasks unless target
          tasks.select { |t| (t.labels || []).any? { |l| l.downcase.include?(target.downcase) } }
        when "task"
          return tasks unless target
          tasks.select { |t| t.id.to_s == target.to_s }
        else
          tasks
        end
      end

      def detect_structural_drift(spec_content, tasks)
        findings = []

        completed_tasks = tasks.select(&:completed?)
        completed_tasks.each do |task|
          if task.result_diff.blank? || task.result_diff == "[]"
            findings << {
              "domain" => (task.labels || []).first.to_s,
              "drift_type" => "structural",
              "severity" => "warning",
              "description" => "Completed task '#{task.title}' has no code changes (empty diff).",
              "spec_expectation" => "Task should produce code artifacts.",
              "actual_state" => "No diff recorded for completed task.",
              "files_examined" => [],
              "affected_tasks" => [ task.id.to_s ],
              "recommendation" => "review_needed"
            }
          end
        end

        # Check for spec sections that have no corresponding tasks
        spec_sections = extract_spec_sections(spec_content)
        task_domains = tasks.flat_map { |t| (t.labels || []).map(&:downcase) }.uniq

        spec_sections.each do |section|
          section_lower = section.downcase
          covered = task_domains.any? { |d| d.include?(section_lower) || section_lower.include?(d) } ||
            tasks.any? { |t| t.title.to_s.downcase.include?(section_lower) || t.description.to_s.downcase.include?(section_lower) }

          unless covered
            findings << {
              "domain" => section,
              "drift_type" => "structural",
              "severity" => "info",
              "description" => "Spec section '#{section}' has no corresponding tasks.",
              "spec_expectation" => "Each spec section should map to at least one task.",
              "actual_state" => "No tasks found covering '#{section}'.",
              "files_examined" => [],
              "affected_tasks" => [],
              "recommendation" => "review_needed"
            }
          end
        end

        findings
      end

      def detect_behavioral_drift(spec_content, tasks)
        completed_with_diffs = tasks.select { |t| t.completed? && t.result_diff.present? && t.result_diff != "[]" }
        return [] if completed_with_diffs.empty?

        task_summaries = completed_with_diffs.map { |t|
          diff_excerpt = t.result_diff.to_s.truncate(500)
          "### Task: #{t.title}\nLabels: #{(t.labels || []).join(', ')}\nDiff excerpt:\n#{diff_excerpt}"
        }.join("\n\n")

        system = <<~SYSTEM
          You are a QA analyst comparing completed work against a specification.
          Identify any behavioral drift: cases where the implementation does not fully satisfy
          the spec requirements, or where behavior diverges from what was specified.
          Only report genuine issues, not minor style differences.
          If everything looks aligned, return an empty findings array.
        SYSTEM

        user = <<~USER
          ## Specification
          #{spec_content}

          ## Completed Task Outputs
          #{task_summaries}

          Analyze whether the completed tasks satisfy the spec requirements.
          Report any behavioral drift found.
        USER

        result = chat_json(
          messages: [ { role: :user, content: user } ],
          system: system,
          schema: BEHAVIORAL_SCHEMA
        )

        findings = result["findings"] || []
        # Attach affected task IDs
        findings.each do |f|
          f["affected_tasks"] ||= completed_with_diffs.map { |t| t.id.to_s }
        end

        findings
      end

      def detect_intent_drift(spec_content, tasks)
        completed_with_diffs = tasks.select { |t| t.completed? && t.result_diff.present? && t.result_diff != "[]" }
        return [] if completed_with_diffs.empty?

        task_summaries = completed_with_diffs.map { |t|
          "### Task: #{t.title}\nLabels: #{(t.labels || []).join(', ')}\nDescription: #{t.description.to_s.truncate(300)}"
        }.join("\n\n")

        system = <<~SYSTEM
          You are a QA analyst checking for intent drift.
          Identify any completed work that does not map to any section of the specification.
          This means work was done that was never requested or specified.
          Only report genuine issues. If all work maps to spec sections, return empty findings.
        SYSTEM

        user = <<~USER
          ## Specification
          #{spec_content}

          ## Completed Tasks
          #{task_summaries}

          Identify any tasks whose output does not correspond to any spec section.
        USER

        result = chat_json(
          messages: [ { role: :user, content: user } ],
          system: system,
          schema: INTENT_SCHEMA
        )

        findings = result["findings"] || []
        findings.each do |f|
          f["affected_tasks"] ||= completed_with_diffs.map { |t| t.id.to_s }
        end

        findings
      end

      def extract_spec_sections(spec_content)
        # Extract h2/h3 headers as section names, filtering common non-feature headers
        headers = spec_content.scan(Regexp.new('^#{2,3}\s+(.+)$')).flatten
        non_feature = %w[purpose overview requirements tech technology stack constraints notes iteration]
        headers.reject { |h| non_feature.any? { |nf| h.downcase.include?(nf) } }
      end
    end
  end
end

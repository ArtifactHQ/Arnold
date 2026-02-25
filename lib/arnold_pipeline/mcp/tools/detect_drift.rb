require "arnold_pipeline/agents/drift_detector"
require_relative "base"

module ArnoldPipeline
  module Mcp
    module Tools
      class DetectDrift < Base
        def self.tool_name
          "detect_drift"
        end

        def self.description
          "Detect divergence between the spec and the codebase. " \
            "Analyzes completed tasks against the specification to find structural, behavioral, or intent drift."
        end

        def self.input_schema
          {
            type: "object",
            properties: {
              scope: {
                type: "string",
                enum: %w[full domain task],
                description: "Scope of drift detection: full (all tasks), domain (filter by label), task (single task).",
                default: "full"
              },
              target: {
                type: %w[string null],
                description: "Target domain label or task ID when scope is 'domain' or 'task'."
              },
              run_id: {
                type: %w[string null],
                description: "Pipeline run ID. Defaults to the latest run if not provided."
              },
              depth: {
                type: "string",
                enum: %w[structural behavioral full],
                description: "Depth of analysis: structural (deterministic only), behavioral (LLM check), full (all checks including intent).",
                default: "full"
              }
            },
            required: []
          }
        end

        def self.call(params, context)
          scope = params["scope"] || "full"
          target = params["target"]
          run_id = params["run_id"]
          depth = params["depth"] || "full"

          run = context.pipeline_run(run_id: run_id)
          return { error: "No pipeline run found" } unless run

          spec = run.specification
          return { error: "No specification found for pipeline run ##{run.id}" } unless spec

          tasks = run.tasks.ordered
          revision = latest_revision(spec)

          # Exclude previously accepted findings for this spec revision
          accepted_descriptions = if revision
            DriftFinding.accepted_for_revision(revision.id).pluck(:description)
          else
            []
          end

          # Run drift detection
          agent = Agents::DriftDetector.new(
            llm: build_llm,
            logger: Logger.new(File::NULL)
          )

          raw_findings = agent.call(
            spec_content: spec.content,
            tasks: tasks,
            scope: scope,
            target: target,
            depth: depth
          )

          # Filter out accepted findings
          new_findings = raw_findings.reject { |f| accepted_descriptions.include?(f["description"]) }

          # Persist findings
          persisted = persist_findings(run, revision, new_findings)

          # Build coverage stats
          coverage = build_coverage(tasks, new_findings, scope, target)

          status = new_findings.empty? ? "clean" : "drift_detected"
          summary = build_summary(new_findings, coverage)

          {
            run_id: run.id.to_s,
            revision: revision&.version.to_s,
            scope: scope,
            status: status,
            findings: persisted.map { |f| format_finding(f) },
            summary: summary,
            coverage: coverage
          }
        end

        private_class_method def self.build_llm
          Providers::Llm.build
        rescue => e
          # Return nil - agent will handle building its own LLM
          nil
        end

        private_class_method def self.latest_revision(spec)
          spec.spec_revisions.ordered.last
        end

        private_class_method def self.persist_findings(run, revision, findings)
          findings.map do |f|
            DriftFinding.create!(
              pipeline_run: run,
              spec_revision: revision,
              domain: f["domain"],
              drift_type: f["drift_type"],
              severity: f["severity"],
              description: f["description"],
              spec_expectation: f["spec_expectation"],
              actual_state: f["actual_state"],
              files_examined: f["files_examined"] || [],
              affected_tasks: f["affected_tasks"] || [],
              recommendation: f["recommendation"]
            )
          end
        end

        private_class_method def self.build_coverage(tasks, findings, scope, target)
          checked_tasks = tasks.select(&:completed?)

          # Filter by scope
          if scope == "domain" && target
            checked_tasks = checked_tasks.select { |t| (t.labels || []).any? { |l| l.downcase.include?(target.downcase) } }
          elsif scope == "task" && target
            checked_tasks = checked_tasks.select { |t| t.id.to_s == target.to_s }
          end

          drifted_task_ids = findings.flat_map { |f| f["affected_tasks"] || [] }.uniq
          drifted_domains = findings.map { |f| f["domain"] }.compact.uniq
          all_domains = checked_tasks.flat_map { |t| (t.labels || []).map(&:downcase) }.uniq

          {
            domains_checked: all_domains.size,
            domains_clean: all_domains.size - drifted_domains.size,
            domains_drifted: drifted_domains.size,
            tasks_checked: checked_tasks.size,
            tasks_clean: checked_tasks.size - checked_tasks.count { |t| drifted_task_ids.include?(t.id.to_s) },
            tasks_drifted: checked_tasks.count { |t| drifted_task_ids.include?(t.id.to_s) }
          }
        end

        private_class_method def self.build_summary(findings, coverage)
          if findings.empty?
            "No drift detected. #{coverage[:tasks_checked]} task(s) checked across #{coverage[:domains_checked]} domain(s)."
          else
            critical = findings.count { |f| f["severity"] == "critical" }
            warnings = findings.count { |f| f["severity"] == "warning" }
            info = findings.count { |f| f["severity"] == "info" }
            parts = []
            parts << "#{critical} critical" if critical > 0
            parts << "#{warnings} warning(s)" if warnings > 0
            parts << "#{info} info" if info > 0
            "#{findings.size} finding(s) detected (#{parts.join(', ')}). #{coverage[:tasks_checked]} task(s) checked."
          end
        end

        private_class_method def self.format_finding(finding)
          {
            finding_id: finding.id.to_s,
            domain: finding.domain,
            type: finding.drift_type,
            severity: finding.severity,
            description: finding.description,
            spec_expectation: finding.spec_expectation,
            actual_state: finding.actual_state,
            files_examined: finding.files_examined || [],
            affected_tasks: finding.affected_tasks || [],
            recommendation: finding.recommendation
          }
        end
      end
    end
  end
end

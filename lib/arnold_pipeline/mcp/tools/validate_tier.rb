module ArnoldPipeline
  module Mcp
    module Tools
      class ValidateTier < Base
        def self.tool_name
          "validate_tier"
        end

        def self.description
          "Validate a completed tier against the spec. Checks task completion, dependencies, and result data."
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
                type: "integer",
                description: "The tier number to validate."
              },
              include_drift_check: {
                type: "boolean",
                description: "Whether to include drift detection (Phase 3 — currently a no-op).",
                default: false
              }
            },
            required: ["tier"]
          }
        end

        def self.call(params, context)
          run_id = params["run_id"]
          tier = params["tier"]
          include_drift_check = params["include_drift_check"] || false

          return { error: "tier is required" } if tier.nil?

          run = context.pipeline_run(run_id: run_id)
          return { error: "No pipeline run found" } unless run

          tier_tasks = run.tasks.in_tier(tier)
          return { error: "No tasks found for tier #{tier}" } if tier_tasks.empty?

          # Run checks
          checks = []
          issues = []

          # 1. Task completion check
          completion_check = check_task_completion(tier_tasks)
          checks << completion_check
          if completion_check[:result] == "fail"
            issues << {
              severity: "blocking",
              description: completion_check[:detail],
              affected_tasks: incomplete_task_ids(tier_tasks),
              recommendation: "Complete all tasks in tier #{tier} before validation."
            }
          end

          # 2. Dependency check
          dep_check = check_dependencies(tier_tasks, tier, run)
          checks << dep_check
          if dep_check[:result] == "fail"
            issues << {
              severity: "blocking",
              description: dep_check[:detail],
              affected_tasks: dep_check[:affected_tasks] || [],
              recommendation: "Ensure all dependency tasks from prior tiers are completed."
            }
          elsif dep_check[:result] == "warning"
            issues << {
              severity: "warning",
              description: dep_check[:detail],
              affected_tasks: dep_check[:affected_tasks] || [],
              recommendation: "Review dependency task results for completeness."
            }
          end

          # 3. Acceptance criteria / result data check
          result_check = check_result_data(tier_tasks)
          checks << result_check
          if result_check[:result] == "warning"
            issues << {
              severity: "warning",
              description: result_check[:detail],
              affected_tasks: result_check[:affected_tasks] || [],
              recommendation: "Ensure completed tasks have result summaries or comments."
            }
          end

          # Determine verdict
          verdict = determine_verdict(checks, issues)

          # Build response
          response = {
            tier: tier,
            verdict: verdict,
            summary: build_summary(tier, tier_tasks, verdict, checks),
            checks: checks.map { |c| c.slice(:check, :result, :detail) },
            issues: issues
          }

          # Drift check placeholder
          if include_drift_check
            response[:drift] = {
              status: "clean",
              findings: [
                { level: "info", message: "Drift detection not yet implemented (Phase 3)." }
              ]
            }
          else
            response[:drift] = { status: "clean", findings: [] }
          end

          # Next tier info (only if current tier passes)
          if verdict != "fail"
            response[:next_tier] = build_next_tier_info(tier, run)
          end

          response
        end

        private_class_method def self.check_task_completion(tier_tasks)
          total = tier_tasks.count
          completed = tier_tasks.where(status: :completed).count

          if completed == total
            { check: "task_completion", result: "pass", detail: "All #{total} tasks in tier completed." }
          else
            pending = total - completed
            { check: "task_completion", result: "fail", detail: "#{pending} of #{total} tasks not yet completed." }
          end
        end

        private_class_method def self.check_dependencies(tier_tasks, tier, run)
          return { check: "dependencies", result: "pass", detail: "Tier 0 has no prior dependencies." } if tier == 0

          # Collect all dependency IDs from tasks in this tier that point to prior tiers
          prior_dep_ids = []
          tier_tasks.each do |task|
            (task.depends_on || []).each do |dep_id|
              dep_task = run.tasks.find_by(id: dep_id)
              prior_dep_ids << dep_id if dep_task && (dep_task.tier || 0) < tier
            end
          end

          return { check: "dependencies", result: "pass", detail: "No cross-tier dependencies." } if prior_dep_ids.empty?

          prior_deps = run.tasks.where(id: prior_dep_ids.uniq)
          incomplete = prior_deps.reject(&:completed?)

          if incomplete.empty?
            { check: "dependencies", result: "pass", detail: "All #{prior_deps.count} prior-tier dependencies satisfied." }
          else
            {
              check: "dependencies",
              result: "fail",
              detail: "#{incomplete.size} prior-tier dependency task(s) not completed: #{incomplete.map(&:title).join(', ')}.",
              affected_tasks: incomplete.map { |t| t.id.to_s }
            }
          end
        end

        private_class_method def self.check_result_data(tier_tasks)
          completed = tier_tasks.where(status: :completed)
          return { check: "result_data", result: "pass", detail: "No completed tasks to check." } if completed.empty?

          missing_data = completed.select do |task|
            (task.result_comments.blank? || task.result_comments.empty?) &&
              (task.execution_metadata.blank? || task.execution_metadata.empty?)
          end

          if missing_data.empty?
            { check: "result_data", result: "pass", detail: "All completed tasks have result data." }
          else
            {
              check: "result_data",
              result: "warning",
              detail: "#{missing_data.size} completed task(s) have no result data: #{missing_data.map(&:title).join(', ')}.",
              affected_tasks: missing_data.map { |t| t.id.to_s }
            }
          end
        end

        private_class_method def self.determine_verdict(checks, issues)
          has_blocking = issues.any? { |i| i[:severity] == "blocking" }
          has_warning = issues.any? { |i| i[:severity] == "warning" }

          if has_blocking
            "fail"
          elsif has_warning
            "conditional"
          else
            "pass"
          end
        end

        private_class_method def self.build_summary(tier, tier_tasks, verdict, checks)
          total = tier_tasks.count
          completed = tier_tasks.where(status: :completed).count
          passed = checks.count { |c| c[:result] == "pass" }

          "Tier #{tier}: #{completed}/#{total} tasks completed, #{passed}/#{checks.size} checks passed — verdict: #{verdict}."
        end

        private_class_method def self.incomplete_task_ids(tier_tasks)
          tier_tasks.reject(&:completed?).map { |t| t.id.to_s }
        end

        private_class_method def self.build_next_tier_info(tier, run)
          next_tier_num = tier + 1
          next_tasks = run.tasks.in_tier(next_tier_num)

          if next_tasks.any?
            ready = next_tasks.all? { |t| t.pending? || t.in_progress? }
            {
              tier: next_tier_num,
              task_count: next_tasks.count,
              ready: ready
            }
          else
            nil
          end
        end
      end
    end
  end
end

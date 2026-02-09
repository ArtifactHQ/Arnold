module ArnoldPipeline
  class TierExecutionEngine
    attr_reader :executor, :tier_gate_check, :logger

    def initialize(executor:, tier_gate_check:, logger:)
      @executor = executor
      @tier_gate_check = tier_gate_check
      @logger = logger
    end

    def execute_tiers!(pipeline_run)
      pipeline_run.update!(status: :executing)
      logger.info { "[Arnold] Publishing tasks..." }

      max_tier = pipeline_run.tasks.maximum(:tier) || 0
      accumulated_context = load_accumulated_context(pipeline_run)

      (0..max_tier).each do |tier_num|
        tier_tasks = pipeline_run.tasks.in_tier(tier_num).to_a

        # Resume: skip fully resolved tiers
        if tier_tasks.all? { |t| tier_task_resolved?(t) }
          logger.info { "[Arnold] Executing tier #{tier_num + 1}/#{max_tier + 1}: skipping (all #{tier_tasks.size} tasks already resolved)" }
          next
        end

        logger.info { "[Arnold] Executing tier #{tier_num + 1}/#{max_tier + 1} (#{tier_tasks.size} tasks)..." }

        prior_context = build_prior_context(accumulated_context)

        # Publish (executor skips tasks with existing external_id)
        executor.call(tasks: tier_tasks, pipeline_run:, prior_context:)

        if executor.provider.async?
          # Async providers: poll until results available
          pipeline_run.update!(status: :awaiting_results)
          executor.await_results(pipeline_run:, tasks: tier_tasks)
        else
          # Sync providers: results available immediately after publish.
          # Reload tasks to pick up external_id set by executor.call (which
          # updates via a separate find_by query, leaving these objects stale).
          tier_tasks.each(&:reload)
          executor.fetch_results(pipeline_run:, tasks: tier_tasks)
        end

        # Merge this tier before next tier starts
        merge_tier_results!(pipeline_run, tier_tasks)
        logger.info { "[Arnold] Tier #{tier_num + 1}/#{max_tier + 1} complete. Running gate check..." }

        # Gate check + context (when either feature is enabled)
        if gate_check_needed?
          gate_result = run_tier_gate!(pipeline_run, tier_num, tier_tasks)

          if gate_result
            if ArnoldPipeline.configuration.tier_gate_enabled && !gate_result["pass"]
              handle_tier_gate_failure!(pipeline_run, tier_num, tier_tasks, gate_result, accumulated_context)
            end

            if ArnoldPipeline.configuration.context_propagation_enabled
              store_tier_context!(pipeline_run, tier_num, gate_result["context_summary"])
              accumulated_context = load_accumulated_context(pipeline_run)
            end
          end
        end
      end
    end

    def merge_all_results!(pipeline_run)
      logger.info { "[Arnold] Merging results..." }
      executor.merge_results(pipeline_run:)
    rescue => e
      raise unless recoverable_merge_error?(e)
      logger.warn { "[Arnold] Merge failed (non-fatal): #{e.message}" }
    end

    def tier_task_resolved?(task)
      task.external_id.present? && !task.workflow_active? && (
        (task.result_diff.present? && task.result_diff != "[]") ||
        task.failed? ||
        task.has_substantive_comments?
      )
    end

    def format_task_comments(tasks)
      sections = tasks.filter_map do |task|
        comments = task.result_comments
        next if comments.blank?

        lines = comments.map { |c| "[#{c['source']}] #{c['author']}: #{c['body']}" }
        "### Task: #{task.title} (#{task.status})\n#{lines.join("\n")}"
      end

      sections.join("\n\n")
    end

    private

    def merge_tier_results!(pipeline_run, tier_tasks)
      logger.info { "[Arnold] Merging tier results..." }
      executor.merge_results(pipeline_run:, tasks: tier_tasks)
    rescue => e
      raise unless recoverable_merge_error?(e)
      logger.warn { "[Arnold] Tier merge failed (non-fatal): #{e.message}" }
    end

    def recoverable_merge_error?(error)
      executor.provider.recoverable_errors.any? { |klass| error.is_a?(klass) }
    end

    def gate_check_needed?
      ArnoldPipeline.configuration.tier_gate_enabled || ArnoldPipeline.configuration.context_propagation_enabled
    end

    def run_tier_gate!(pipeline_run, tier_num, tier_tasks)
      tier_tasks.each(&:reload)

      task_summaries = tier_tasks.map { |t| "- **#{t.title}**: #{t.description}" }.join("\n")
      diffs = tier_tasks.map(&:result_diff).compact.join("\n\n")
      comments = format_task_comments(tier_tasks)

      result = tier_gate_check.call(
        tier_number: tier_num,
        task_summaries: task_summaries,
        diffs: diffs,
        comments: comments
      )

      if result
        status = result["pass"] ? "PASSED" : "FAILED"
        issues = result["issues"]&.join("; ") || "none"
        logger.info { "[Arnold] Tier #{tier_num} gate: #{status} — issues: #{issues}" }
      end

      result
    rescue => e
      logger.warn { "[Arnold] Tier gate check failed (non-fatal): #{e.class}: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}" }
      nil
    end

    def handle_tier_gate_failure!(pipeline_run, tier_num, tier_tasks, gate_result, accumulated_context)
      max_retries = ArnoldPipeline.configuration.max_tier_retries
      metadata = pipeline_run.metadata || {}
      tier_retries = metadata["tier_retries"] || {}
      retry_count = tier_retries[tier_num.to_s] || 0

      while retry_count < max_retries
        # Increment retry count
        retry_count += 1
        tier_retries[tier_num.to_s] = retry_count
        pipeline_run.update!(metadata: metadata.merge("tier_retries" => tier_retries))

        logger.info { "[Arnold] Tier #{tier_num} gate failed (retry #{retry_count}/#{max_retries}), creating corrective tasks" }

        # Create corrective tasks at the same tier
        corrective_tasks = gate_result["corrective_tasks"] || []
        max_position = pipeline_run.tasks.maximum(:position) || 0

        created_tasks = corrective_tasks.each_with_index.map do |td, i|
          pipeline_run.tasks.create!(
            title: td["title"],
            description: td["description"],
            labels: td["labels"] || [],
            position: max_position + i + 1,
            tier: tier_num
          )
        end

        if created_tasks.any?
          titles = created_tasks.map(&:title).join(", ")
          logger.info { "[Arnold] Created #{created_tasks.size} corrective tasks for tier #{tier_num}: #{titles}" }
        end

        return if created_tasks.empty?

        # Execute corrective tasks
        prior_context = build_prior_context(accumulated_context)
        pipeline_run.update!(status: :executing)
        executor.call(tasks: created_tasks, pipeline_run:, prior_context:)

        if executor.provider.async?
          pipeline_run.update!(status: :awaiting_results)
          executor.await_results(pipeline_run:, tasks: created_tasks)
        else
          created_tasks.each(&:reload)
          executor.fetch_results(pipeline_run:, tasks: created_tasks)
        end

        merge_tier_results!(pipeline_run, created_tasks)

        # Re-run gate check
        all_tier_tasks = pipeline_run.tasks.in_tier(tier_num).to_a
        gate_result = run_tier_gate!(pipeline_run, tier_num, all_tier_tasks)

        # If gate passed or returned nil, we're done
        return if gate_result.nil? || gate_result["pass"]

        # Update context if context propagation is enabled
        if ArnoldPipeline.configuration.context_propagation_enabled
          store_tier_context!(pipeline_run, tier_num, gate_result["context_summary"])
        end
      end

      # Exhausted retries — pause the pipeline
      issues_text = (gate_result["issues"] || []).join("; ")
      current_metadata = pipeline_run.reload.metadata || {}
      pipeline_run.update!(
        status: :paused,
        metadata: current_metadata.merge(
          "paused_at" => "tier_gate_failed",
          "tier_gate_failure" => { "tier" => tier_num, "issues" => gate_result["issues"] }
        )
      )
      raise TierGateError, "Tier #{tier_num} failed gate check after #{max_retries} retries: #{issues_text}"
    end

    def store_tier_context!(pipeline_run, tier_num, summary)
      return unless summary.present?

      metadata = pipeline_run.metadata || {}
      tier_contexts = metadata["tier_contexts"] || []
      # Replace existing context for this tier if retried
      tier_contexts.reject! { |tc| tc["tier"] == tier_num }
      tier_contexts << { "tier" => tier_num, "summary" => summary }
      pipeline_run.update!(metadata: metadata.merge("tier_contexts" => tier_contexts))
    end

    def load_accumulated_context(pipeline_run)
      (pipeline_run.metadata || {})["tier_contexts"] || []
    end

    def build_prior_context(tier_contexts)
      return nil if tier_contexts.blank?

      lines = tier_contexts.sort_by { |tc| tc["tier"] }.map do |tc|
        "**Tier #{tc['tier']} completed:** #{tc['summary']}"
      end

      "## Prior Implementation Context\n\n#{lines.join("\n\n")}"
    end
  end
end

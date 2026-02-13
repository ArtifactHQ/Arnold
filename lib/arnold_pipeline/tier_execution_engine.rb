require "arnold_pipeline/diff_summarizer"
require "arnold_pipeline/repo_context_scanner"
require "arnold_pipeline/acceptance_criterion"
require "arnold_pipeline/criteria_checker"
require "arnold_pipeline/verification/verification_result"
require "arnold_pipeline/verification/verification_runner"
require "arnold_pipeline/verification/recipe_verification_extractor"
require "arnold_pipeline/test_execution/test_result"
require "arnold_pipeline/test_execution/test_result_parser"
require "arnold_pipeline/test_execution/test_runner"

module ArnoldPipeline
  class TierExecutionEngine
    attr_reader :executor, :tier_gate_check, :logger, :event_recorder

    def initialize(executor:, tier_gate_check:, logger:, event_recorder: nil)
      @executor = executor
      @tier_gate_check = tier_gate_check
      @logger = logger
      @event_recorder = event_recorder
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

        event_recorder&.record(
          event_type: :tier_execution_started, stage: "execution",
          summary: { tier_number: tier_num, task_count: tier_tasks.size, task_titles: tier_tasks.map(&:title) },
          tier_number: tier_num
        )

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

        tier_tasks.each(&:reload)
        resolved = tier_tasks.count { |t| tier_task_resolved?(t) }
        failed = tier_tasks.count(&:failed?)
        event_recorder&.record(
          event_type: :tier_execution_completed, stage: "execution",
          summary: { tier_number: tier_num, resolved_count: resolved, failed_count: failed },
          tier_number: tier_num
        )

        logger.info { "[Arnold] Tier #{tier_num + 1}/#{max_tier + 1} complete. Running gate check..." }

        # Run verification after bootstrap tier (tier 0) if enabled
        verification_summary = nil
        if tier_num == 0 && verification_enabled?
          verification_summary = run_verification!(pipeline_run)
        end

        # Run test execution after merge if enabled
        test_execution_summary = nil
        if test_execution_enabled?
          test_execution_summary = run_test_execution!(pipeline_run)
        end

        # Run criteria check for this tier's tasks
        acceptance_criteria_summary = nil
        if gate_check_needed?
          acceptance_criteria_summary = run_criteria_check!(pipeline_run, tier_tasks)
        end

        # Gate check + context (when either feature is enabled)
        if gate_check_needed?
          gate_result = run_tier_gate!(pipeline_run, tier_num, tier_tasks,
                                      acceptance_criteria_summary:, verification_summary:,
                                      test_execution_summary:)

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

    def run_tier_gate!(pipeline_run, tier_num, tier_tasks,
                       acceptance_criteria_summary: nil, verification_summary: nil,
                       test_execution_summary: nil)
      tier_tasks.each(&:reload)

      task_summaries = tier_tasks.map { |t|
        suffix = if t.failed? && (t.result_diff.blank? || t.result_diff == "[]")
          " **[FAILED - EMPTY DIFF]**"
        elsif t.failed?
          " **[FAILED]**"
        else
          ""
        end
        "- **#{t.title}**: #{t.description}#{suffix}"
      }.join("\n")
      diffs = DiffSummarizer.call(tier_tasks.map(&:result_diff).compact)
      comments = format_task_comments(tier_tasks)
      repo_context = build_repo_context(pipeline_run)

      result = if event_recorder
        event_recorder.timed(
          event_type: :tier_gate_evaluated, stage: "tier_gate",
          summary: ->(r) {
            {
              pass: r&.dig("pass"),
              issues: r&.dig("issues") || [],
              corrective_task_count: (r&.dig("corrective_tasks") || []).size
            }
          },
          payload: ->(r) { { diffs: diffs, gate_response: r } },
          tier_number: tier_num
        ) do
          tier_gate_check.call(tier_number: tier_num, task_summaries:, diffs:, comments:, repo_context:,
                               acceptance_criteria_summary:, verification_summary:,
                               test_execution_summary:)
        end
      else
        tier_gate_check.call(tier_number: tier_num, task_summaries:, diffs:, comments:, repo_context:,
                             acceptance_criteria_summary:, verification_summary:,
                             test_execution_summary:)
      end

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
            tier: tier_num,
            acceptance_criteria: td["acceptance_criteria"] || []
          )
        end

        if created_tasks.any?
          titles = created_tasks.map(&:title).join(", ")
          logger.info { "[Arnold] Created #{created_tasks.size} corrective tasks for tier #{tier_num}: #{titles}" }
        end

        return if created_tasks.empty?

        # Execute corrective tasks sequentially — each branches from updated master
        prior_context = build_prior_context(accumulated_context)
        pipeline_run.update!(status: :executing)

        created_tasks.each do |task|
          executor.call(tasks: [task], pipeline_run:, prior_context:)

          if executor.provider.async?
            pipeline_run.update!(status: :awaiting_results)
            executor.await_results(pipeline_run:, tasks: [task])
          else
            task.reload
            executor.fetch_results(pipeline_run:, tasks: [task])
          end

          merge_tier_results!(pipeline_run, [task])
        end

        # Re-run empirical checks and gate check
        all_tier_tasks = pipeline_run.tasks.in_tier(tier_num).to_a
        acceptance_criteria_summary = run_criteria_check!(pipeline_run, all_tier_tasks)
        retry_test_execution_summary = test_execution_enabled? ? run_test_execution!(pipeline_run) : nil
        gate_result = run_tier_gate!(pipeline_run, tier_num, all_tier_tasks,
                                     acceptance_criteria_summary:,
                                     test_execution_summary: retry_test_execution_summary)

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

    def verification_enabled?
      ArnoldPipeline.configuration.verification_enabled
    end

    def test_execution_enabled?
      ArnoldPipeline.configuration.test_execution_enabled
    end

    def run_test_execution!(pipeline_run)
      cfg = ArnoldPipeline.configuration
      repo_path = cfg.claude_code_repo_path
      return nil unless repo_path && Dir.exist?(repo_path)

      logger.info { "[Arnold] Running test execution..." }

      runner_args = {
        repo_path: repo_path,
        test_command: cfg.test_command,
        timeout: cfg.test_timeout,
        boot_command: cfg.test_boot_command,
        boot_timeout: cfg.test_boot_timeout
      }

      if event_recorder
        result = event_recorder.timed(
          event_type: :test_execution, stage: "execution",
          summary: ->(r) {
            {
              passed: r&.passed,
              exit_code: r&.exit_code,
              framework: r&.framework,
              summary: r&.summary,
              failure_count: r&.failures&.size || 0
            }
          }
        ) do
          TestExecution::TestRunner.call(**runner_args)
        end
      else
        result = TestExecution::TestRunner.call(**runner_args)
      end

      status = result.passed ? "PASSED" : "FAILED"
      logger.info { "[Arnold] Test execution #{status}: #{result.summary}" }
      result.failures.each { |f| logger.warn { "[Arnold] Test failure: #{f[:name]}: #{f[:message]}" } } unless result.passed

      result.to_gate_summary
    rescue => e
      logger.warn { "[Arnold] Test execution failed (non-fatal): #{e.class}: #{e.message}" }
      nil
    end

    def run_verification!(pipeline_run)
      config = Verification::RecipeVerificationExtractor.call(pipeline_run:)
      return nil unless config

      repo_path = ArnoldPipeline.configuration.claude_code_repo_path
      return nil unless repo_path && Dir.exist?(repo_path)

      logger.info { "[Arnold] Running recipe verification (setup + boot + health check)..." }

      cfg = ArnoldPipeline.configuration
      timeout = cfg.verification_timeout
      retries = cfg.verification_health_check_retries
      interval = cfg.verification_health_check_interval

      runner_args = { repo_path:, verification_config: config, timeout:,
                      health_check_retries: retries, health_check_interval: interval }

      if event_recorder
        result = event_recorder.timed(
          event_type: :verification_execution, stage: "execution",
          summary: ->(r) {
            {
              setup_passed: r&.setup_passed,
              boot_passed: r&.boot_passed,
              health_check_passed: r&.health_check_passed,
              test_passed: r&.test_passed,
              passed: r&.passed?,
              error_count: r&.errors&.size || 0
            }
          }
        ) do
          Verification::VerificationRunner.call(**runner_args)
        end
      else
        result = Verification::VerificationRunner.call(**runner_args)
      end

      status = result.passed? ? "PASSED" : "FAILED"
      logger.info { "[Arnold] Verification #{status}" }
      result.errors.each { |e| logger.warn { "[Arnold] Verification error: #{e}" } } unless result.passed?

      result.to_gate_summary
    rescue => e
      logger.warn { "[Arnold] Verification failed (non-fatal): #{e.class}: #{e.message}" }
      nil
    end

    def run_criteria_check!(pipeline_run, tier_tasks)
      all_criteria = tier_tasks.flat_map do |task|
        AcceptanceCriterion.from_array(task.acceptance_criteria)
      end

      return nil if all_criteria.empty?

      repo_path = ArnoldPipeline.configuration.claude_code_repo_path
      return nil unless repo_path

      logger.info { "[Arnold] Running criteria check (#{all_criteria.size} criteria)..." }

      check_result = CriteriaChecker.call(criteria: all_criteria, repo_path:)

      event_recorder&.record(
        event_type: :criteria_check, stage: "tier_gate",
        summary: {
          verified_count: check_result[:verified].size,
          failed_count: check_result[:failed].size,
          unverified_count: check_result[:unverified].size
        }
      )

      format_criteria_summary(check_result)
    rescue => e
      logger.warn { "[Arnold] Criteria check failed (non-fatal): #{e.class}: #{e.message}" }
      nil
    end

    def format_criteria_summary(check_result)
      lines = []

      if check_result[:verified].any?
        lines << "**Verified (programmatic — treat as confirmed):**"
        check_result[:verified].each { |c| lines << "- [PASS] #{c.description} (#{c.type})" }
      end

      if check_result[:failed].any?
        lines << "" if lines.any?
        lines << "**Failed (programmatic — these are NOT satisfied):**"
        check_result[:failed].each { |c| lines << "- [FAIL] #{c.description} (#{c.type})" }
      end

      if check_result[:unverified].any?
        lines << "" if lines.any?
        lines << "**Unverified (requires your evaluation):**"
        check_result[:unverified].each { |c| lines << "- [EVALUATE] #{c.description} (#{c.type})" }
      end

      return nil if lines.empty?

      lines.join("\n")
    end

    def build_repo_context(pipeline_run)
      repo_path = ArnoldPipeline.configuration.claude_code_repo_path
      return nil unless repo_path

      file_list = RepoContextScanner.call(repo_path:)
      return nil if file_list.nil? || file_list.empty?

      formatted = format_repo_context(file_list)

      event_recorder&.record(
        event_type: :repo_context_scanned, stage: "tier_gate",
        summary: { file_count: file_list.size, directories: file_list.map { |f| File.dirname(f) }.uniq },
        payload: { file_list: file_list }
      )

      formatted
    rescue => e
      logger.warn { "[Arnold] Failed to build repo context: #{e.message}" }
      nil
    end

    def format_repo_context(file_list)
      grouped = file_list.group_by { |f| File.dirname(f) }
      grouped.sort_by(&:first).map do |dir, files|
        filenames = files.map { |f| File.basename(f) }.sort
        if filenames.size > RepoContextScanner::MAX_FILES_PER_DIR
          shown = filenames.first(RepoContextScanner::MAX_FILES_PER_DIR)
          remaining = filenames.size - RepoContextScanner::MAX_FILES_PER_DIR
          "  #{dir}/ (#{filenames.size} files): #{shown.join(', ')} ... and #{remaining} more"
        else
          "  #{dir}/ (#{filenames.size} files): #{filenames.join(', ')}"
        end
      end.join("\n")
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

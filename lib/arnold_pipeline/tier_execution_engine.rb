require "arnold_pipeline/diff_summarizer"
require "arnold_pipeline/repo_context_scanner"
require "arnold_pipeline/acceptance_criterion"
require "arnold_pipeline/criteria_checker"
require "arnold_pipeline/post_merge_hook"
require "arnold_pipeline/post_merge_hook_runner"
require "arnold_pipeline/verification_check"
require "arnold_pipeline/verification_runner"
require "arnold_pipeline/test_execution/test_result"
require "arnold_pipeline/test_execution/test_result_parser"
require "arnold_pipeline/test_execution/test_runner"
require "arnold_pipeline/spec_test_progress_tracker"
require "arnold_pipeline/spec_test_progress"
require "arnold_pipeline/corrective_task_generator"
require "open3"

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
          summary: {
            tier_number: tier_num,
            resolved_count: resolved,
            failed_count: failed,
            task_outcomes: tier_tasks.map { |t|
              outcome = { title: t.title, status: t.status }
              outcome[:failure_reason] = task_failure_reason(t) if t.failed?
              outcome
            }
          },
          tier_number: tier_num
        )

        logger.info { "[Arnold] Tier #{tier_num + 1}/#{max_tier + 1} complete. Running gate check..." }

        # Run post-merge hooks after merge (before gate)
        run_post_merge_hooks(tier_tasks, tier_num)

        # Run verification checks after hooks (before gate)
        verification_results = run_verification_checks(tier_num)

        # Run spec test generation after bootstrap tier (tier 0.5) if enabled
        if tier_num == 0 && spec_test_generation_enabled?
          run_spec_test_generation!(pipeline_run, tier_num)
        end

        # Run spec test progress tracking after merge if enabled
        spec_test_progress_summary = nil
        if spec_test_generation_enabled?
          spec_test_progress_summary = run_spec_test_progress!(pipeline_run, tier_num)
        end

        # Run criteria check for this tier's tasks (gate feature only, not context propagation)
        acceptance_criteria_summary = nil
        if ArnoldPipeline.configuration.tier_gate_enabled && ArnoldPipeline.configuration.criteria_check_mode != :disabled
          acceptance_criteria_summary = run_criteria_check!(pipeline_run, tier_tasks, tier_num)
        end

        # Gate check + context (when either feature is enabled)
        if gate_check_needed?
          gate_result = run_tier_gate!(pipeline_run, tier_num, tier_tasks,
                                      acceptance_criteria_summary:,
                                      verification_results:,
                                      spec_test_progress_summary:)

          if gate_result
            if ArnoldPipeline.configuration.tier_gate_enabled && !gate_result["pass"]
              handle_tier_gate_failure!(pipeline_run, tier_num, tier_tasks, gate_result, accumulated_context,
                                        acceptance_criteria_summary:)
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

    def task_failure_reason(task)
      return nil unless task.failed?
      if task.result_diff.blank? || task.result_diff == "[]"
        "empty_diff"
      else
        "execution_error"
      end
    end

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
                       acceptance_criteria_summary: nil, verification_results: nil,
                       spec_test_progress_summary: nil)
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
      repo_context = build_repo_context(pipeline_run, tier_num)

      if verification_results && has_test_suite_result?(verification_results)
        return evaluate_with_verification(
          pipeline_run:, tier_num:, tier_tasks:,
          task_summaries:, diffs:, comments:, repo_context:,
          acceptance_criteria_summary:, verification_results:,
          spec_test_progress_summary:
        )
      end

      evaluate_with_llm(
        tier_num:, task_summaries:, diffs:, comments:, repo_context:,
        acceptance_criteria_summary:, verification_results:,
        spec_test_progress_summary:
      )
    rescue => e
      logger.warn { "[Arnold] Tier gate check failed (non-fatal): #{e.class}: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}" }
      nil
    end

    def has_test_suite_result?(verification_results)
      verification_results[:checks]&.any? { |c| c[:type] == :test_suite }
    end

    def test_suite_passed?(verification_results)
      test_check = verification_results[:checks].find { |c| c[:type] == :test_suite }
      test_check && test_check[:success]
    end

    def required_checks_passed?(verification_results)
      verification_results[:checks].select { |c| c[:required] }.all? { |c| c[:success] }
    end

    def evaluate_with_verification(pipeline_run:, tier_num:, tier_tasks:,
                                   task_summaries:, diffs:, comments:, repo_context:,
                                   acceptance_criteria_summary:, verification_results:,
                                   spec_test_progress_summary:)
      # Check required checks first — boot failures are immediate gate failures
      failed_required = verification_results[:checks].select { |c| c[:required] && !c[:success] }
      if failed_required.any?
        result = build_failed_gate_result(
          tier_num: tier_num,
          issues: failed_required.map { |c| "Required check '#{c[:name]}' failed" },
          corrective_tasks: [build_boot_fix_task(verification_results)],
          context_summary: "Tier #{tier_num}: required verification checks failed — #{failed_required.map { |c| c[:name] }.join(', ')}"
        )
        log_gate_result(tier_num, result)
        record_gate_event(tier_num, result, diffs, task_summaries, "verification_required_failed")
        return result
      end

      # Parse test output for structured failures
      test_check = verification_results[:checks].find { |c| c[:type] == :test_suite }
      test_result = TestExecution::TestResultParser.call(
        stdout: test_check[:stdout] || "",
        stderr: test_check[:stderr] || "",
        exit_code: test_check[:exit_code]
      )

      if test_suite_passed?(verification_results)
        # Tests passed — gate PASSES, criteria are advisory
        context_summary = build_pass_context_summary(verification_results, acceptance_criteria_summary)
        result = build_passed_gate_result(tier_num: tier_num, context_summary: context_summary)
        log_gate_result(tier_num, result)
        record_gate_event(tier_num, result, diffs, task_summaries, "verification_tests_passed")
        result
      else
        # Tests failed — gate FAILS with corrective tasks from failures
        corrective_tasks = generate_corrective_tasks_from_failures(
          test_result: test_result, diffs: diffs,
          task_summaries: task_summaries, repo_context: repo_context
        )
        issues = extract_failure_summary(test_result)
        context_summary = build_fail_context_summary(verification_results, acceptance_criteria_summary)
        result = build_failed_gate_result(
          tier_num: tier_num, issues: issues,
          corrective_tasks: corrective_tasks, context_summary: context_summary
        )
        log_gate_result(tier_num, result)
        record_gate_event(tier_num, result, diffs, task_summaries, "verification_tests_failed")
        result
      end
    end

    def evaluate_with_llm(tier_num:, task_summaries:, diffs:, comments:, repo_context:,
                          acceptance_criteria_summary:, verification_results:,
                          spec_test_progress_summary:)
      result = if event_recorder
        event_recorder.timed(
          event_type: :tier_gate_evaluated, stage: "tier_gate",
          summary: ->(r) {
            {
              pass: r&.dig("pass"),
              issues: r&.dig("issues") || [],
              corrective_task_count: (r&.dig("corrective_tasks") || []).size,
              corrective_tasks: (r&.dig("corrective_tasks") || []).map { |t|
                { title: t["title"], description: t["description"] }
              },
              decision_source: "llm_judgment"
            }
          },
          payload: ->(r) { { diffs: diffs, task_summaries: task_summaries, gate_response: r } },
          tier_number: tier_num
        ) do
          tier_gate_check.call(tier_number: tier_num, task_summaries:, diffs:, comments:, repo_context:,
                               acceptance_criteria_summary:, verification_results:,
                               spec_test_progress_summary:)
        end
      else
        tier_gate_check.call(tier_number: tier_num, task_summaries:, diffs:, comments:, repo_context:,
                             acceptance_criteria_summary:, verification_results:,
                             spec_test_progress_summary:)
      end

      log_gate_result(tier_num, result)
      result
    end

    def generate_corrective_tasks_from_failures(test_result:, diffs:, task_summaries:, repo_context:)
      CorrectiveTaskGenerator.call(
        test_result: test_result,
        diffs: diffs,
        task_summaries: task_summaries,
        repo_context: repo_context,
        logger: logger
      )
    rescue => e
      logger.warn { "[Arnold] CorrectiveTaskGenerator failed (fallback to generic task): #{e.class}: #{e.message}" }
      truncated_summary = test_result.summary.to_s[0, 500]
      [{
        "title" => "Fix test failures",
        "description" => "Test suite failed. Summary: #{truncated_summary}",
        "labels" => ["bugfix"]
      }]
    end

    def build_passed_gate_result(tier_num:, context_summary:)
      {
        "pass" => true,
        "issues" => [],
        "corrective_tasks" => [],
        "context_summary" => context_summary
      }
    end

    def build_failed_gate_result(tier_num:, issues:, corrective_tasks:, context_summary:)
      {
        "pass" => false,
        "issues" => issues,
        "corrective_tasks" => corrective_tasks,
        "context_summary" => context_summary
      }
    end

    def build_pass_context_summary(verification_results, criteria_summary)
      lines = ["Verification checks all passed."]
      check_names = verification_results[:checks].map { |c| "#{c[:name]}=#{c[:success] ? 'OK' : 'FAIL'}" }
      lines << "Checks: #{check_names.join(', ')}"
      if criteria_summary.present?
        lines << ""
        lines << "Criteria check (advisory): #{criteria_summary}"
      end
      lines.join("\n")
    end

    def build_fail_context_summary(verification_results, criteria_summary)
      lines = ["Verification checks found failures."]
      check_names = verification_results[:checks].map { |c| "#{c[:name]}=#{c[:success] ? 'OK' : 'FAIL'}" }
      lines << "Checks: #{check_names.join(', ')}"
      if criteria_summary.present?
        lines << ""
        lines << "Criteria check: #{criteria_summary}"
      end
      lines.join("\n")
    end

    def build_boot_fix_task(verification_results)
      failed_checks = verification_results[:checks].select { |c| c[:required] && !c[:success] }
      details = failed_checks.map do |c|
        output = [c[:stdout], c[:stderr]].compact.reject(&:empty?).join("\n")
        truncated = output[0, 1000]
        "Check '#{c[:name]}' failed (exit code: #{c[:exit_code]}):\n#{truncated}"
      end.join("\n\n")

      {
        "title" => "Fix application boot failure",
        "description" => "Required verification checks failed. The application cannot boot.\n\n#{details}",
        "labels" => ["boot-fix", "critical"]
      }
    end

    def extract_failure_summary(test_result)
      return ["Test suite failed: #{test_result.summary}"] if test_result.failures.empty?

      test_result.failures.map do |f|
        location = f[:location] ? " (#{f[:location]})" : ""
        "#{f[:name]}#{location}: #{f[:message]}"
      end
    end

    def log_gate_result(tier_num, result)
      return unless result

      status = result["pass"] ? "PASSED" : "FAILED"
      issues = result["issues"]&.join("; ") || "none"
      logger.info { "[Arnold] Tier #{tier_num} gate: #{status} — issues: #{issues}" }
    end

    def record_gate_event(tier_num, result, diffs, task_summaries, decision_source)
      event_recorder&.record(
        event_type: :tier_gate_evaluated, stage: "tier_gate",
        summary: {
          pass: result["pass"],
          issues: result["issues"] || [],
          corrective_task_count: (result["corrective_tasks"] || []).size,
          corrective_tasks: (result["corrective_tasks"] || []).map { |t|
            { title: t["title"], description: t["description"] }
          },
          decision_source: decision_source
        },
        payload: { diffs: diffs, task_summaries: task_summaries, gate_response: result },
        tier_number: tier_num
      )
    end

    def handle_tier_gate_failure!(pipeline_run, tier_num, tier_tasks, gate_result, accumulated_context,
                                   acceptance_criteria_summary: nil)
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

        gate_issues = gate_result["issues"] || []
        if gate_issues.any?
          logger.debug { "[Arnold] Gate issues triggering correction:" }
          gate_issues.each_with_index { |issue, i| logger.debug { "[Arnold]   #{i + 1}. #{issue}" } }
        end

        # Create corrective tasks at the same tier
        corrective_tasks = gate_result["corrective_tasks"] || []
        max_position = pipeline_run.tasks.maximum(:position) || 0

        created_tasks = corrective_tasks.each_with_index.map do |td, i|
          enriched_desc = build_corrective_description(
            base_description: td["description"],
            gate_issues: gate_issues,
            original_tier_tasks: tier_tasks,
            acceptance_criteria_summary: acceptance_criteria_summary
          )

          pipeline_run.tasks.create!(
            title: td["title"],
            description: enriched_desc,
            labels: td["labels"] || [],
            position: max_position + i + 1,
            tier: tier_num,
            acceptance_criteria: td["acceptance_criteria"] || []
          )
        end

        if created_tasks.any?
          titles = created_tasks.map(&:title).join(", ")
          logger.info { "[Arnold] Created #{created_tasks.size} corrective tasks for tier #{tier_num}: #{titles}" }
          created_tasks.each do |ct|
            logger.debug { "[Arnold]   Task: #{ct.title}" }
            logger.debug { "[Arnold]     Description: #{ct.description}" } if ct.description.present?
            logger.debug { "[Arnold]     Labels: #{ct.labels.join(', ')}" } if ct.labels.any?
          end
        end

        return if created_tasks.empty?

        # Include the current tier's context_summary so corrective tasks know what was already built
        current_tier_summary = gate_result["context_summary"]
        corrective_context = if current_tier_summary.present?
          accumulated_context + [{ "tier" => tier_num, "summary" => current_tier_summary }]
        else
          accumulated_context
        end

        # Execute corrective tasks sequentially — each branches from updated master
        prior_context = build_prior_context(corrective_context)
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
        acceptance_criteria_summary = run_criteria_check!(pipeline_run, all_tier_tasks, tier_num)
        retry_verification_results = run_verification_checks(tier_num)
        gate_result = run_tier_gate!(pipeline_run, tier_num, all_tier_tasks,
                                     acceptance_criteria_summary:,
                                     verification_results: retry_verification_results)

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

    def spec_test_generation_enabled?
      ArnoldPipeline.configuration.spec_test_generation_enabled
    end

    def run_spec_test_generation!(pipeline_run, tier_number = nil)
      cfg = ArnoldPipeline.configuration
      repo_path = cfg.claude_code_repo_path
      return unless repo_path && Dir.exist?(repo_path)

      spec_content = pipeline_run.specification&.content
      return unless spec_content.present?

      logger.info { "[Arnold] Generating spec-scenario tests (tier 0.5)..." }

      require "arnold_pipeline/agents/spec_test_generator"
      generator = Agents::SpecTestGenerator.new(logger: logger)

      result = if event_recorder
        event_recorder.timed(
          event_type: :spec_test_execution, stage: "execution",
          tier_number: tier_number,
          summary: ->(r) {
            {
              phase: "generation",
              test_file_count: r&.dig("test_files")&.size || 0,
              test_directory: cfg.spec_test_directory
            }
          }
        ) do
          generator.call(spec_content:, test_directory: cfg.spec_test_directory)
        end
      else
        generator.call(spec_content:, test_directory: cfg.spec_test_directory)
      end

      test_files = result["test_files"] || []
      return if test_files.empty?

      # Write generated test files to the repo
      test_files.each do |file|
        path = File.join(repo_path, file["path"])
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, file["content"])
      end

      logger.info { "[Arnold] Generated #{test_files.size} spec test files in #{cfg.spec_test_directory}/" }

      # Run baseline — all tests should fail (no implementation yet)
      baseline_progress = SpecTestProgressTracker.call(
        repo_path: repo_path,
        test_directory: cfg.spec_test_directory
      )

      # Store baseline results in pipeline_run metadata
      metadata = pipeline_run.metadata || {}
      metadata["spec_test_results"] = {
        "total" => baseline_progress.total_tests,
        "passing_count" => baseline_progress.total_passing,
        "failed_names" => baseline_progress.still_failing
      }
      pipeline_run.update!(metadata: metadata)

      logger.info { "[Arnold] Spec test baseline: #{baseline_progress.total_passing}/#{baseline_progress.total_tests} passing (#{baseline_progress.pass_rate}%)" }
    rescue => e
      logger.warn { "[Arnold] Spec test generation failed (non-fatal): #{e.class}: #{e.message}" }
    end

    def run_spec_test_progress!(pipeline_run, tier_number = nil)
      cfg = ArnoldPipeline.configuration
      repo_path = cfg.claude_code_repo_path
      return nil unless repo_path && Dir.exist?(repo_path)

      test_dir = File.join(repo_path, cfg.spec_test_directory)
      return nil unless Dir.exist?(test_dir)

      logger.info { "[Arnold] Running spec-scenario test progression check..." }

      metadata = pipeline_run.metadata || {}
      previous_results = metadata["spec_test_results"]

      progress = if event_recorder
        event_recorder.timed(
          event_type: :spec_test_execution, stage: "tier_gate",
          tier_number: tier_number,
          summary: ->(r) {
            {
              phase: "progress_check",
              total_tests: r&.total_tests,
              total_passing: r&.total_passing,
              pass_rate: r&.pass_rate,
              newly_passing_count: r&.newly_passing&.size || 0,
              regression_count: r&.regressions&.size || 0
            }
          }
        ) do
          SpecTestProgressTracker.call(
            repo_path: repo_path,
            test_directory: cfg.spec_test_directory,
            previous_results: previous_results
          )
        end
      else
        SpecTestProgressTracker.call(
          repo_path: repo_path,
          test_directory: cfg.spec_test_directory,
          previous_results: previous_results
        )
      end

      # Update stored results for next tier comparison
      metadata["spec_test_results"] = {
        "total" => progress.total_tests,
        "passing_count" => progress.total_passing,
        "failed_names" => progress.still_failing + progress.regressions
      }
      pipeline_run.update!(metadata: metadata)

      logger.info { "[Arnold] Spec tests: #{progress.total_passing}/#{progress.total_tests} passing (#{progress.pass_rate}%)" }
      if progress.newly_passing.any?
        logger.info { "[Arnold] Newly passing: #{progress.newly_passing.join(', ')}" }
      end
      if progress.regressions.any?
        logger.warn { "[Arnold] Regressions: #{progress.regressions.join(', ')}" }
      end

      progress.to_gate_summary
    rescue => e
      logger.warn { "[Arnold] Spec test progress check failed (non-fatal): #{e.class}: #{e.message}" }
      nil
    end

    def run_post_merge_hooks(tier_tasks, tier_number = nil)
      config = ArnoldPipeline.configuration
      repo_path = config.claude_code_repo_path
      hooks = build_hooks
      return [] if repo_path.nil? || hooks.empty?

      changed_files = collect_changed_files(tier_tasks)
      results = PostMergeHookRunner.call(repo_path:, changed_files:, hooks:, logger:)

      triggered = results.select { |r| r[:triggered] }
      event_recorder&.record(
        event_type: :post_merge_hooks, stage: "execution",
        tier_number: tier_number,
        summary: {
          hook_count: results.size,
          triggered_count: triggered.size,
          success_count: triggered.count { |r| r[:success] },
          results: results.map { |r|
            entry = { name: r[:name], triggered: r[:triggered], success: r[:success] }
            entry[:exit_code] = r[:exit_code] if r[:triggered]
            entry[:error] = r[:error] if r[:error]
            entry
          }
        },
        payload: { changed_files: changed_files, results: results }
      )

      results
    rescue => e
      logger.warn { "[Arnold] Post-merge hooks failed: #{e.message}" }
      []
    end

    def run_verification_checks(tier_number = nil)
      config = ArnoldPipeline.configuration
      repo_path = config.claude_code_repo_path
      checks = build_checks
      return nil if repo_path.nil? || checks.empty?

      results = ArnoldPipeline::VerificationRunner.call(repo_path:, checks:, logger:)

      event_recorder&.record(
        event_type: :verification_checks, stage: "execution",
        tier_number: tier_number,
        summary: { all_passed: results[:all_passed], summary: results[:summary] },
        payload: results
      )

      results
    rescue => e
      logger.warn { "[Arnold] Verification checks failed: #{e.message}" }
      nil
    end

    def collect_changed_files(tier_tasks)
      tier_tasks.flat_map do |t|
        diff_data = t.result_diff.to_s
        next [] if diff_data.blank? || diff_data == "[]"

        parsed = JSON.parse(diff_data)
        parsed.filter_map { |f| f["filename"] }
      rescue JSON::ParserError
        # Fallback: try parsing as raw unified diff text
        diff_data.scan(%r{^[+-]{3} [ab]/(.+)$}).flatten
      end.uniq
    rescue => e
      logger.warn { "[Arnold] Failed to collect changed files: #{e.message}" }
      []
    end

    def build_hooks
      config = ArnoldPipeline.configuration
      return [] unless config.post_merge_hooks.present?

      config.post_merge_hooks.map do |h|
        PostMergeHook.new(
          name: h["name"] || h[:name],
          trigger_paths: h["trigger_paths"] || h[:trigger_paths],
          command: h["command"] || h[:command],
          commit_paths: h["commit_paths"] || h[:commit_paths] || [],
          commit_message: h["commit_message"] || h[:commit_message]
        )
      end
    end

    def build_checks
      config = ArnoldPipeline.configuration
      return [] unless config.verification_checks.present?

      config.verification_checks.map do |c|
        VerificationCheck.new(
          name: c["name"] || c[:name],
          command: c["command"] || c[:command],
          type: c["type"] || c[:type] || :custom,
          required: c["required"] || c[:required] || false
        )
      end
    end

    def run_criteria_check!(pipeline_run, tier_tasks, tier_number = nil)
      return nil if ArnoldPipeline.configuration.criteria_check_mode == :disabled

      all_criteria = tier_tasks.flat_map do |task|
        AcceptanceCriterion.from_array(task.acceptance_criteria)
      end

      return nil if all_criteria.empty?

      repo_path = ArnoldPipeline.configuration.claude_code_repo_path
      return nil unless repo_path

      logger.info { "[Arnold] Running criteria check (#{all_criteria.size} criteria)..." }
      all_criteria.each { |c| logger.debug { "[Arnold]   [#{c.type}] #{c.description}" } }

      check_result = CriteriaChecker.call(criteria: all_criteria, repo_path:)

      logger.info { "[Arnold] Criteria results: #{check_result[:verified].size} verified, #{check_result[:failed].size} failed, #{check_result[:unverified].size} unverified" }
      check_result[:verified].each { |c| logger.debug { "[Arnold]   PASS: #{c.description} (#{c.type})" } }
      check_result[:failed].each { |c| logger.debug { "[Arnold]   FAIL: #{c.description} (#{c.type})" } }
      check_result[:unverified].each { |c| logger.debug { "[Arnold]   UNVERIFIED: #{c.description} (#{c.type})" } }

      criteria_details = []
      check_result[:verified].each { |c| criteria_details << { type: c.type, description: c.description, result: "verified" } }
      check_result[:failed].each { |c| criteria_details << { type: c.type, description: c.description, result: "failed" } }
      check_result[:unverified].each { |c| criteria_details << { type: c.type, description: c.description, result: "unverified" } }

      event_recorder&.record(
        event_type: :criteria_check, stage: "tier_gate",
        tier_number: tier_number,
        summary: {
          verified_count: check_result[:verified].size,
          failed_count: check_result[:failed].size,
          unverified_count: check_result[:unverified].size,
          criteria: criteria_details
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

    def build_repo_context(pipeline_run, tier_number = nil)
      repo_path = ArnoldPipeline.configuration.claude_code_repo_path
      return nil unless repo_path

      file_list = RepoContextScanner.call(repo_path:)
      return nil if file_list.nil? || file_list.empty?

      formatted = format_repo_context(file_list)

      event_recorder&.record(
        event_type: :repo_context_scanned, stage: "tier_gate",
        tier_number: tier_number,
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

    def build_corrective_description(base_description:, gate_issues: [], original_tier_tasks: [], acceptance_criteria_summary: nil)
      sections = [base_description]

      if gate_issues.present?
        issue_lines = gate_issues.each_with_index.map { |issue, i| "#{i + 1}. #{issue}" }
        sections << "## Gate Issues\n#{issue_lines.join("\n")}"
      end

      if original_tier_tasks.present?
        task_lines = original_tier_tasks.map do |t|
          has_diffs = t.result_diff.present? && t.result_diff != "[]"
          status = has_diffs ? "[produced diffs]" : "[NO DIFFS]"
          "- #{t.title}: #{t.description} #{status}"
        end
        sections << "## Original Tier Tasks\n#{task_lines.join("\n")}"
      end

      if acceptance_criteria_summary.present?
        sections << "## Acceptance Criteria Status\n#{acceptance_criteria_summary}"
      end

      return base_description if sections.size == 1

      sections.join("\n\n")
    end
  end
end

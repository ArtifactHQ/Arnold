require "test_helper"
require "octokit"
require "faraday"
require "arnold_pipeline/tier_execution_engine"
require "arnold_pipeline/acceptance_criterion"
require "arnold_pipeline/criteria_checker"
require "arnold_pipeline/post_merge_hook"
require "arnold_pipeline/post_merge_hook_runner"
require "arnold_pipeline/verification_check"
require "arnold_pipeline/verification_runner"
require "arnold_pipeline/prompts/tier_gate"

module ArnoldPipeline
  class EmpiricalValidationIntegrationTest < ActiveSupport::TestCase
    setup do
      @executor = stub("executor")
      @tier_gate_check = stub("tier_gate_check")
      @tier_gate_check.stubs(:call).returns({
        "pass" => true,
        "issues" => [],
        "context_summary" => "Tier complete.",
        "corrective_tasks" => []
      })

      @provider = stub("execution_provider")
      @provider.stubs(:recoverable_errors).returns([Octokit::Error, Faraday::Error])
      @provider.stubs(:async?).returns(true)
      @executor.stubs(:provider).returns(@provider)

      @engine = TierExecutionEngine.new(
        executor: @executor,
        tier_gate_check: @tier_gate_check,
        logger: Logger.new(File::NULL)
      )

      ArnoldPipeline.configure do |c|
        c.max_iterations = 3
        c.llm_api_key = "test"
        c.github_token = "test"
        c.github_repo = "owner/repo"
        c.tier_gate_enabled = true
      end
    end

    teardown do
      ArnoldPipeline.reset_configuration!
    end

    # --- Configuration defaults ---

    test "post_merge_hooks defaults to empty array" do
      config = Configuration.new
      assert_equal [], config.post_merge_hooks
    end

    test "verification_checks defaults to empty array" do
      config = Configuration.new
      assert_equal [], config.verification_checks
    end

    test "test_timeout defaults to 120" do
      config = Configuration.new
      assert_equal 120, config.test_timeout
    end

    test "validate! raises on invalid test_timeout" do
      config = Configuration.new
      config.llm_api_key = "test"
      config.github_token = "test"
      config.github_repo = "owner/repo"
      config.test_timeout = 0

      error = assert_raises(ConfigurationError) { config.validate! }
      assert_match(/test_timeout/, error.message)
    end

    test "validate! passes with valid config" do
      config = Configuration.new
      config.llm_api_key = "test"
      config.github_token = "test"
      config.github_repo = "owner/repo"
      config.post_merge_hooks = [{ name: "lint", trigger_paths: ["*.rb"], command: "rubocop" }]
      config.verification_checks = [{ name: "boot", command: "bin/rails runner 'true'", type: :boot }]

      assert config.validate!
    end

    # --- Pipeline events ---

    test "criteria_check event type exists" do
      pipeline_run = PipelineRun.create!(nl_input: "test")
      event = pipeline_run.pipeline_events.create!(
        event_type: :criteria_check,
        stage: "tier_gate",
        summary: { verified_count: 2, failed_count: 1, unverified_count: 3 }
      )

      assert event.criteria_check?
      assert_equal 15, PipelineEvent.event_types["criteria_check"]
    end

    test "post_merge_hooks event type exists" do
      pipeline_run = PipelineRun.create!(nl_input: "test")
      event = pipeline_run.pipeline_events.create!(
        event_type: :post_merge_hooks,
        stage: "execution",
        summary: { hook_count: 1, results: [{ name: "lint", success: true }] }
      )

      assert event.post_merge_hooks?
      assert_equal 19, PipelineEvent.event_types["post_merge_hooks"]
    end

    test "verification_checks event type exists" do
      pipeline_run = PipelineRun.create!(nl_input: "test")
      event = pipeline_run.pipeline_events.create!(
        event_type: :verification_checks,
        stage: "execution",
        summary: { all_passed: true, summary: "1 passed, 0 failed: boot=OK" }
      )

      assert event.verification_checks?
      assert_equal 20, PipelineEvent.event_types["verification_checks"]
    end

    # --- Tier gate prompt includes updated sections ---

    test "tier gate prompt includes acceptance criteria section" do
      prompt = ArnoldPipeline::Prompts::TierGate.system_prompt
      assert_includes prompt, "Acceptance Criteria Evaluation"
      assert_includes prompt, "Verified (programmatic)"
      assert_includes prompt, "Failed (programmatic)"
      assert_includes prompt, "Unverified"
    end

    test "tier gate prompt includes empirical verification results section" do
      prompt = ArnoldPipeline::Prompts::TierGate.system_prompt
      assert_includes prompt, "Empirical Verification Results"
      assert_includes prompt, "pass/fail"
      assert_includes prompt, "architectural quality"
    end

    test "user_prompt includes acceptance criteria when provided" do
      prompt = ArnoldPipeline::Prompts::TierGate.user_prompt(
        tier_number: 0,
        task_summaries: "- Setup DB",
        diffs: "diff",
        acceptance_criteria_summary: "**Verified**: file exists"
      )
      assert_includes prompt, "### Acceptance Criteria Results"
      assert_includes prompt, "file exists"
    end

    test "user_prompt omits acceptance criteria when nil" do
      prompt = ArnoldPipeline::Prompts::TierGate.user_prompt(
        tier_number: 0,
        task_summaries: "- Setup DB",
        diffs: "diff",
        acceptance_criteria_summary: nil
      )
      refute_includes prompt, "Acceptance Criteria Results"
    end

    test "user_prompt includes verification results when provided" do
      results = {
        all_passed: true,
        summary: "1 passed, 0 failed: boot=OK",
        checks: [{ name: "boot", type: :boot, success: true, stdout: "", stderr: "" }]
      }
      prompt = ArnoldPipeline::Prompts::TierGate.user_prompt(
        tier_number: 0,
        task_summaries: "- Setup DB",
        diffs: "diff",
        verification_results: results
      )
      assert_includes prompt, "### Empirical Verification Results"
      assert_includes prompt, "ALL PASSED"
      assert_includes prompt, "boot"
    end

    test "user_prompt omits verification results when nil" do
      prompt = ArnoldPipeline::Prompts::TierGate.user_prompt(
        tier_number: 0,
        task_summaries: "- Setup DB",
        diffs: "diff",
        verification_results: nil
      )
      refute_includes prompt, "Empirical Verification Results"
    end

    test "user_prompt places acceptance criteria and verification before repo baseline" do
      results = {
        all_passed: true,
        summary: "1 passed, 0 failed: boot=OK",
        checks: [{ name: "boot", type: :boot, success: true, stdout: "", stderr: "" }]
      }
      prompt = ArnoldPipeline::Prompts::TierGate.user_prompt(
        tier_number: 0,
        task_summaries: "- Setup DB",
        diffs: "diff",
        acceptance_criteria_summary: "criteria data",
        verification_results: results,
        repo_context: "  config/ (1 files): routes.rb",
        comments: "some comments"
      )

      criteria_pos = prompt.index("Acceptance Criteria Results")
      verification_pos = prompt.index("Empirical Verification Results")
      baseline_pos = prompt.index("Repository Baseline")
      comments_pos = prompt.index("Task Comments / Agent Feedback")

      assert criteria_pos < verification_pos, "Criteria should appear before verification"
      assert verification_pos < baseline_pos, "Verification should appear before baseline"
      assert baseline_pos < comments_pos, "Baseline should appear before comments"
    end

    # --- TierGateCheck agent passes new params ---

    test "tier_gate_check.call accepts acceptance_criteria_summary and verification_results" do
      captured_kwargs = nil
      @tier_gate_check.stubs(:call).with { |**kwargs|
        captured_kwargs = kwargs
        true
      }.returns({
        "pass" => true,
        "issues" => [],
        "context_summary" => "Done.",
        "corrective_tasks" => []
      })

      pipeline_run = PipelineRun.create!(nl_input: "Build an app")
      task = pipeline_run.tasks.create!(
        title: "Setup DB", position: 0, tier: 0,
        external_id: "42", status: :completed,
        result_diff: '[{"filename":"schema.rb"}]'
      )

      verification_results = { all_passed: true, summary: "ok", checks: [] }
      @engine.send(:run_tier_gate!, pipeline_run, 0, [task],
                   acceptance_criteria_summary: "criteria", verification_results: verification_results)

      assert_not_nil captured_kwargs
      assert_equal "criteria", captured_kwargs[:acceptance_criteria_summary]
      assert_equal verification_results, captured_kwargs[:verification_results]
    end

    # --- Criteria check integration ---

    test "run_criteria_check! formats results from CriteriaChecker" do
      tmpdir = Dir.mktmpdir("arnold_criteria_test")

      ArnoldPipeline.configure do |c|
        c.llm_api_key = "test"
        c.github_token = "test"
        c.github_repo = "owner/repo"
        c.claude_code_repo_path = tmpdir
      end

      pipeline_run = PipelineRun.create!(nl_input: "Build an app")
      task = pipeline_run.tasks.create!(
        title: "Setup DB", position: 0, tier: 0,
        acceptance_criteria: [
          { "type" => "file_exists", "description" => "Schema file exists", "pattern" => "db/schema.rb" },
          { "type" => "http", "description" => "API responds", "method" => "GET", "path" => "/api/health" }
        ]
      )

      verified_criterion = AcceptanceCriterion.new(type: "file_exists", description: "Schema file exists", params: { "pattern" => "db/schema.rb" })
      unverified_criterion = AcceptanceCriterion.new(type: "http", description: "API responds", params: { "method" => "GET", "path" => "/api/health" })

      CriteriaChecker.stubs(:call).returns({
        verified: [verified_criterion],
        failed: [],
        unverified: [unverified_criterion]
      })

      result = @engine.send(:run_criteria_check!, pipeline_run, [task])

      assert_not_nil result
      assert_includes result, "[PASS] Schema file exists"
      assert_includes result, "[EVALUATE] API responds"
    ensure
      FileUtils.rm_rf(tmpdir) if tmpdir
    end

    test "run_criteria_check! returns nil when no acceptance criteria" do
      pipeline_run = PipelineRun.create!(nl_input: "Build an app")
      task = pipeline_run.tasks.create!(
        title: "Setup DB", position: 0, tier: 0,
        acceptance_criteria: []
      )

      result = @engine.send(:run_criteria_check!, pipeline_run, [task])
      assert_nil result
    end

    test "run_criteria_check! returns nil when no repo_path configured" do
      ArnoldPipeline.configure do |c|
        c.llm_api_key = "test"
        c.github_token = "test"
        c.github_repo = "owner/repo"
        c.claude_code_repo_path = nil
      end

      pipeline_run = PipelineRun.create!(nl_input: "Build an app")
      task = pipeline_run.tasks.create!(
        title: "Setup DB", position: 0, tier: 0,
        acceptance_criteria: [
          { "type" => "file_exists", "description" => "test", "pattern" => "Gemfile" }
        ]
      )

      result = @engine.send(:run_criteria_check!, pipeline_run, [task])
      assert_nil result
    end

    # --- Post-merge hooks integration ---

    test "run_post_merge_hooks returns empty array when no hooks configured" do
      pipeline_run = PipelineRun.create!(nl_input: "Build an app")
      task = pipeline_run.tasks.create!(title: "Setup DB", position: 0, tier: 0)

      result = @engine.send(:run_post_merge_hooks, [task])
      assert_equal [], result
    end

    test "run_post_merge_hooks returns empty array when no repo_path" do
      ArnoldPipeline.configure do |c|
        c.llm_api_key = "test"
        c.github_token = "test"
        c.github_repo = "owner/repo"
        c.claude_code_repo_path = nil
        c.post_merge_hooks = [{ name: "lint", trigger_paths: ["*.rb"], command: "rubocop" }]
      end

      pipeline_run = PipelineRun.create!(nl_input: "Build an app")
      task = pipeline_run.tasks.create!(title: "Setup DB", position: 0, tier: 0)

      result = @engine.send(:run_post_merge_hooks, [task])
      assert_equal [], result
    end

    # --- Verification checks integration ---

    test "run_verification_checks returns nil when no checks configured" do
      result = @engine.send(:run_verification_checks)
      assert_nil result
    end

    test "run_verification_checks returns nil when no repo_path" do
      ArnoldPipeline.configure do |c|
        c.llm_api_key = "test"
        c.github_token = "test"
        c.github_repo = "owner/repo"
        c.claude_code_repo_path = nil
        c.verification_checks = [{ name: "boot", command: "bin/rails runner 'true'" }]
      end

      result = @engine.send(:run_verification_checks)
      assert_nil result
    end

    # --- format_criteria_summary ---

    test "format_criteria_summary formats verified, failed, and unverified" do
      verified = AcceptanceCriterion.new(type: "file_exists", description: "Gemfile exists", params: {})
      failed = AcceptanceCriterion.new(type: "route_exists", description: "POST /users route", params: {})
      unverified = AcceptanceCriterion.new(type: "http", description: "GET /health returns 200", params: {})

      result = @engine.send(:format_criteria_summary, {
        verified: [verified],
        failed: [failed],
        unverified: [unverified]
      })

      assert_includes result, "[PASS] Gemfile exists (file_exists)"
      assert_includes result, "[FAIL] POST /users route (route_exists)"
      assert_includes result, "[EVALUATE] GET /health returns 200 (http)"
    end

    test "format_criteria_summary returns nil for empty results" do
      result = @engine.send(:format_criteria_summary, {
        verified: [],
        failed: [],
        unverified: []
      })

      assert_nil result
    end

    # --- format_verification_results ---

    test "format_verification_results formats passing results" do
      results = {
        all_passed: true,
        summary: "2 passed, 0 failed: boot=OK, tests=OK",
        checks: [
          { name: "boot", type: :boot, success: true, stdout: "", stderr: "" },
          { name: "tests", type: :test_suite, success: true, stdout: "all green", stderr: "" }
        ]
      }

      formatted = Prompts::TierGate.format_verification_results(results)
      assert_includes formatted, "ALL PASSED"
      assert_includes formatted, "boot"
      assert_includes formatted, "tests"
    end

    test "format_verification_results includes failure output" do
      results = {
        all_passed: false,
        summary: "1 passed, 1 failed: boot=OK, tests=FAIL",
        checks: [
          { name: "boot", type: :boot, success: true, stdout: "", stderr: "" },
          { name: "tests", type: :test_suite, success: false, stdout: "", stderr: "3 failures\ntest_auth: Expected 200" }
        ]
      }

      formatted = Prompts::TierGate.format_verification_results(results)
      assert_includes formatted, "SOME FAILED"
      assert_includes formatted, "3 failures"
      assert_includes formatted, "test_auth"
    end
  end
end

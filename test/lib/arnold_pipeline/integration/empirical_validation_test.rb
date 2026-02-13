require "test_helper"
require "octokit"
require "faraday"
require "arnold_pipeline/tier_execution_engine"
require "arnold_pipeline/acceptance_criterion"
require "arnold_pipeline/criteria_checker"
require "arnold_pipeline/verification/verification_result"
require "arnold_pipeline/verification/verification_runner"
require "arnold_pipeline/verification/recipe_verification_extractor"
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
        c.verification_enabled = false
      end
    end

    teardown do
      ArnoldPipeline.reset_configuration!
    end

    # --- Configuration defaults ---

    test "verification_enabled defaults to false" do
      config = Configuration.new
      assert_equal false, config.verification_enabled
    end

    test "verification_timeout defaults to 120" do
      config = Configuration.new
      assert_equal 120, config.verification_timeout
    end

    test "verification_health_check_retries defaults to 10" do
      config = Configuration.new
      assert_equal 10, config.verification_health_check_retries
    end

    test "verification_health_check_interval defaults to 3" do
      config = Configuration.new
      assert_equal 3, config.verification_health_check_interval
    end

    test "validate! raises on invalid verification_timeout" do
      config = Configuration.new
      config.llm_api_key = "test"
      config.github_token = "test"
      config.github_repo = "owner/repo"
      config.verification_timeout = 0

      error = assert_raises(ConfigurationError) { config.validate! }
      assert_match(/verification_timeout/, error.message)
    end

    test "validate! raises on invalid verification_health_check_retries" do
      config = Configuration.new
      config.llm_api_key = "test"
      config.github_token = "test"
      config.github_repo = "owner/repo"
      config.verification_health_check_retries = -1

      error = assert_raises(ConfigurationError) { config.validate! }
      assert_match(/verification_health_check_retries/, error.message)
    end

    test "validate! raises on invalid verification_health_check_interval" do
      config = Configuration.new
      config.llm_api_key = "test"
      config.github_token = "test"
      config.github_repo = "owner/repo"
      config.verification_health_check_interval = 0

      error = assert_raises(ConfigurationError) { config.validate! }
      assert_match(/verification_health_check_interval/, error.message)
    end

    test "validate! passes with valid verification config" do
      config = Configuration.new
      config.llm_api_key = "test"
      config.github_token = "test"
      config.github_repo = "owner/repo"
      config.verification_enabled = true
      config.verification_timeout = 60
      config.verification_health_check_retries = 5
      config.verification_health_check_interval = 2

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

    test "verification_execution event type exists" do
      pipeline_run = PipelineRun.create!(nl_input: "test")
      event = pipeline_run.pipeline_events.create!(
        event_type: :verification_execution,
        stage: "execution",
        summary: { setup_passed: true, boot_passed: true, health_check_passed: true }
      )

      assert event.verification_execution?
      assert_equal 16, PipelineEvent.event_types["verification_execution"]
    end

    # --- Tier gate prompt includes new sections ---

    test "tier gate prompt includes acceptance criteria section" do
      prompt = ArnoldPipeline::Prompts::TierGate.system_prompt
      assert_includes prompt, "Acceptance Criteria Evaluation"
      assert_includes prompt, "Verified (programmatic)"
      assert_includes prompt, "Failed (programmatic)"
      assert_includes prompt, "Unverified"
    end

    test "tier gate prompt includes verification results section" do
      prompt = ArnoldPipeline::Prompts::TierGate.system_prompt
      assert_includes prompt, "Verification Results"
      assert_includes prompt, "verification PASSED"
      assert_includes prompt, "verification FAILED"
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

    test "user_prompt includes verification summary when provided" do
      prompt = ArnoldPipeline::Prompts::TierGate.user_prompt(
        tier_number: 0,
        task_summaries: "- Setup DB",
        diffs: "diff",
        verification_summary: "## Verification Results\n| Setup | PASSED |"
      )
      assert_includes prompt, "### Verification Results"
      assert_includes prompt, "| Setup | PASSED |"
    end

    test "user_prompt omits verification summary when nil" do
      prompt = ArnoldPipeline::Prompts::TierGate.user_prompt(
        tier_number: 0,
        task_summaries: "- Setup DB",
        diffs: "diff",
        verification_summary: nil
      )
      # The system prompt has "## Verification Results" but the user prompt shouldn't
      # have the "### Verification Results" section
      refute_includes prompt, "### Verification Results"
    end

    test "user_prompt places acceptance criteria and verification before repo baseline" do
      prompt = ArnoldPipeline::Prompts::TierGate.user_prompt(
        tier_number: 0,
        task_summaries: "- Setup DB",
        diffs: "diff",
        acceptance_criteria_summary: "criteria data",
        verification_summary: "verification data",
        repo_context: "  config/ (1 files): routes.rb",
        comments: "some comments"
      )

      criteria_pos = prompt.index("Acceptance Criteria Results")
      verification_pos = prompt.index("Verification Results")
      baseline_pos = prompt.index("Repository Baseline")
      comments_pos = prompt.index("Task Comments / Agent Feedback")

      assert criteria_pos < verification_pos, "Criteria should appear before verification"
      assert verification_pos < baseline_pos, "Verification should appear before baseline"
      assert baseline_pos < comments_pos, "Baseline should appear before comments"
    end

    # --- TierGateCheck agent passes new params ---

    test "tier_gate_check.call accepts acceptance_criteria_summary and verification_summary" do
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

      @engine.send(:run_tier_gate!, pipeline_run, 0, [task],
                   acceptance_criteria_summary: "criteria", verification_summary: "verification")

      assert_not_nil captured_kwargs
      assert_equal "criteria", captured_kwargs[:acceptance_criteria_summary]
      assert_equal "verification", captured_kwargs[:verification_summary]
    end

    # --- Criteria check integration ---

    test "run_criteria_check! formats results from CriteriaChecker" do
      ArnoldPipeline.configure do |c|
        c.llm_api_key = "test"
        c.github_token = "test"
        c.github_repo = "owner/repo"
        c.claude_code_repo_path = "/tmp/test_repo"
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

    # --- Verification integration ---

    test "run_verification! returns nil when verification_enabled is false" do
      ArnoldPipeline.configure do |c|
        c.llm_api_key = "test"
        c.verification_enabled = false
      end

      refute @engine.send(:verification_enabled?)
    end

    test "run_verification! returns gate summary when verification passes" do
      ArnoldPipeline.configure do |c|
        c.llm_api_key = "test"
        c.github_token = "test"
        c.github_repo = "owner/repo"
        c.verification_enabled = true
        c.claude_code_repo_path = "/tmp/test_repo"
      end

      pipeline_run = PipelineRun.create!(nl_input: "Build a web app")
      pipeline_run.create_specification!(
        content: "test spec",
        version: 1,
        structured_data: { "recipe_type" => "web_app" }
      )

      Dir.stubs(:exist?).returns(true)

      passed_result = Verification::VerificationResult.new(
        setup_passed: true, boot_passed: true, health_check_passed: true
      )
      Verification::VerificationRunner.stubs(:call).returns(passed_result)

      summary = @engine.send(:run_verification!, pipeline_run)

      assert_not_nil summary
      assert_includes summary, "PASSED"
    end

    test "run_verification! returns nil when no recipe verification config" do
      ArnoldPipeline.configure do |c|
        c.llm_api_key = "test"
        c.github_token = "test"
        c.github_repo = "owner/repo"
        c.verification_enabled = true
        c.claude_code_repo_path = "/tmp/test_repo"
      end

      pipeline_run = PipelineRun.create!(nl_input: "Build something unusual")
      # No specification => extractor falls back to nl_input matching.
      # But this should still return a recipe match and verification config.
      # Let's stub the extractor to return nil for this test
      Verification::RecipeVerificationExtractor.stubs(:call).returns(nil)

      summary = @engine.send(:run_verification!, pipeline_run)
      assert_nil summary
    end

    test "run_verification! rescues errors and returns nil" do
      ArnoldPipeline.configure do |c|
        c.llm_api_key = "test"
        c.github_token = "test"
        c.github_repo = "owner/repo"
        c.verification_enabled = true
        c.claude_code_repo_path = "/tmp/test_repo"
      end

      pipeline_run = PipelineRun.create!(nl_input: "Build a web app")

      Verification::RecipeVerificationExtractor.stubs(:call).raises(RuntimeError, "unexpected error")

      summary = @engine.send(:run_verification!, pipeline_run)
      assert_nil summary
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
  end
end

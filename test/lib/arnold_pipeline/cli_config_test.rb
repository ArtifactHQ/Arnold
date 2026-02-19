require "test_helper"
require "arnold_pipeline/cli"
require "arnold_pipeline/orchestrator"

module ArnoldPipeline
  class CliConfigTest < ActiveSupport::TestCase
    teardown do
      ArnoldPipeline.reset_configuration!
    end

    test "apply_config loads tier_gate_enabled" do
      cli = Cli.new
      cli.send(:apply_config!, { tier_gate_enabled: false })
      refute ArnoldPipeline.configuration.tier_gate_enabled
    end

    test "apply_config loads context_propagation_enabled" do
      cli = Cli.new
      cli.send(:apply_config!, { context_propagation_enabled: false })
      refute ArnoldPipeline.configuration.context_propagation_enabled
    end

    test "apply_config loads max_tier_retries" do
      cli = Cli.new
      cli.send(:apply_config!, { max_tier_retries: 4 })
      assert_equal 4, ArnoldPipeline.configuration.max_tier_retries
    end

    test "apply_config loads workflow_status_enabled" do
      cli = Cli.new
      cli.send(:apply_config!, { workflow_status_enabled: false })
      refute ArnoldPipeline.configuration.workflow_status_enabled
    end

    test "apply_config loads workflow_branch_pattern as Regexp" do
      cli = Cli.new
      cli.send(:apply_config!, { workflow_branch_pattern: "feature[-_]?\\d+" })
      assert_kind_of Regexp, ArnoldPipeline.configuration.workflow_branch_pattern
      assert ArnoldPipeline.configuration.workflow_branch_pattern.match?("feature-123")
    end

    test "apply_config preserves tier_gate_enabled default when key absent" do
      cli = Cli.new
      cli.send(:apply_config!, {})
      assert ArnoldPipeline.configuration.tier_gate_enabled
    end

    test "apply_config handles false boolean correctly for tier_gate_enabled" do
      cli = Cli.new
      cli.send(:apply_config!, { tier_gate_enabled: false })
      refute ArnoldPipeline.configuration.tier_gate_enabled
    end

    test "run --dry-run shows preview output with spec and tasks" do
      mock_run = PipelineRun.create!(nl_input: "Build an app", status: :paused)
      mock_run.create_specification!(content: "# App Spec", version: 1)
      mock_run.tasks.create!(title: "Setup", tier: 0, position: 0, status: :pending)

      mock_orchestrator = mock("orchestrator")
      mock_orchestrator.expects(:call).with(nl_input: "Build an app", stop_after: :tasks).returns(mock_run)
      ArnoldPipeline::Orchestrator.stubs(:new).returns(mock_orchestrator)
      require "arnold_pipeline/cli/setup_wizard"
      ArnoldPipeline::CliModule::SetupWizard.stubs(:api_key_available?).returns(true)

      output = capture_output { Cli.start(["run", "--dry-run", "Build an app"]) }
      assert_match(/Arnold Preview/, output)
      assert_match(/# App Spec/, output)
      assert_match(/1 tasks, 1 tiers/, output)
      assert_match(/Run without --preview to execute/, output)
    ensure
      ArnoldPipeline.reset_configuration!
    end

    test "load_config! sets execution_provider from CLI flag" do
      cli = Cli.new
      cli.send(:load_config!, { execution_provider: "claude_code" })
      assert_equal :claude_code, ArnoldPipeline.configuration.execution_provider
    end

    test "load_config! sets claude_code_repo_path from CLI flag" do
      cli = Cli.new
      cli.send(:load_config!, { claude_code_repo_path: "/tmp/my-repo" })
      assert_equal "/tmp/my-repo", ArnoldPipeline.configuration.claude_code_repo_path
    end

    test "load_config! sets claude_code_model from CLI flag" do
      cli = Cli.new
      cli.send(:load_config!, { claude_code_model: "opus" })
      assert_equal "opus", ArnoldPipeline.configuration.claude_code_model
    end

    test "load_config! sets claude_code_max_turns from CLI flag" do
      cli = Cli.new
      cli.send(:load_config!, { claude_code_max_turns: 50 })
      assert_equal 50, ArnoldPipeline.configuration.claude_code_max_turns
    end

    test "load_config! sets claude_code_permission_mode from CLI flag" do
      cli = Cli.new
      cli.send(:load_config!, { claude_code_permission_mode: "manual" })
      assert_equal "manual", ArnoldPipeline.configuration.claude_code_permission_mode
    end

    test "apply_config! loads claude_code_repo_path from YAML" do
      cli = Cli.new
      cli.send(:apply_config!, { claude_code_repo_path: "/home/user/project" })
      assert_equal "/home/user/project", ArnoldPipeline.configuration.claude_code_repo_path
    end

    test "apply_config! loads claude_code_model from YAML" do
      cli = Cli.new
      cli.send(:apply_config!, { claude_code_model: "haiku" })
      assert_equal "haiku", ArnoldPipeline.configuration.claude_code_model
    end

    test "apply_config! loads claude_code_max_turns from YAML" do
      cli = Cli.new
      cli.send(:apply_config!, { claude_code_max_turns: 100 })
      assert_equal 100, ArnoldPipeline.configuration.claude_code_max_turns
    end

    test "apply_config! loads claude_code_permission_mode from YAML" do
      cli = Cli.new
      cli.send(:apply_config!, { claude_code_permission_mode: "plan" })
      assert_equal "plan", ArnoldPipeline.configuration.claude_code_permission_mode
    end

    test "apply_config! loads execution_provider as symbol from YAML" do
      cli = Cli.new
      cli.send(:apply_config!, { execution_provider: "claude_code" })
      assert_equal :claude_code, ArnoldPipeline.configuration.execution_provider
    end

    test "CLI flags override YAML values for claude_code settings" do
      cli = Cli.new
      cli.send(:apply_config!, { claude_code_model: "opus", execution_provider: "github" })
      cli.send(:load_config!, { claude_code_model: "sonnet", execution_provider: "claude_code" })
      assert_equal "sonnet", ArnoldPipeline.configuration.claude_code_model
      assert_equal :claude_code, ArnoldPipeline.configuration.execution_provider
    end

    private

    def capture_output
      original_stdout = $stdout
      $stdout = StringIO.new
      yield
      $stdout.string
    ensure
      $stdout = original_stdout
    end
  end
end

require "test_helper"
require "arnold_pipeline/cli"

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

    test "run --dry-run shows accurate message about GitHub issues" do
      mock_run = PipelineRun.create!(nl_input: "Build an app", status: :paused)
      mock_run.tasks.create!(title: "Setup", tier: 0, position: 0, status: :pending)

      mock_orchestrator = mock("orchestrator")
      mock_orchestrator.expects(:call).returns(mock_run)
      ArnoldPipeline::Orchestrator.stubs(:new).returns(mock_orchestrator)
      ArnoldPipeline.configure { |c| c.github_repo = "test/repo" }

      output = capture_output { Cli.start(["run", "--dry-run", "Build an app"]) }
      assert_match(/DRY RUN/, output)
      assert_match(/no GitHub issues will be created/, output)
      refute_match(/no changes will be made/, output)
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

require "test_helper"
require "arnold_pipeline/cli"

module ArnoldPipeline
  class CliAnalyzeTest < ActiveSupport::TestCase
    setup do
      ArnoldPipeline.reset_configuration!
    end

    teardown do
      ArnoldPipeline.reset_configuration!
    end

    test "analyze command requires valid directory" do
      cli = Cli.new
      assert_raises(SystemExit) do
        cli.invoke(:analyze, [ "/nonexistent/path/foo" ])
      end
    end

    test "analyze command calls orchestrator.analyze_codebase!" do
      Dir.mktmpdir do |dir|
        profile = mock("profile")
        profile.stubs(:project_name).returns("Test App")
        profile.stubs(:stack_fingerprint).returns({ "language" => "ruby", "framework" => "rails" })
        profile.stubs(:stack_language).returns("ruby")
        profile.stubs(:stack_framework).returns("rails")
        profile.stubs(:confidence).returns(85)
        profile.stubs(:health_baseline).returns({ "summary" => "3 passed, 0 failed" })
        profile.stubs(:recipe_alignment).returns({ "concerns" => { "auth" => { "status" => "present" } } })
        profile.stubs(:feature_inventories).returns([ { "features" => [ { "name" => "Login" } ] } ])
        profile.stubs(:pipeline_run_id).returns(1)
        profile.stubs(:conventions).returns({})
        profile.stubs(:documentation_fidelity).returns(nil)
        profile.stubs(:change_surface).returns(nil)
        profile.stubs(:token_budget_used).returns(5000)
        profile.stubs(:analyzed_at).returns(Time.current)

        orchestrator = mock("orchestrator")
        orchestrator.expects(:analyze_codebase!).with(
          repo_path: dir,
          description: nil,
          reference_materials: []
        ).returns(profile)

        ArnoldPipeline::Orchestrator.stubs(:new).returns(orchestrator)

        cli = Cli.new([], { quiet: true })
        cli.invoke(:analyze, [ dir ])
      end
    end
  end
end

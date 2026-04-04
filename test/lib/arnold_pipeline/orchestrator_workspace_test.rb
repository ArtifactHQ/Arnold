require "test_helper"
require "arnold_pipeline/orchestrator"
require "arnold_pipeline/brownfield/workspace_manifest"
require "yaml"

module ArnoldPipeline
  class OrchestratorWorkspaceTest < ActiveSupport::TestCase
    setup do
      ArnoldPipeline.configure do |c|
        c.llm_api_key = "test"
      end
    end

    teardown do
      ArnoldPipeline.reset_configuration!
    end

    test "analyze_workspace! calls analyze_codebase! once per root" do
      manifest = Brownfield::WorkspaceManifest.new({
        "project" => "MyApp",
        "roots" => [
          { "path" => "/tmp/backend", "hint" => "rails", "name" => "backend" },
          { "path" => "/tmp/frontend", "hint" => "react", "name" => "frontend" }
        ]
      })

      orchestrator = Orchestrator.new(logger: Logger.new(File::NULL))

      profile1 = stub_profile("Backend")
      profile2 = stub_profile("Frontend")

      call_count = sequence("analyze_calls")
      orchestrator.expects(:analyze_codebase!).with(
        repo_path: "/tmp/backend",
        description: "analyze this",
        reference_materials: ["ref.md"]
      ).in_sequence(call_count).returns(profile1)

      orchestrator.expects(:analyze_codebase!).with(
        repo_path: "/tmp/frontend",
        description: "analyze this",
        reference_materials: ["ref.md"]
      ).in_sequence(call_count).returns(profile2)

      profiles = orchestrator.analyze_workspace!(
        manifest:,
        description: "analyze this",
        reference_materials: ["ref.md"]
      )

      assert_equal 2, profiles.size
      assert_equal "Backend", profiles[0].project_name
      assert_equal "Frontend", profiles[1].project_name
    end

    test "analyze_workspace! applies stack_detection_overrides per root" do
      manifest = Brownfield::WorkspaceManifest.new({
        "project" => "MyApp",
        "roots" => [
          { "path" => "/tmp/api", "hint" => "rails", "name" => "api" },
          { "path" => "/tmp/web", "name" => "web" }
        ]
      })

      orchestrator = Orchestrator.new(logger: Logger.new(File::NULL))
      config = ArnoldPipeline.configuration

      captured_overrides = []
      orchestrator.stubs(:analyze_codebase!).with { |kwargs|
        captured_overrides << config.stack_detection_overrides.dup
        true
      }.returns(stub_profile("Root"))

      orchestrator.analyze_workspace!(manifest:)

      # First root had rails hint
      assert_equal({ framework: "rails" }, captured_overrides[0])
      # Second root had no hint
      assert_equal({}, captured_overrides[1])
      # After completion, overrides are restored
      assert_equal({}, config.stack_detection_overrides)
    end

    test "analyze_workspace! restores overrides on error" do
      manifest = Brownfield::WorkspaceManifest.new({
        "project" => "MyApp",
        "roots" => [{ "path" => "/tmp/boom", "hint" => "rails" }]
      })

      orchestrator = Orchestrator.new(logger: Logger.new(File::NULL))
      config = ArnoldPipeline.configuration
      config.stack_detection_overrides = { language: "original" }

      orchestrator.stubs(:analyze_codebase!).raises(RuntimeError, "boom")

      assert_raises(RuntimeError) do
        orchestrator.analyze_workspace!(manifest:)
      end

      assert_equal({ language: "original" }, config.stack_detection_overrides)
    end

    test "analyze_workspace! tags pipeline runs with workspace metadata" do
      manifest = Brownfield::WorkspaceManifest.new({
        "project" => "MyApp",
        "roots" => [
          { "path" => "/tmp/api", "name" => "api" },
          { "path" => "/tmp/web", "name" => "web" }
        ]
      })

      orchestrator = Orchestrator.new(logger: Logger.new(File::NULL))

      run1 = PipelineRun.create!(nl_input: "test1", status: :completed)
      run2 = PipelineRun.create!(nl_input: "test2", status: :completed)

      profile1 = stub_profile("Api", pipeline_run: run1)
      profile2 = stub_profile("Web", pipeline_run: run2)

      call_count = sequence("calls")
      orchestrator.expects(:analyze_codebase!).in_sequence(call_count).returns(profile1)
      orchestrator.expects(:analyze_codebase!).in_sequence(call_count).returns(profile2)

      orchestrator.analyze_workspace!(manifest:)

      run1.reload
      run2.reload

      assert_equal "MyApp", run1.metadata["workspace_project"]
      assert_equal "api", run1.metadata["workspace_root"]
      assert run1.metadata["workspace_id"].present?

      assert_equal "MyApp", run2.metadata["workspace_project"]
      assert_equal "web", run2.metadata["workspace_root"]

      # Both runs share the same workspace_id
      assert_equal run1.metadata["workspace_id"], run2.metadata["workspace_id"]
    end

    test "analyze_workspace! returns array of profiles" do
      manifest = Brownfield::WorkspaceManifest.new({
        "project" => "Solo",
        "roots" => [{ "path" => "/tmp/app" }]
      })

      orchestrator = Orchestrator.new(logger: Logger.new(File::NULL))
      profile = stub_profile("App")
      orchestrator.stubs(:analyze_codebase!).returns(profile)

      result = orchestrator.analyze_workspace!(manifest:)

      assert_instance_of Array, result
      assert_equal 1, result.size
    end

    private

    def stub_profile(name, pipeline_run: nil)
      run = pipeline_run || PipelineRun.create!(nl_input: "test", status: :completed)
      profile = mock("profile_#{name}")
      profile.stubs(:project_name).returns(name)
      profile.stubs(:pipeline_run).returns(run)
      profile.stubs(:pipeline_run_id).returns(run.id)
      profile
    end
  end
end

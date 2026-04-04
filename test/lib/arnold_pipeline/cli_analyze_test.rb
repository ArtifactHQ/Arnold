require "test_helper"
require "arnold_pipeline/cli"
require "arnold_pipeline/orchestrator"
require "yaml"

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

    test "analyze with no path and no workspace exits with error" do
      assert_raises(SystemExit) do
        capture_output_and_errors { Cli.start([ "analyze" ]) }
      end
    end

    test "analyze command calls orchestrator.analyze_codebase!" do
      Dir.mktmpdir do |dir|
        profile = stub_profile

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

    test "analyze uses configured reference_materials when no flag is passed" do
      Dir.mktmpdir do |dir|
        ArnoldPipeline.configuration.reference_materials = [ "docs/api.md" ]

        profile = stub_profile

        orchestrator = mock("orchestrator")
        orchestrator.expects(:analyze_codebase!).with(
          repo_path: dir,
          description: nil,
          reference_materials: [ "docs/api.md" ]
        ).returns(profile)

        ArnoldPipeline::Orchestrator.stubs(:new).returns(orchestrator)

        cli = Cli.new([], { quiet: true })
        cli.invoke(:analyze, [ dir ])
      end
    end

    # --- Workspace mode tests ---

    test "analyze --workspace calls orchestrator.analyze_workspace!" do
      Dir.mktmpdir do |dir|
        backend = File.join(dir, "backend")
        frontend = File.join(dir, "frontend")
        Dir.mkdir(backend)
        Dir.mkdir(frontend)

        manifest_path = File.join(dir, "workspace.yml")
        File.write(manifest_path, YAML.dump({
          "project" => "MyApp",
          "roots" => [
            { "path" => "./backend", "hint" => "rails" },
            { "path" => "./frontend", "hint" => "react" }
          ]
        }))

        profiles = [ stub_profile(name: "Backend"), stub_profile(name: "Frontend") ]

        orchestrator = mock("orchestrator")
        orchestrator.expects(:analyze_workspace!).with { |kwargs|
          kwargs[:manifest].is_a?(Brownfield::WorkspaceManifest) &&
            kwargs[:manifest].project_name == "MyApp" &&
            kwargs[:manifest].roots.size == 2
        }.returns(profiles)

        ArnoldPipeline::Orchestrator.stubs(:new).returns(orchestrator)

        cli = Cli.new([], { quiet: true, workspace: manifest_path })
        cli.invoke(:analyze)
      end
    end

    test "analyze --workspace with missing manifest file exits with error" do
      assert_raises(SystemExit) do
        capture_output_and_errors do
          cli = Cli.new([], { quiet: true, workspace: "/nonexistent/workspace.yml" })
          cli.invoke(:analyze)
        end
      end
    end

    test "analyze --workspace with missing root directory exits with error" do
      Dir.mktmpdir do |dir|
        manifest_path = File.join(dir, "workspace.yml")
        File.write(manifest_path, YAML.dump({
          "project" => "MyApp",
          "roots" => [{ "path" => "./does_not_exist" }]
        }))

        assert_raises(SystemExit) do
          capture_output_and_errors do
            cli = Cli.new([], { quiet: true, workspace: manifest_path })
            cli.invoke(:analyze)
          end
        end
      end
    end

    test "analyze --workspace json output includes root_name" do
      Dir.mktmpdir do |dir|
        backend = File.join(dir, "api")
        Dir.mkdir(backend)

        manifest_path = File.join(dir, "workspace.yml")
        File.write(manifest_path, YAML.dump({
          "project" => "Solo",
          "roots" => [{ "path" => "./api", "hint" => "rails" }]
        }))

        profiles = [ stub_profile(name: "Api") ]

        orchestrator = mock("orchestrator")
        orchestrator.stubs(:analyze_workspace!).returns(profiles)
        ArnoldPipeline::Orchestrator.stubs(:new).returns(orchestrator)

        # Capture what would be passed to `say` for JSON output
        captured_json = nil
        Cli.any_instance.stubs(:say).with { |msg|
          begin
            captured_json = JSON.parse(msg) if msg.include?("root_name")
          rescue
            # not JSON, skip
          end
          true
        }

        cli = Cli.new([], { json: true, quiet: true, workspace: manifest_path })
        cli.invoke(:analyze)

        assert_not_nil captured_json, "Expected JSON output with root_name"
        assert_instance_of Array, captured_json
        assert_equal "api", captured_json[0]["root_name"]
        assert_equal "Api", captured_json[0]["project_name"]
      end
    end

    test "analyze --workspace writes per-root spec files" do
      Dir.mktmpdir do |dir|
        backend = File.join(dir, "api")
        web = File.join(dir, "web")
        Dir.mkdir(backend)
        Dir.mkdir(web)

        manifest_path = File.join(dir, "workspace.yml")
        File.write(manifest_path, YAML.dump({
          "project" => "Multi",
          "roots" => [
            { "path" => "./api", "name" => "api" },
            { "path" => "./web", "name" => "web" }
          ]
        }))

        spec1 = mock("spec1")
        spec1.stubs(:content).returns("# API Spec")
        run1 = mock("run1")
        run1.stubs(:specification).returns(spec1)
        profile1 = stub_profile(name: "Api")
        profile1.stubs(:pipeline_run).returns(run1)

        spec2 = mock("spec2")
        spec2.stubs(:content).returns("# Web Spec")
        run2 = mock("run2")
        run2.stubs(:specification).returns(spec2)
        profile2 = stub_profile(name: "Web")
        profile2.stubs(:pipeline_run).returns(run2)

        orchestrator = mock("orchestrator")
        orchestrator.stubs(:analyze_workspace!).returns([ profile1, profile2 ])
        ArnoldPipeline::Orchestrator.stubs(:new).returns(orchestrator)

        output_base = File.join(dir, "output.md")
        capture_output_and_errors do
          cli = Cli.new([], { quiet: true, workspace: manifest_path, output: output_base })
          cli.invoke(:analyze)
        end

        assert File.exist?(File.join(dir, "output.api.md"))
        assert File.exist?(File.join(dir, "output.web.md"))
        assert_equal "# API Spec", File.read(File.join(dir, "output.api.md"))
        assert_equal "# Web Spec", File.read(File.join(dir, "output.web.md"))
      end
    end

    private

    def stub_profile(name: "Test App")
      profile = mock("profile_#{name}")
      profile.stubs(:project_name).returns(name)
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
      pipeline_run = mock("pipeline_run_#{name}")
      pipeline_run.stubs(:specification).returns(nil)
      profile.stubs(:pipeline_run).returns(pipeline_run)
      profile
    end

    def capture_output_and_errors(&block)
      out = StringIO.new
      err = StringIO.new
      $stdout = out
      $stderr = err
      yield
      out.string + err.string
    ensure
      $stdout = STDOUT
      $stderr = STDERR
    end

    def capture_output(&block)
      out = StringIO.new
      $stdout = out
      yield
      out.string
    ensure
      $stdout = STDOUT
    end
  end
end

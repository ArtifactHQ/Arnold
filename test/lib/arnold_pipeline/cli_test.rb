require "test_helper"
require "tempfile"
require "arnold_pipeline/cli"
require "arnold_pipeline/orchestrator"
require "arnold_pipeline/delta_presenter"

module ArnoldPipeline
  class CliTest < ActiveSupport::TestCase
    test "list shows pipeline runs" do
      PipelineRun.create!(nl_input: "Build a todo app", status: :completed)
      PipelineRun.create!(nl_input: "Build an API", status: :pending)

      output = capture_output { Cli.start([ "list" ]) }

      assert_match(/Pipeline Runs:/, output)
      assert_match(/Build a todo app/, output)
      assert_match(/Build an API/, output)
    end

    test "list shows message when no runs" do
      output = capture_output { Cli.start([ "list" ]) }
      assert_match(/No pipeline runs found/, output)
    end

    test "status shows pipeline run details" do
      run_record = PipelineRun.create!(nl_input: "Build a todo app", status: :completed)
      run_record.create_specification!(content: "# Spec", version: 1)
      run_record.iterations.create!(number: 1, decision: "done", confidence: 95)

      output = capture_output { Cli.start([ "status", run_record.id.to_s ]) }

      assert_match(/Pipeline Run ##{run_record.id}/, output)
      assert_match(/completed/, output)
      assert_match(/Spec version: 1/, output)
      assert_match(/done.*95%/, output)
    end

    test "status with non-existent ID exits with error" do
      assert_raises(SystemExit) do
        capture_output_and_errors { Cli.start([ "status", "99999" ]) }
      end
    end

    test "spec outputs specification content" do
      run_record = PipelineRun.create!(nl_input: "Build a todo app", status: :completed)
      run_record.create_specification!(content: "# Todo App Spec\n\nFeatures here.", version: 2)

      output = capture_output { Cli.start([ "spec", run_record.id.to_s ]) }

      assert_match(/# Todo App Spec/, output)
      assert_match(/Features here/, output)
    end

    test "spec outputs structured JSON with --json flag" do
      run_record = PipelineRun.create!(nl_input: "Build a todo app", status: :completed)
      run_record.create_specification!(
        content: "# Spec",
        structured_data: { "features" => [ "auth", "todos" ] },
        version: 1
      )

      output = capture_output { Cli.start([ "spec", run_record.id.to_s, "--json" ]) }

      parsed = JSON.parse(output)
      assert_equal [ "auth", "todos" ], parsed["features"]
    end

    test "spec writes to file with --output flag" do
      run_record = PipelineRun.create!(nl_input: "Build a todo app", status: :completed)
      run_record.create_specification!(content: "# Spec content", version: 1)

      outfile = File.join(Dir.tmpdir, "arnold_spec_test_#{SecureRandom.hex(4)}.md")

      stderr_output = nil
      original_stderr = $stderr
      $stderr = StringIO.new
      begin
        capture_output { Cli.start([ "spec", run_record.id.to_s, "--output", outfile ]) }
        stderr_output = $stderr.string
      ensure
        $stderr = original_stderr
      end

      assert_match(/written to/, stderr_output)
      assert_equal "# Spec content", File.read(outfile)
    ensure
      File.delete(outfile) if outfile && File.exist?(outfile)
    end

    test "spec with non-existent ID exits with error" do
      assert_raises(SystemExit) do
        capture_output_and_errors { Cli.start([ "spec", "99999" ]) }
      end
    end

    test "spec with no specification exits with error" do
      run_record = PipelineRun.create!(nl_input: "Build a todo app", status: :pending)

      assert_raises(SystemExit) do
        capture_output_and_errors { Cli.start([ "spec", run_record.id.to_s ]) }
      end
    end

    test "spec falls back to as_built_specification for brownfield runs" do
      run_record = PipelineRun.create!(nl_input: "Analyze existing app", status: :completed)
      run_record.create_as_built_specification!(
        content: "# As-Built Spec\n\nExisting features.",
        spec_type: "as_built",
        version: 1
      )

      output = capture_output { Cli.start([ "spec", run_record.id.to_s ]) }

      assert_match(/# As-Built Spec/, output)
      assert_match(/Existing features/, output)
    end

    test "version shows version string" do
      output = capture_output { Cli.start([ "version" ]) }
      assert_match(/arnold_pipeline #{ArnoldPipeline::VERSION}/, output)
    end

    test "version works without full engine loaded (standalone entrypoint)" do
      output = `ruby -I #{File.expand_path("../../../lib", __dir__)} -e 'require "arnold_pipeline/cli"; ArnoldPipeline::Cli.start(["version"])' 2>&1`
      assert_equal 0, $?.exitstatus, "Standalone version failed: #{output}"
      assert_match(/arnold_pipeline \d+\.\d+\.\d+/, output)
    end

    test "exit_on_failure? returns true" do
      assert Cli.exit_on_failure?
    end

    test "--version flag shows version string" do
      output = capture_output { Cli.start([ "--version" ]) }
      assert_match(/arnold_pipeline #{ArnoldPipeline::VERSION}/, output)
    end

    test "-v flag shows version string" do
      output = capture_output { Cli.start([ "-v" ]) }
      assert_match(/arnold_pipeline #{ArnoldPipeline::VERSION}/, output)
    end

    test "run calls orchestrator with nl_input and displays result" do
      mock_run = PipelineRun.create!(nl_input: "Build a todo app", status: :completed)

      mock_orchestrator = mock("orchestrator")
      mock_orchestrator.expects(:call).with(nl_input: "Build a todo app", stop_after: nil).returns(mock_run)

      ArnoldPipeline::Orchestrator.stubs(:new).returns(mock_orchestrator)

      output = capture_output { Cli.start([ "run", "Build a todo app" ]) }
      assert_match(/Starting pipeline for: Build a todo app/, output)
      assert_match(/Pipeline completed!/, output)
      assert_match(/Run ID: #{mock_run.id}/, output)
    end

    test "run --stop-after passes stop_after to orchestrator" do
      mock_run = PipelineRun.create!(nl_input: "test", status: :completed)
      mock_orchestrator = mock("orchestrator")
      mock_orchestrator.expects(:call).with(nl_input: "Build an app", stop_after: :spec).returns(mock_run)

      ArnoldPipeline::Orchestrator.stubs(:new).returns(mock_orchestrator)

      output = capture_output { Cli.start([ "run", "Build an app", "--stop-after", "spec" ]) }
      assert_match(/Starting pipeline/, output)
    end

    test "run --stop-after with invalid value exits with error" do
      assert_raises(SystemExit) do
        capture_output_and_errors { Cli.start([ "run", "test", "--stop-after", "invalid" ]) }
      end
    end

    test "resume calls orchestrator.resume with paused run" do
      run_record = PipelineRun.create!(nl_input: "Build a todo app", status: :paused)
      mock_orchestrator = mock("orchestrator")
      mock_orchestrator.expects(:resume).with(pipeline_run: run_record, stop_after: nil).returns(run_record)

      ArnoldPipeline::Orchestrator.stubs(:new).returns(mock_orchestrator)

      output = capture_output { Cli.start([ "resume", run_record.id.to_s ]) }
      assert_match(/Resuming pipeline run/, output)
    end

    test "resume calls orchestrator.resume with failed run" do
      run_record = PipelineRun.create!(nl_input: "Build a todo app", status: :failed)
      mock_orchestrator = mock("orchestrator")
      mock_orchestrator.expects(:resume).with(pipeline_run: run_record, stop_after: nil).returns(run_record)

      ArnoldPipeline::Orchestrator.stubs(:new).returns(mock_orchestrator)

      output = capture_output { Cli.start([ "resume", run_record.id.to_s ]) }
      assert_match(/Resuming pipeline run/, output)
    end

    test "resume with non-existent ID exits with error" do
      assert_raises(SystemExit) do
        capture_output_and_errors { Cli.start([ "resume", "99999" ]) }
      end
    end

    test "resume with completed run exits with error" do
      run_record = PipelineRun.create!(nl_input: "Build a todo app", status: :completed)

      assert_raises(SystemExit) do
        capture_output_and_errors { Cli.start([ "resume", run_record.id.to_s ]) }
      end
    end

    test "resume passes --stop-after to orchestrator" do
      run_record = PipelineRun.create!(nl_input: "Build a todo app", status: :paused)
      mock_orchestrator = mock("orchestrator")
      mock_orchestrator.expects(:resume).with(pipeline_run: run_record, stop_after: :tasks).returns(run_record)

      ArnoldPipeline::Orchestrator.stubs(:new).returns(mock_orchestrator)

      output = capture_output { Cli.start([ "resume", run_record.id.to_s, "--stop-after", "tasks" ]) }
      assert_match(/Resuming pipeline run/, output)
    end

    test "run shows friendly message for ConfigurationError" do
      ArnoldPipeline::Orchestrator.stubs(:new).raises(ArnoldPipeline::ConfigurationError, "LLM API key is required")

      stderr_output = capture_stderr_through_exit { Cli.start([ "run", "Build an app" ]) }
      assert_match(/Configuration error:.*LLM API key is required/, stderr_output)
    end

    test "run shows friendly message for missing config file" do
      stderr_output = capture_stderr_through_exit { Cli.start([ "run", "Build an app", "--config", "/nonexistent/config.yml" ]) }
      assert_match(/File not found/, stderr_output)
    end

    test "run shows friendly message for invalid YAML config" do
      bad_yaml = File.join(Dir.tmpdir, "arnold_bad_yaml_#{SecureRandom.hex(4)}.yml")
      File.write(bad_yaml, "invalid: yaml: [broken")

      stderr_output = capture_stderr_through_exit { Cli.start([ "run", "Build an app", "--config", bad_yaml ]) }
      assert_match(/Invalid YAML in config file/, stderr_output)
    ensure
      File.delete(bad_yaml) if bad_yaml && File.exist?(bad_yaml)
    end

    test "run with unexpected error shows clean message" do
      ArnoldPipeline::Orchestrator.stubs(:new).raises(RuntimeError, "something went wrong")

      stderr_output = capture_stderr_through_exit { Cli.start([ "run", "Build an app" ]) }
      assert_match(/Error:.*something went wrong/, stderr_output)
    end

    test "run with unexpected error and --verbose shows backtrace" do
      ArnoldPipeline::Orchestrator.stubs(:new).raises(RuntimeError, "something went wrong")

      stderr_output = capture_stderr_through_exit { Cli.start([ "run", "Build an app", "--verbose" ]) }
      assert_match(/Error:.*something went wrong/, stderr_output)
      assert_match(/\.rb/, stderr_output) # backtrace includes file references
    end

    test "run with unexpected error and --backtrace shows backtrace" do
      ArnoldPipeline::Orchestrator.stubs(:new).raises(RuntimeError, "something went wrong")

      stderr_output = capture_stderr_through_exit { Cli.start([ "run", "Build an app", "--backtrace" ]) }
      assert_match(/Error:.*something went wrong/, stderr_output)
      assert_match(/Backtrace:/, stderr_output)
      assert_match(/\.rb/, stderr_output)
    end

    test "run with unexpected error without --backtrace hides backtrace" do
      ArnoldPipeline::Orchestrator.stubs(:new).raises(RuntimeError, "something went wrong")

      stderr_output = capture_stderr_through_exit { Cli.start([ "run", "Build an app" ]) }
      assert_match(/Error:.*something went wrong/, stderr_output)
      refute_match(/Backtrace:/, stderr_output)
    end

    test "LlmParseError with --backtrace shows raw response excerpt" do
      error = ArnoldPipeline::Agents::LlmParseError.new(
        "expected ',' or '}' after object value",
        raw_response: "{ bad json " * 100
      )
      ArnoldPipeline::Orchestrator.stubs(:new).raises(error)

      stderr_output = capture_stderr_through_exit { Cli.start([ "run", "Build an app", "--backtrace" ]) }
      assert_match(/Error:.*expected ','/, stderr_output)
      assert_match(/Raw LLM response \(first 500 chars\):/, stderr_output)
      assert_match(/bad json/, stderr_output)
      assert_match(/Backtrace:/, stderr_output)
    end

    test "resume shows friendly message for ConfigurationError" do
      run_record = PipelineRun.create!(nl_input: "Build an app", status: :paused)
      ArnoldPipeline::Orchestrator.stubs(:new).raises(ArnoldPipeline::ConfigurationError, "GitHub token is required")

      stderr_output = capture_stderr_through_exit { Cli.start([ "resume", run_record.id.to_s ]) }
      assert_match(/Configuration error:.*GitHub token is required/, stderr_output)
    end

    test "list --json outputs valid JSON array" do
      PipelineRun.create!(nl_input: "Build a todo app", status: :completed)
      PipelineRun.create!(nl_input: "Build an API", status: :pending)

      output = capture_output { Cli.start([ "list", "--json" ]) }

      parsed = JSON.parse(output)
      assert_kind_of Array, parsed
      assert_equal 2, parsed.length
      assert parsed.first.key?("id")
      assert parsed.first.key?("status")
      assert parsed.first.key?("description")
      assert parsed.first.key?("created_at")
    end

    test "list --json with no runs outputs empty array" do
      output = capture_output { Cli.start([ "list", "--json" ]) }

      parsed = JSON.parse(output)
      assert_equal [], parsed
    end

    test "status --json outputs valid JSON object" do
      run_record = PipelineRun.create!(nl_input: "Build a todo app", status: :completed)
      run_record.create_specification!(content: "# Spec", version: 2)

      output = capture_output { Cli.start([ "status", run_record.id.to_s, "--json" ]) }

      parsed = JSON.parse(output)
      assert_equal run_record.id, parsed["id"]
      assert_equal "completed", parsed["status"]
      assert_equal "Build a todo app", parsed["input"]
      assert_equal 0, parsed["task_count"]
      assert_equal 0, parsed["iteration_count"]
      assert_equal 2, parsed["spec_version"]
      assert parsed.key?("created_at")
      assert_kind_of Array, parsed["iterations"]
    end

    test "run --help shows usage without crashing" do
      output = capture_output { Cli.start([ "run", "--help" ]) }
      assert_match(/DESCRIPTION/, output)
    end

    test "resume --help shows usage without crashing" do
      output = capture_output { Cli.start([ "resume", "--help" ]) }
      assert_match(/ID/, output)
    end

    test "run --dry-run shows summary without executing" do
      mock_run = PipelineRun.create!(nl_input: "Build a recipe app", status: :paused)
      mock_run.create_specification!(content: "# Recipe App Spec", version: 1)
      mock_run.tasks.create!(title: "Setup project", tier: 0, position: 0, status: :pending)
      mock_run.tasks.create!(title: "Add models", tier: 1, position: 1, status: :pending)
      mock_run.tasks.create!(title: "Add views", tier: 1, position: 2, status: :pending)

      mock_orchestrator = mock("orchestrator")
      mock_orchestrator.expects(:call).with(nl_input: "Build a recipe app", stop_after: :tasks).returns(mock_run)

      ArnoldPipeline::Orchestrator.stubs(:new).returns(mock_orchestrator)
      require "arnold_pipeline/cli/setup_wizard"
      ArnoldPipeline::CliModule::SetupWizard.stubs(:api_key_available?).returns(true)

      output = capture_output { Cli.start([ "run", "--dry-run", "Build a recipe app" ]) }

      assert_match(/Arnold Preview/, output)
      assert_match(/# Recipe App Spec/, output)
      assert_match(/3 tasks, 2 tiers/, output)
      assert_match(/Tier 0/, output)
      assert_match(/Tier 1/, output)
      assert_match(/Run without --preview to execute/, output)
    ensure
      ArnoldPipeline.reset_configuration!
    end

    test "run --preview always uses null execution provider regardless of CLI flags" do
      mock_run = PipelineRun.create!(nl_input: "Build an app", status: :paused)
      mock_run.create_specification!(content: "# Spec", version: 1)
      mock_run.tasks.create!(title: "Setup", tier: 0, position: 0, status: :pending)

      mock_orchestrator = mock("orchestrator")
      mock_orchestrator.expects(:call).with(nl_input: "Build an app", stop_after: :tasks).returns(mock_run)
      ArnoldPipeline::Orchestrator.stubs(:new).returns(mock_orchestrator)
      require "arnold_pipeline/cli/setup_wizard"
      ArnoldPipeline::CliModule::SetupWizard.stubs(:api_key_available?).returns(true)

      output = capture_output { Cli.start([ "run", "--preview", "--execution-provider", "claude_code", "Build an app" ]) }
      assert_equal :null, ArnoldPipeline.configuration.execution_provider
      assert_match(/Arnold Preview/, output)
    ensure
      ArnoldPipeline.reset_configuration!
    end

    test "resume applies CLI flags without --config" do
      run_record = PipelineRun.create!(nl_input: "Build a todo app", status: :paused)
      mock_orchestrator = mock("orchestrator")
      mock_orchestrator.expects(:resume).with(pipeline_run: run_record, stop_after: nil).returns(run_record)

      ArnoldPipeline::Orchestrator.stubs(:new).returns(mock_orchestrator)

      capture_output { Cli.start([ "resume", run_record.id.to_s, "--execution-provider", "claude_code", "--repo", "owner/repo" ]) }
      assert_equal :claude_code, ArnoldPipeline.configuration.execution_provider
      assert_equal "owner/repo", ArnoldPipeline.configuration.github_repo
    ensure
      ArnoldPipeline.reset_configuration!
    end

    test "run with empty description exits with error" do
      assert_raises(SystemExit) do
        capture_output_and_errors { Cli.start([ "run", "" ]) }
      end
    end

    test "run with whitespace-only description exits with error" do
      assert_raises(SystemExit) do
        capture_output_and_errors { Cli.start([ "run", "   " ]) }
      end
    end

    test "run with empty description shows error message on stderr" do
      stderr_output = capture_stderr_through_exit { Cli.start([ "run", "" ]) }
      assert_match(/Provide a description argument or use --file/, stderr_output)
    end

    test "run with no argument and no --file shows error message on stderr" do
      stderr_output = capture_stderr_through_exit { Cli.start([ "run" ]) }
      assert_match(/Provide a description argument or use --file/, stderr_output)
    end

    test "run --file reads description from file" do
      tmpfile = Tempfile.new([ "arnold_desc", ".txt" ])
      tmpfile.write("Build a recipe sharing platform")
      tmpfile.close

      ArnoldPipeline.configure do |c|
        c.llm_api_key = "test"
        c.github_token = "test"
        c.github_repo = "owner/repo"
      end

      orchestrator_mock = mock("orchestrator")
      orchestrator_mock.expects(:call).with(nl_input: "Build a recipe sharing platform", stop_after: nil).returns(
        PipelineRun.create!(nl_input: "Build a recipe sharing platform", status: :completed)
      )
      ArnoldPipeline::Orchestrator.stubs(:new).returns(orchestrator_mock)

      capture_output { Cli.start([ "run", "--file", tmpfile.path ]) }
    ensure
      tmpfile&.unlink
    end

    test "run --file with nonexistent file exits with error" do
      assert_raises(SystemExit) do
        capture_output_and_errors { Cli.start([ "run", "--file", "/tmp/no_such_file_arnold.txt" ]) }
      end
    end

    test "run --file with nonexistent file shows error message" do
      stderr_output = capture_stderr_through_exit { Cli.start([ "run", "--file", "/tmp/no_such_file_arnold.txt" ]) }
      assert_match(/File not found/, stderr_output)
    end

    test "run --spec passes spec file to call_with_spec" do
      spec_file = Tempfile.new([ "spec", ".md" ])
      spec_file.write("# My Spec\n\n```json\n{\"recipe_type\": \"web_app\"}\n```\n")
      spec_file.close

      ArnoldPipeline.configure do |c|
        c.llm_api_key = "test"
        c.github_token = "test"
        c.github_repo = "owner/repo"
      end

      orchestrator_mock = mock("orchestrator")
      orchestrator_mock.expects(:call_with_spec).with(
        spec_file: spec_file.path,
        nl_input: "Build from spec: #{File.basename(spec_file.path)}",
        recipe_override: nil,
        stop_after: nil
      ).returns(PipelineRun.create!(nl_input: "Build from spec", status: :completed))
      ArnoldPipeline::Orchestrator.stubs(:new).returns(orchestrator_mock)

      capture_output { Cli.start([ "run", "--spec", spec_file.path ]) }
    ensure
      spec_file&.unlink
      ArnoldPipeline.reset_configuration!
    end

    test "run --spec with description uses it as nl_input" do
      spec_file = Tempfile.new([ "spec", ".md" ])
      spec_file.write("# Spec\n")
      spec_file.close

      ArnoldPipeline.configure do |c|
        c.llm_api_key = "test"
        c.github_token = "test"
        c.github_repo = "owner/repo"
      end

      orchestrator_mock = mock("orchestrator")
      orchestrator_mock.expects(:call_with_spec).with(
        spec_file: spec_file.path,
        nl_input: "A healthcare web app",
        recipe_override: nil,
        stop_after: nil
      ).returns(PipelineRun.create!(nl_input: "A healthcare web app", status: :completed))
      ArnoldPipeline::Orchestrator.stubs(:new).returns(orchestrator_mock)

      capture_output { Cli.start([ "run", "--spec", spec_file.path, "A healthcare web app" ]) }
    ensure
      spec_file&.unlink
      ArnoldPipeline.reset_configuration!
    end

    test "run --spec with --recipe passes recipe_override" do
      spec_file = Tempfile.new([ "spec", ".md" ])
      spec_file.write("# Spec\n")
      spec_file.close

      ArnoldPipeline.configure do |c|
        c.llm_api_key = "test"
        c.github_token = "test"
        c.github_repo = "owner/repo"
      end

      orchestrator_mock = mock("orchestrator")
      orchestrator_mock.expects(:call_with_spec).with(
        spec_file: spec_file.path,
        nl_input: "Build from spec: #{File.basename(spec_file.path)}",
        recipe_override: "api_service",
        stop_after: nil
      ).returns(PipelineRun.create!(nl_input: "Build from spec", status: :completed))
      ArnoldPipeline::Orchestrator.stubs(:new).returns(orchestrator_mock)

      capture_output { Cli.start([ "run", "--spec", spec_file.path, "--recipe", "api_service" ]) }
    ensure
      spec_file&.unlink
      ArnoldPipeline.reset_configuration!
    end

    test "run --spec with --stop-after spec pauses without task generation" do
      spec_file = Tempfile.new([ "spec", ".md" ])
      spec_file.write("# Spec\n\n```json\n{\"recipe_type\": \"web_app\"}\n```\n")
      spec_file.close

      ArnoldPipeline.configure do |c|
        c.llm_api_key = "test"
        c.github_token = "test"
        c.github_repo = "owner/repo"
      end

      orchestrator_mock = mock("orchestrator")
      orchestrator_mock.expects(:call_with_spec).with(
        spec_file: spec_file.path,
        nl_input: "Build from spec: #{File.basename(spec_file.path)}",
        recipe_override: nil,
        stop_after: :spec
      ).returns(PipelineRun.create!(nl_input: "Build from spec", status: :paused))
      ArnoldPipeline::Orchestrator.stubs(:new).returns(orchestrator_mock)

      capture_output { Cli.start([ "run", "--spec", spec_file.path, "--stop-after", "spec" ]) }
    ensure
      spec_file&.unlink
      ArnoldPipeline.reset_configuration!
    end

    test "run --spec with nonexistent file exits with error" do
      assert_raises(SystemExit) do
        capture_output_and_errors { Cli.start([ "run", "--spec", "/tmp/no_such_spec_arnold.md" ]) }
      end
    end

    test "run --spec with nonexistent file shows error message" do
      stderr_output = capture_stderr_through_exit { Cli.start([ "run", "--spec", "/tmp/no_such_spec_arnold.md" ]) }
      assert_match(/Spec file not found/, stderr_output)
    end

    test "tasks outputs task list" do
      run_record = PipelineRun.create!(nl_input: "Build a todo app", status: :completed)
      run_record.tasks.create!(title: "Setup project", description: "Initialize the project", tier: 0, position: 0, priority: 1, status: :pending, labels: [ "setup" ], depends_on: [])
      run_record.tasks.create!(title: "Add models", description: "Create data models", tier: 1, position: 1, priority: 2, status: :pending, labels: [ "backend" ], depends_on: [ 0 ])

      output = capture_output { Cli.start([ "tasks", run_record.id.to_s ]) }

      assert_match(/\[0\] Setup project/, output)
      assert_match(/\[1\] Add models/, output)
      assert_match(/Tier: 0/, output)
      assert_match(/Tier: 1/, output)
      assert_match(/Initialize the project/, output)
      assert_match(/Labels: setup/, output)
      assert_match(/Depends on: 0/, output)
    end

    test "tasks --json outputs valid JSON array" do
      run_record = PipelineRun.create!(nl_input: "Build a todo app", status: :completed)
      run_record.tasks.create!(title: "Setup project", description: "Initialize", tier: 0, position: 0, priority: 1, status: :pending, labels: [ "setup" ], depends_on: [])
      run_record.tasks.create!(title: "Add models", description: "Models", tier: 1, position: 1, priority: 2, status: :pending, labels: [], depends_on: [ 0 ])

      output = capture_output { Cli.start([ "tasks", run_record.id.to_s, "--json" ]) }

      parsed = JSON.parse(output)
      assert_kind_of Array, parsed
      assert_equal 2, parsed.length
      first = parsed.first
      assert_equal "Setup project", first["title"]
      assert_equal 0, first["tier"]
      assert_equal 0, first["position"]
      assert_equal 1, first["priority"]
      assert_equal [ "setup" ], first["labels"]
      assert first.key?("depends_on")
      assert first.key?("external_id")
      assert first.key?("external_url")
    end

    test "tasks writes to file with --output flag" do
      run_record = PipelineRun.create!(nl_input: "Build a todo app", status: :completed)
      run_record.tasks.create!(title: "Setup project", tier: 0, position: 0, status: :pending)

      outfile = File.join(Dir.tmpdir, "arnold_tasks_test_#{SecureRandom.hex(4)}.md")

      stderr_output = nil
      original_stderr = $stderr
      $stderr = StringIO.new
      begin
        capture_output { Cli.start([ "tasks", run_record.id.to_s, "--output", outfile ]) }
        stderr_output = $stderr.string
      ensure
        $stderr = original_stderr
      end

      assert_match(/1 tasks written to/, stderr_output)
      assert_match(/Setup project/, File.read(outfile))
    ensure
      File.delete(outfile) if outfile && File.exist?(outfile)
    end

    test "tasks with non-existent ID exits with error" do
      assert_raises(SystemExit) do
        capture_output_and_errors { Cli.start([ "tasks", "99999" ]) }
      end
    end

    test "tasks with no tasks exits with error" do
      run_record = PipelineRun.create!(nl_input: "Build a todo app", status: :pending)

      assert_raises(SystemExit) do
        capture_output_and_errors { Cli.start([ "tasks", run_record.id.to_s ]) }
      end
    end

    test "spec --history shows lineage for single run (no forks)" do
      run_record = PipelineRun.create!(nl_input: "Build a todo app", status: :completed)
      run_record.create_specification!(content: "# Spec v1", version: 1)

      output = capture_output { Cli.start([ "spec", run_record.id.to_s, "--history" ]) }

      assert_match(/Spec Lineage for Run ##{run_record.id}/, output)
      assert_match(/##{run_record.id}.*\[completed\].*v1/, output)
      assert_match(/spec_generation/, output)
      assert_match(/◄ current/, output)
    end

    test "spec --history shows fork lineage tree" do
      root = PipelineRun.create!(nl_input: "Build a todo app", status: :completed)
      root.create_specification!(content: "# Spec v1", version: 1)

      child = PipelineRun.create!(
        nl_input: "Build a todo app",
        status: :completed,
        metadata: { "forked_from_run_id" => root.id, "fork_change_request" => "Add authentication" }
      )
      spec2 = child.create_specification!(content: "# Spec v2", version: 2)
      spec2.spec_revisions.create!(
        version: 2, content: "# Spec v2", change_source: "user_iterate",
        delta_summary: [ "ADDED: Auth > Login" ]
      )

      output = capture_output { Cli.start([ "spec", child.id.to_s, "--history" ]) }

      assert_match(/Spec Lineage for Run ##{child.id}/, output)
      assert_match(/##{root.id}.*\[completed\].*v1/, output)
      assert_match(/spec_generation/, output)
      assert_match(/##{child.id}.*\[completed\].*v2/, output)
      assert_match(/Add authentication/, output)
      assert_match(/ADDED: Auth > Login/, output)
      # current marker on the requested run
      assert_match(/##{child.id}.*◄ current/, output)
    end

    test "spec --history shows deeply nested fork chain" do
      root = PipelineRun.create!(nl_input: "Build a todo app", status: :completed)
      root.create_specification!(content: "# v1", version: 1)

      child1 = PipelineRun.create!(
        nl_input: "Build a todo app", status: :completed,
        metadata: { "forked_from_run_id" => root.id, "fork_change_request" => "First change" }
      )
      child1.create_specification!(content: "# v2", version: 2)

      child2 = PipelineRun.create!(
        nl_input: "Build a todo app", status: :executing,
        metadata: { "forked_from_run_id" => child1.id, "fork_change_request" => "Second change" }
      )
      child2.create_specification!(content: "# v3", version: 3)

      output = capture_output { Cli.start([ "spec", child2.id.to_s, "--history" ]) }

      assert_match(/Spec Lineage for Run ##{child2.id}/, output)
      assert_match(/##{root.id}/, output)
      assert_match(/##{child1.id}/, output)
      assert_match(/##{child2.id}.*◄ current/, output)
      assert_match(/First change/, output)
      assert_match(/Second change/, output)
    end

    test "spec --history shows multiple forks from same parent (branching)" do
      root = PipelineRun.create!(nl_input: "Build a todo app", status: :completed)
      root.create_specification!(content: "# v1", version: 1)

      fork_a = PipelineRun.create!(
        nl_input: "Build a todo app", status: :completed,
        metadata: { "forked_from_run_id" => root.id, "fork_change_request" => "Branch A" }
      )
      fork_a.create_specification!(content: "# v2a", version: 2)

      fork_b = PipelineRun.create!(
        nl_input: "Build a todo app", status: :failed,
        metadata: { "forked_from_run_id" => root.id, "fork_change_request" => "Branch B" }
      )
      fork_b.create_specification!(content: "# v2b", version: 2)

      output = capture_output { Cli.start([ "spec", fork_a.id.to_s, "--history" ]) }

      assert_match(/##{root.id}/, output)
      assert_match(/##{fork_a.id}.*◄ current/, output)
      assert_match(/##{fork_b.id}/, output)
      assert_match(/Branch A/, output)
      assert_match(/Branch B/, output)
    end

    test "spec --history marks current run distinctly" do
      root = PipelineRun.create!(nl_input: "Build a todo app", status: :completed)
      root.create_specification!(content: "# v1", version: 1)

      child = PipelineRun.create!(
        nl_input: "Build a todo app", status: :completed,
        metadata: { "forked_from_run_id" => root.id, "fork_change_request" => "Change" }
      )
      child.create_specification!(content: "# v2", version: 2)

      # Request history for the root — root should be marked current, not child
      output = capture_output { Cli.start([ "spec", root.id.to_s, "--history" ]) }

      assert_match(/##{root.id}.*◄ current/, output)
      assert_no_match(/##{child.id}.*◄ current/, output)
    end

    test "spec --history truncates long change requests" do
      root = PipelineRun.create!(nl_input: "Build a todo app", status: :completed)
      root.create_specification!(content: "# v1", version: 1)

      long_request = "A" * 100
      child = PipelineRun.create!(
        nl_input: "Build a todo app", status: :completed,
        metadata: { "forked_from_run_id" => root.id, "fork_change_request" => long_request }
      )
      child.create_specification!(content: "# v2", version: 2)

      output = capture_output { Cli.start([ "spec", child.id.to_s, "--history" ]) }

      assert_match(/#{"A" * 70}\.\.\./, output)
      assert_no_match(/#{"A" * 100}/, output)
    end

    test "spec --version shows specific version content" do
      run_record = PipelineRun.create!(nl_input: "Build a todo app", status: :completed)
      spec = run_record.create_specification!(content: "# Spec v2", version: 2)
      spec.spec_revisions.create!(version: 1, content: "# Spec version one content")
      spec.spec_revisions.create!(version: 2, content: "# Spec version two content")

      output = capture_output { Cli.start([ "spec", run_record.id.to_s, "--version", "1" ]) }

      assert_match(/# Spec version one content/, output)
      assert_no_match(/version two/, output)
    end

    test "spec --version with non-existent version exits with error" do
      run_record = PipelineRun.create!(nl_input: "Build a todo app", status: :completed)
      run_record.create_specification!(content: "# Spec", version: 1)

      assert_raises(SystemExit) do
        capture_output_and_errors { Cli.start([ "spec", run_record.id.to_s, "--version", "99" ]) }
      end
    end

    # --- Log command tests ---

    test "log shows events for valid ID" do
      run_record = PipelineRun.create!(nl_input: "Build a todo app", status: :completed)
      run_record.pipeline_events.create!(
        event_type: :library_selection, stage: "spec_generation",
        summary: { "persona" => "Software Architect", "recipe" => "Web App", "domain_type" => "PRODUCTIVITY" }
      )
      run_record.pipeline_events.create!(
        event_type: :spec_generated, stage: "spec_generation",
        summary: { "spec_version" => 1, "content_length" => 4521 }, duration_ms: 3412.5
      )

      output = capture_output { Cli.start([ "log", run_record.id.to_s ]) }

      assert_match(/Pipeline Run ##{run_record.id}/, output)
      assert_match(/library.*persona=Software Architect/, output)
      assert_match(/spec.*v1 generated/, output)
      assert_match(/3\.4s/, output)
    end

    test "log filters by --stage" do
      run_record = PipelineRun.create!(nl_input: "Build a todo app", status: :completed)
      run_record.pipeline_events.create!(event_type: :library_selection, stage: "spec_generation", summary: {})
      run_record.pipeline_events.create!(event_type: :tasks_broken, stage: "task_breakdown", summary: {})
      run_record.pipeline_events.create!(event_type: :analysis_completed, stage: "analysis", summary: {})

      output = capture_output { Cli.start([ "log", run_record.id.to_s, "--stage", "analysis" ]) }

      assert_match(/Pipeline Run ##{run_record.id}/, output)
      assert_match(/ANALYSIS/, output)
      assert_no_match(/library/, output)
      assert_no_match(/tasks.*tiers/, output)
    end

    test "log --json outputs valid JSON array" do
      run_record = PipelineRun.create!(nl_input: "Build a todo app", status: :completed)
      run_record.pipeline_events.create!(
        event_type: :spec_generated, stage: "spec_generation",
        summary: { "content_length" => 100 }, duration_ms: 500.0
      )

      output = capture_output { Cli.start([ "log", run_record.id.to_s, "--json" ]) }

      parsed = JSON.parse(output)
      assert_kind_of Array, parsed
      assert_equal 1, parsed.length
      assert_equal "spec_generated", parsed.first["event_type"]
      assert_equal "spec_generation", parsed.first["stage"]
      assert_equal({ "content_length" => 100 }, parsed.first["summary"])
    end

    test "log --json includes pipeline_run_id" do
      run_record = PipelineRun.create!(nl_input: "Build an app", status: :completed)
      run_record.pipeline_events.create!(
        event_type: :pipeline_completed, stage: "lifecycle",
        summary: { total_iterations: 1, total_tasks: 5 }
      )

      output = capture_output { Cli.start([ "log", run_record.id.to_s, "--json" ]) }
      data = JSON.parse(output)

      assert_equal 1, data.size
      assert_equal run_record.id, data.first["pipeline_run_id"]
    end

    test "log --verbose includes payloads" do
      run_record = PipelineRun.create!(nl_input: "Build a todo app", status: :completed)
      run_record.pipeline_events.create!(
        event_type: :spec_generated, stage: "spec_generation",
        summary: { "content_length" => 100 },
        payload: { "full_response" => "test data" }
      )

      output = capture_output { Cli.start([ "log", run_record.id.to_s, "--verbose" ]) }

      assert_match(/Payload:/, output)
      assert_match(/full_response/, output)
    end

    test "log --json --verbose includes payload in JSON" do
      run_record = PipelineRun.create!(nl_input: "Build a todo app", status: :completed)
      run_record.pipeline_events.create!(
        event_type: :spec_generated, stage: "spec_generation",
        summary: { "content_length" => 100 },
        payload: { "response" => "data" }
      )

      output = capture_output { Cli.start([ "log", run_record.id.to_s, "--json", "--verbose" ]) }

      parsed = JSON.parse(output)
      assert_equal({ "response" => "data" }, parsed.first["payload"])
    end

    test "log with non-existent ID exits with error" do
      assert_raises(SystemExit) do
        capture_output_and_errors { Cli.start([ "log", "99999" ]) }
      end
    end

    test "log with no events shows message" do
      run_record = PipelineRun.create!(nl_input: "Build a todo app", status: :completed)

      output = capture_output { Cli.start([ "log", run_record.id.to_s ]) }

      assert_match(/No events found/, output)
    end

    test "log formats lifecycle events" do
      run_record = PipelineRun.create!(nl_input: "Build a todo app", status: :completed)
      run_record.pipeline_events.create!(
        event_type: :pipeline_completed, stage: "lifecycle",
        summary: { "total_iterations" => 2, "total_tasks" => 10 }
      )

      output = capture_output { Cli.start([ "log", run_record.id.to_s ]) }

      assert_match(/2 iterations, 10 tasks/, output)
    end

    test "log formats criteria_check event with counts" do
      run_record = PipelineRun.create!(nl_input: "Build a todo app", status: :completed)
      run_record.pipeline_events.create!(
        event_type: :criteria_check, stage: "tier_gate",
        summary: {
          "verified_count" => 3, "failed_count" => 1, "unverified_count" => 2,
          "criteria" => [
            { "type" => "file_exists", "description" => "Gemfile exists", "result" => "verified" },
            { "type" => "route_exists", "description" => "Health check route", "result" => "failed" },
            { "type" => "http", "description" => "Returns 200", "result" => "unverified" }
          ]
        }
      )

      output = capture_output { Cli.start([ "log", run_record.id.to_s ]) }

      assert_match(/criteria/, output)
      assert_match(/1 failed/, output)
      assert_match(/3 verified/, output)
      # Without --verbose, individual criteria should not show
      assert_no_match(/PASS:/, output)
    end

    test "log formats criteria_check event with mode label" do
      run_record = PipelineRun.create!(nl_input: "Build a todo app", status: :completed)
      run_record.pipeline_events.create!(
        event_type: :criteria_check, stage: "tier_gate",
        summary: {
          "mode" => "advisory",
          "verified_count" => 2, "failed_count" => 1, "unverified_count" => 0,
          "criteria" => []
        }
      )

      output = capture_output { Cli.start([ "log", run_record.id.to_s ]) }

      assert_match(/criteria/, output)
      assert_match(/unmet/, output)
      assert_match(/advisory/, output)
    end

    test "log --verbose shows per-criterion results for criteria_check" do
      run_record = PipelineRun.create!(nl_input: "Build a todo app", status: :completed)
      run_record.pipeline_events.create!(
        event_type: :criteria_check, stage: "tier_gate",
        summary: {
          "verified_count" => 1, "failed_count" => 1, "unverified_count" => 0,
          "criteria" => [
            { "type" => "file_exists", "description" => "Gemfile exists", "result" => "verified" },
            { "type" => "route_exists", "description" => "Health check route", "result" => "failed" }
          ]
        }
      )

      output = capture_output { Cli.start([ "log", run_record.id.to_s, "--verbose" ]) }

      assert_match(/PASS: Gemfile exists \(file_exists\)/, output)
      assert_match(/FAIL: Health check route \(route_exists\)/, output)
    end

    test "log --verbose shows corrective tasks for tier_gate_evaluated" do
      run_record = PipelineRun.create!(nl_input: "Build a todo app", status: :completed)
      run_record.pipeline_events.create!(
        event_type: :tier_gate_evaluated, stage: "tier_gate",
        summary: {
          "pass" => false,
          "issues" => [ "Missing route" ],
          "corrective_task_count" => 1,
          "corrective_tasks" => [
            { "title" => "Add route", "description" => "Add GET /up to routes.rb" }
          ]
        },
        duration_ms: 5000.0
      )

      output = capture_output { Cli.start([ "log", run_record.id.to_s, "--verbose" ]) }

      assert_match(/gate/, output)
      assert_match(/FAIL/, output)
      assert_match(/Missing route/, output)
      assert_match(/Corrective tasks:/, output)
      assert_match(/1\. Add route/, output)
    end

    test "format_task shows superseded label for superseded tasks" do
      run_record = PipelineRun.create!(nl_input: "Build a todo app", status: :completed)
      task = run_record.tasks.create!(title: "Setup project", tier: 0, position: 0, priority: 1, status: :superseded, labels: [], depends_on: [])

      output = capture_output { Cli.start([ "tasks", run_record.id.to_s ]) }

      assert_match(/\[0\] Setup project \[superseded\]/, output)
      assert_match(/Status: superseded/, output)
    end

    test "format_task does not show superseded label for non-superseded tasks" do
      run_record = PipelineRun.create!(nl_input: "Build a todo app", status: :completed)
      run_record.tasks.create!(title: "Setup project", tier: 0, position: 0, priority: 1, status: :completed, labels: [], depends_on: [])

      output = capture_output { Cli.start([ "tasks", run_record.id.to_s ]) }

      assert_match(/\[0\] Setup project\n/, output)
      assert_no_match(/\[superseded\]/, output)
    end

    # --- Iterate command tests ---

    test "iterate with paused run shows success output" do
      run_record = PipelineRun.create!(nl_input: "Build a todo app", status: :paused)
      run_record.create_specification!(content: "# Spec", version: 1)
      run_record.tasks.create!(title: "Setup DB", position: 0, tier: 0, status: :pending)

      mock_orchestrator = mock("orchestrator")
      mock_orchestrator.expects(:iterate_spec!).with(
        pipeline_run: run_record, change_request: "Add auth"
      ).returns({
        pipeline_run: run_record,
        deltas: { merge_strategy: "append", delta_count: 2, new_version: 2 },
        spec_version: 2
      })

      ArnoldPipeline::Orchestrator.stubs(:new).returns(mock_orchestrator)

      # Mark task as superseded to match what iterate_spec! would do
      run_record.tasks.update_all(status: :superseded)

      output = capture_output { Cli.start([ "iterate", run_record.id.to_s, "Add auth" ]) }

      assert_match(/Iterating specification for pipeline run/, output)
      assert_match(/Specification updated to v2/, output)
      assert_match(/Deltas applied: 2/, output)
      assert_match(/Merge strategy: append/, output)
      assert_match(/Tasks superseded: 1/, output)
      assert_match(/arnold resume #{run_record.id}/, output)
    end

    test "iterate with non-existent ID exits with error" do
      assert_raises(SystemExit) do
        capture_output_and_errors { Cli.start([ "iterate", "99999", "Add auth" ]) }
      end
    end

    test "iterate with empty change request exits with error" do
      run_record = PipelineRun.create!(nl_input: "Build a todo app", status: :paused)

      assert_raises(SystemExit) do
        capture_output_and_errors { Cli.start([ "iterate", run_record.id.to_s, "   " ]) }
      end
    end

    test "iterate with empty change request shows error message" do
      run_record = PipelineRun.create!(nl_input: "Build a todo app", status: :paused)

      stderr_output = capture_stderr_through_exit { Cli.start([ "iterate", run_record.id.to_s, "   " ]) }
      assert_match(/Change request cannot be empty/, stderr_output)
    end

    test "iterate --dry-run shows deltas without applying" do
      run_record = PipelineRun.create!(nl_input: "Build a todo app", status: :paused)
      run_record.create_specification!(content: "# Spec", version: 1)

      mock_orchestrator = mock("orchestrator")
      mock_orchestrator.expects(:iterate_spec_dry_run!).with(
        pipeline_run: run_record, change_request: "Add auth"
      ).returns({
        deltas: [
          { "operation" => "added", "section" => "Auth", "requirement" => "Login", "rationale" => "User needs login" }
        ],
        summary: "Adding authentication",
        current_version: 1
      })

      ArnoldPipeline::Orchestrator.stubs(:new).returns(mock_orchestrator)

      output = capture_output { Cli.start([ "iterate", run_record.id.to_s, "Add auth", "--dry-run" ]) }

      assert_match(/Proposed changes to specification/, output)
      assert_match(/ADDED: Auth > Login/, output)
      assert_match(/No changes applied \(dry run\)/, output)
    end

    test "iterate --dry-run --json outputs JSON" do
      run_record = PipelineRun.create!(nl_input: "Build a todo app", status: :paused)
      run_record.create_specification!(content: "# Spec", version: 1)

      mock_orchestrator = mock("orchestrator")
      mock_orchestrator.expects(:iterate_spec_dry_run!).returns({
        deltas: [
          { "operation" => "added", "section" => "Auth", "requirement" => "Login", "rationale" => "Needs login" }
        ],
        summary: "Adding auth",
        current_version: 1
      })

      ArnoldPipeline::Orchestrator.stubs(:new).returns(mock_orchestrator)

      output = capture_output { Cli.start([ "iterate", run_record.id.to_s, "Add auth", "--dry-run", "--json" ]) }

      parsed = JSON.parse(output)
      assert_kind_of Array, parsed
      assert_equal 1, parsed.length
      assert_equal "added", parsed.first["operation"]
      assert_equal "Auth", parsed.first["section"]
    end

    test "iterate with executing run shows error" do
      run_record = PipelineRun.create!(nl_input: "Build a todo app", status: :executing)

      mock_orchestrator = mock("orchestrator")
      mock_orchestrator.expects(:iterate_spec!).raises(
        ArgumentError, "Cannot iterate a executing pipeline run. Pause or wait for completion first."
      )

      ArnoldPipeline::Orchestrator.stubs(:new).returns(mock_orchestrator)

      stderr_output = capture_stderr_through_exit { Cli.start([ "iterate", run_record.id.to_s, "Add auth" ]) }
      assert_match(/Cannot iterate a executing pipeline run/, stderr_output)
    end

    test "run --quiet suppresses informational output" do
      mock_run = PipelineRun.create!(nl_input: "Build a todo app", status: :completed)

      mock_orchestrator = mock("orchestrator")
      mock_orchestrator.expects(:call).with(nl_input: "Build a todo app", stop_after: nil).returns(mock_run)

      ArnoldPipeline::Orchestrator.stubs(:new).returns(mock_orchestrator)

      output = capture_output { Cli.start([ "run", "Build a todo app", "--quiet" ]) }
      assert_equal "", output
    end

    test "log displays per-task outcomes in verbose mode" do
      run_record = PipelineRun.create!(nl_input: "Build an app", status: :completed)
      run_record.pipeline_events.create!(
        event_type: :tier_execution_completed, stage: "execution", tier_number: 0,
        summary: {
          "tier_number" => 0, "resolved_count" => 1, "failed_count" => 1,
          "task_outcomes" => [
            { "title" => "Setup DB", "status" => "resolved" },
            { "title" => "Add API", "status" => "failed", "failure_reason" => "empty_diff" }
          ]
        }
      )

      output = capture_output { Cli.start([ "log", run_record.id.to_s, "--verbose" ]) }

      assert_match(/Setup DB/, output)
      assert_match(/Add API.*empty_diff/, output)
    end

    test "log does not display per-task outcomes without verbose" do
      run_record = PipelineRun.create!(nl_input: "Build an app", status: :completed)
      run_record.pipeline_events.create!(
        event_type: :tier_execution_completed, stage: "execution", tier_number: 0,
        summary: {
          "tier_number" => 0, "resolved_count" => 1, "failed_count" => 1,
          "task_outcomes" => [
            { "title" => "Setup DB", "status" => "resolved" },
            { "title" => "Add API", "status" => "failed", "failure_reason" => "empty_diff" }
          ]
        }
      )

      output = capture_output { Cli.start([ "log", run_record.id.to_s ]) }

      assert_match(/1 failed/, output)
      assert_match(/1 ok/, output)
      # Per-task outcome detail lines should not appear in non-verbose mode
      assert_no_match(/Setup DB.*resolved/, output)
    end

    test "log displays enriched pipeline_completed summary" do
      run_record = PipelineRun.create!(nl_input: "Build an app", status: :completed)
      run_record.pipeline_events.create!(
        event_type: :pipeline_completed, stage: "lifecycle",
        summary: {
          "total_iterations" => 2, "total_tasks" => 8,
          "tasks_succeeded" => 6, "tasks_failed" => 2,
          "total_duration_ms" => 3600000.0,
          "final_confidence" => 85
        }
      )

      output = capture_output { Cli.start([ "log", run_record.id.to_s ]) }

      assert_match(/PIPELINE COMPLETED/, output)
      assert_match(/2 iterations, 8 tasks/, output)
      assert_match(/6 succeeded, 2 failed/, output)
      assert_match(/1\.0h/, output)
      assert_match(/85% confidence/, output)
    end

    test "log displays enriched pipeline_failed summary" do
      run_record = PipelineRun.create!(nl_input: "Build an app", status: :failed)
      run_record.pipeline_events.create!(
        event_type: :pipeline_failed, stage: "lifecycle",
        summary: {
          "error_class" => "RuntimeError", "error_message" => "Something broke",
          "failed_stage" => "execution",
          "total_tasks" => 5, "tasks_succeeded" => 3, "tasks_failed" => 2,
          "total_duration_ms" => 125000.0,
          "raw_response_excerpt" => "invalid JSON here that is too long" * 10
        }
      )

      output = capture_output { Cli.start([ "log", run_record.id.to_s ]) }

      assert_match(/PIPELINE FAILED/, output)
      assert_match(/RuntimeError: Something broke/, output)
      assert_match(/5 tasks.*3 succeeded.*2 failed/, output)
      assert_match(/2\.1m/, output)
    end

    test "log formats duration in seconds for short durations" do
      run_record = PipelineRun.create!(nl_input: "Build an app", status: :completed)
      run_record.pipeline_events.create!(
        event_type: :pipeline_completed, stage: "lifecycle",
        summary: {
          "total_iterations" => 1, "total_tasks" => 2,
          "total_duration_ms" => 45000.0
        }
      )

      output = capture_output { Cli.start([ "log", run_record.id.to_s ]) }

      assert_match(/45\.0s/, output)
    end

    test "log formats duration in minutes for medium durations" do
      run_record = PipelineRun.create!(nl_input: "Build an app", status: :completed)
      run_record.pipeline_events.create!(
        event_type: :pipeline_completed, stage: "lifecycle",
        summary: {
          "total_iterations" => 1, "total_tasks" => 3,
          "total_duration_ms" => 300000.0
        }
      )

      output = capture_output { Cli.start([ "log", run_record.id.to_s ]) }

      assert_match(/5\.0m/, output)
    end

    test "run --preview auto-sets null provider and stop_after tasks" do
      mock_run = PipelineRun.create!(nl_input: "Build a todo app", status: :paused)
      mock_run.create_specification!(content: "# Todo App Spec", version: 1)
      mock_run.tasks.create!(title: "Setup", tier: 0, position: 0, status: :pending)

      mock_orchestrator = mock("orchestrator")
      mock_orchestrator.expects(:call).with(nl_input: "Build a todo app", stop_after: :tasks).returns(mock_run)

      ArnoldPipeline::Orchestrator.stubs(:new).returns(mock_orchestrator)
      require "arnold_pipeline/cli/setup_wizard"
      ArnoldPipeline::CliModule::SetupWizard.stubs(:api_key_available?).returns(true)

      output = capture_output { Cli.start([ "run", "--preview", "Build a todo app" ]) }

      assert_equal :null, ArnoldPipeline.configuration.execution_provider
      assert_match(/Arnold Preview/, output)
      assert_match(/# Todo App Spec/, output)
    ensure
      ArnoldPipeline.reset_configuration!
    end

    test "run --preview prints formatted spec and task breakdown" do
      mock_run = PipelineRun.create!(nl_input: "Build a todo app", status: :paused)
      mock_run.create_specification!(content: "# Todo App\n\n## Purpose\nA simple todo list.", version: 1)
      mock_run.tasks.create!(title: "Setup DB", description: "Create tables", tier: 0, position: 0, status: :pending)
      mock_run.tasks.create!(title: "Add API", description: "REST endpoints", tier: 1, position: 1, status: :pending, depends_on: [ 0 ])

      mock_orchestrator = mock("orchestrator")
      mock_orchestrator.expects(:call).returns(mock_run)
      ArnoldPipeline::Orchestrator.stubs(:new).returns(mock_orchestrator)
      require "arnold_pipeline/cli/setup_wizard"
      ArnoldPipeline::CliModule::SetupWizard.stubs(:api_key_available?).returns(true)

      output = capture_output { Cli.start([ "run", "--preview", "Build a todo app" ]) }

      assert_match(/# Todo App/, output)
      assert_match(/2 tasks, 2 tiers/, output)
      assert_match(/Tier 0/, output)
      assert_match(/Setup DB/, output)
      assert_match(/Tier 1/, output)
      assert_match(/Add API/, output)
      assert_match(/depends on: 0/, output)
      assert_match(/Run without --preview to execute/, output)
    ensure
      ArnoldPipeline.reset_configuration!
    end

    test "run --preview exits with error when no API key and non-interactive" do
      original_anthropic = ENV["ANTHROPIC_API_KEY"]
      original_openai = ENV["OPENAI_API_KEY"]
      ENV.delete("ANTHROPIC_API_KEY")
      ENV.delete("OPENAI_API_KEY")
      ArnoldPipeline.reset_configuration!

      require "arnold_pipeline/cli/setup_wizard"
      ArnoldPipeline::CliModule::SetupWizard.stubs(:api_key_available?).returns(false)

      stderr_output = capture_stderr_through_exit { Cli.start([ "run", "--preview", "test" ]) }
      assert_match(/No API key found/, stderr_output)
    ensure
      ENV["ANTHROPIC_API_KEY"] = original_anthropic if original_anthropic
      ENV["OPENAI_API_KEY"] = original_openai if original_openai
      ArnoldPipeline.reset_configuration!
    end

    test "run shows doctor hint on ConfigurationError" do
      ArnoldPipeline::Orchestrator.stubs(:new).raises(ArnoldPipeline::ConfigurationError, "LLM API key is required")

      stderr_output = capture_stderr_through_exit { Cli.start([ "run", "Build an app" ]) }
      assert_match(/Configuration error:.*LLM API key is required/, stderr_output)
      assert_match(/arnold doctor/, stderr_output)
    end

    # --- User config auto-load tests ---

    test "load_config! auto-loads user config when present" do
      user_config_file = File.join(Dir.tmpdir, "arnold_user_config_#{SecureRandom.hex(4)}.yml")
      File.write(user_config_file, YAML.dump("llm_provider" => "openai", "llm_model" => "gpt-4o"))

      mock_run = PipelineRun.create!(nl_input: "Build a todo app", status: :completed)
      mock_orchestrator = mock("orchestrator")
      mock_orchestrator.expects(:call).returns(mock_run)
      ArnoldPipeline::Orchestrator.stubs(:new).returns(mock_orchestrator)

      with_user_config_path(user_config_file) do
        capture_output { Cli.start([ "run", "Build a todo app" ]) }
      end

      assert_equal :openai, ArnoldPipeline.configuration.llm_provider
      assert_equal "gpt-4o", ArnoldPipeline.configuration.llm_model
    ensure
      ArnoldPipeline.reset_configuration!
      File.delete(user_config_file) if user_config_file && File.exist?(user_config_file)
    end

    test "load_config! explicit --config overrides user config" do
      user_config_file = File.join(Dir.tmpdir, "arnold_user_config_#{SecureRandom.hex(4)}.yml")
      File.write(user_config_file, YAML.dump("llm_model" => "gpt-4o", "llm_provider" => "openai"))

      explicit_config_file = File.join(Dir.tmpdir, "arnold_explicit_config_#{SecureRandom.hex(4)}.yml")
      File.write(explicit_config_file, YAML.dump("llm_model" => "claude-sonnet-4-6"))

      mock_run = PipelineRun.create!(nl_input: "Build an app", status: :completed)
      mock_orchestrator = mock("orchestrator")
      mock_orchestrator.expects(:call).returns(mock_run)
      ArnoldPipeline::Orchestrator.stubs(:new).returns(mock_orchestrator)

      with_user_config_path(user_config_file) do
        capture_output { Cli.start([ "run", "Build an app", "--config", explicit_config_file ]) }
      end

      # Explicit config should override the user config value for llm_model
      assert_equal "claude-sonnet-4-6", ArnoldPipeline.configuration.llm_model
      # User config value for llm_provider should still be applied (explicit config didn't set it)
      assert_equal :openai, ArnoldPipeline.configuration.llm_provider
    ensure
      ArnoldPipeline.reset_configuration!
      File.delete(user_config_file) if user_config_file && File.exist?(user_config_file)
      File.delete(explicit_config_file) if explicit_config_file && File.exist?(explicit_config_file)
    end

    test "load_config! skips user config when file does not exist" do
      nonexistent_path = File.join(Dir.tmpdir, "arnold_nonexistent_#{SecureRandom.hex(8)}.yml")

      mock_run = PipelineRun.create!(nl_input: "Build an app", status: :completed)
      mock_orchestrator = mock("orchestrator")
      mock_orchestrator.expects(:call).returns(mock_run)
      ArnoldPipeline::Orchestrator.stubs(:new).returns(mock_orchestrator)

      default_provider = ArnoldPipeline.configuration.llm_provider
      default_model = ArnoldPipeline.configuration.llm_model

      with_user_config_path(nonexistent_path) do
        capture_output { Cli.start([ "run", "Build an app" ]) }
      end

      # Defaults should remain unchanged
      assert_equal default_provider, ArnoldPipeline.configuration.llm_provider
      assert_equal default_model, ArnoldPipeline.configuration.llm_model
    ensure
      ArnoldPipeline.reset_configuration!
    end

    test "load_config! CLI flags override user config" do
      user_config_file = File.join(Dir.tmpdir, "arnold_user_config_#{SecureRandom.hex(4)}.yml")
      File.write(user_config_file, YAML.dump("llm_model" => "gpt-4o", "llm_provider" => "openai"))

      mock_run = PipelineRun.create!(nl_input: "Build an app", status: :completed)
      mock_orchestrator = mock("orchestrator")
      mock_orchestrator.expects(:call).returns(mock_run)
      ArnoldPipeline::Orchestrator.stubs(:new).returns(mock_orchestrator)

      with_user_config_path(user_config_file) do
        capture_output { Cli.start([ "run", "Build an app", "--model", "custom-model" ]) }
      end

      # CLI flag should override user config
      assert_equal "custom-model", ArnoldPipeline.configuration.llm_model
      # User config value not overridden by CLI flag should still apply
      assert_equal :openai, ArnoldPipeline.configuration.llm_provider
    ensure
      ArnoldPipeline.reset_configuration!
      File.delete(user_config_file) if user_config_file && File.exist?(user_config_file)
    end

    # --- Doctor command tests ---

    test "doctor command outputs health check results" do
      original_anthropic = ENV["ANTHROPIC_API_KEY"]
      ENV["ANTHROPIC_API_KEY"] = "sk-ant-test"

      nonexistent_config = File.join(Dir.tmpdir, "arnold_nonexistent_#{SecureRandom.hex(8)}.yml")
      with_user_config_path(nonexistent_config) do
        output = capture_output { Cli.start([ "doctor" ]) }

        assert_match(/Arnold Doctor/, output)
        assert_match(/Ruby/, output)
        assert_match(/Git/, output)
        assert_match(/API key/, output)
        assert_match(/SQLite/, output)
      end
    ensure
      ENV["ANTHROPIC_API_KEY"] = original_anthropic
      ArnoldPipeline.reset_configuration!
    end

    test "doctor shows pass count summary" do
      original_anthropic = ENV["ANTHROPIC_API_KEY"]
      ENV["ANTHROPIC_API_KEY"] = "sk-ant-test"

      nonexistent_config = File.join(Dir.tmpdir, "arnold_nonexistent_#{SecureRandom.hex(8)}.yml")
      with_user_config_path(nonexistent_config) do
        output = capture_output { Cli.start([ "doctor" ]) }

        assert_match(/\d+ passed/, output)
      end
    ensure
      ENV["ANTHROPIC_API_KEY"] = original_anthropic
      ArnoldPipeline.reset_configuration!
    end

    test "doctor exits with 0 when all required checks pass" do
      original_anthropic = ENV["ANTHROPIC_API_KEY"]
      ENV["ANTHROPIC_API_KEY"] = "sk-ant-test"

      nonexistent_config = File.join(Dir.tmpdir, "arnold_nonexistent_#{SecureRandom.hex(8)}.yml")
      with_user_config_path(nonexistent_config) do
        # Should not raise SystemExit
        output = capture_output { Cli.start([ "doctor" ]) }
        assert_match(/passed/, output)
      end
    ensure
      ENV["ANTHROPIC_API_KEY"] = original_anthropic
      ArnoldPipeline.reset_configuration!
    end

    test "doctor exits with 1 when required check fails" do
      original_anthropic = ENV["ANTHROPIC_API_KEY"]
      original_openai = ENV["OPENAI_API_KEY"]
      ENV.delete("ANTHROPIC_API_KEY")
      ENV.delete("OPENAI_API_KEY")
      ArnoldPipeline.reset_configuration!

      nonexistent_config = File.join(Dir.tmpdir, "arnold_nonexistent_#{SecureRandom.hex(8)}.yml")
      with_user_config_path(nonexistent_config) do
        assert_raises(SystemExit) do
          capture_output_and_errors { Cli.start([ "doctor" ]) }
        end
      end
    ensure
      ENV["ANTHROPIC_API_KEY"] = original_anthropic if original_anthropic
      ENV["OPENAI_API_KEY"] = original_openai if original_openai
      ArnoldPipeline.reset_configuration!
    end

    private

    def with_user_config_path(path)
      original = ArnoldPipeline::Cli::USER_CONFIG_PATH
      ArnoldPipeline::Cli.send(:remove_const, :USER_CONFIG_PATH)
      ArnoldPipeline::Cli.const_set(:USER_CONFIG_PATH, path)
      yield
    ensure
      ArnoldPipeline::Cli.send(:remove_const, :USER_CONFIG_PATH)
      ArnoldPipeline::Cli.const_set(:USER_CONFIG_PATH, original)
    end

    def capture_output
      original_stdout = $stdout
      $stdout = StringIO.new
      yield
      $stdout.string
    ensure
      $stdout = original_stdout
    end

    def capture_output_and_errors
      original_stdout = $stdout
      original_stderr = $stderr
      $stdout = StringIO.new
      $stderr = StringIO.new
      yield
      { stdout: $stdout.string, stderr: $stderr.string }
    ensure
      $stdout = original_stdout
      $stderr = original_stderr
    end

    def capture_stderr_through_exit
      original_stdout = $stdout
      original_stderr = $stderr
      $stdout = StringIO.new
      $stderr = StringIO.new
      begin
        yield
      rescue SystemExit
        # expected
      end
      $stderr.string
    ensure
      $stdout = original_stdout
      $stderr = original_stderr
    end
  end
end

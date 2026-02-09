require "test_helper"
require "arnold_pipeline/cli"
require "arnold_pipeline/orchestrator"

module ArnoldPipeline
  class CliTest < ActiveSupport::TestCase
    test "list shows pipeline runs" do
      PipelineRun.create!(nl_input: "Build a todo app", status: :completed)
      PipelineRun.create!(nl_input: "Build an API", status: :pending)

      output = capture_output { Cli.start(["list"]) }

      assert_match(/Pipeline Runs:/, output)
      assert_match(/Build a todo app/, output)
      assert_match(/Build an API/, output)
    end

    test "list shows message when no runs" do
      output = capture_output { Cli.start(["list"]) }
      assert_match(/No pipeline runs found/, output)
    end

    test "status shows pipeline run details" do
      run_record = PipelineRun.create!(nl_input: "Build a todo app", status: :completed)
      run_record.create_specification!(content: "# Spec", version: 1)
      run_record.iterations.create!(number: 1, decision: "done", confidence: 95)

      output = capture_output { Cli.start(["status", run_record.id.to_s]) }

      assert_match(/Pipeline Run ##{run_record.id}/, output)
      assert_match(/completed/, output)
      assert_match(/Spec version: 1/, output)
      assert_match(/done.*95%/, output)
    end

    test "status with non-existent ID exits with error" do
      assert_raises(SystemExit) do
        capture_output_and_errors { Cli.start(["status", "99999"]) }
      end
    end

    test "spec outputs specification content" do
      run_record = PipelineRun.create!(nl_input: "Build a todo app", status: :completed)
      run_record.create_specification!(content: "# Todo App Spec\n\nFeatures here.", version: 2)

      output = capture_output { Cli.start(["spec", run_record.id.to_s]) }

      assert_match(/# Todo App Spec/, output)
      assert_match(/Features here/, output)
    end

    test "spec outputs structured JSON with --json flag" do
      run_record = PipelineRun.create!(nl_input: "Build a todo app", status: :completed)
      run_record.create_specification!(
        content: "# Spec",
        structured_data: { "features" => ["auth", "todos"] },
        version: 1
      )

      output = capture_output { Cli.start(["spec", run_record.id.to_s, "--json"]) }

      parsed = JSON.parse(output)
      assert_equal ["auth", "todos"], parsed["features"]
    end

    test "spec writes to file with --output flag" do
      run_record = PipelineRun.create!(nl_input: "Build a todo app", status: :completed)
      run_record.create_specification!(content: "# Spec content", version: 1)

      outfile = File.join(Dir.tmpdir, "arnold_spec_test_#{SecureRandom.hex(4)}.md")

      output = capture_output { Cli.start(["spec", run_record.id.to_s, "--output", outfile]) }

      assert_match(/written to/, output)
      assert_equal "# Spec content", File.read(outfile)
    ensure
      File.delete(outfile) if outfile && File.exist?(outfile)
    end

    test "spec with non-existent ID exits with error" do
      assert_raises(SystemExit) do
        capture_output_and_errors { Cli.start(["spec", "99999"]) }
      end
    end

    test "spec with no specification exits with error" do
      run_record = PipelineRun.create!(nl_input: "Build a todo app", status: :pending)

      assert_raises(SystemExit) do
        capture_output_and_errors { Cli.start(["spec", run_record.id.to_s]) }
      end
    end

    test "version shows version string" do
      output = capture_output { Cli.start(["version"]) }
      assert_match(/arnold_pipeline #{ArnoldPipeline::VERSION}/, output)
    end

    test "exit_on_failure? returns true" do
      assert Cli.exit_on_failure?
    end

    test "--version flag shows version string" do
      output = capture_output { Cli.start(["--version"]) }
      assert_match(/arnold_pipeline #{ArnoldPipeline::VERSION}/, output)
    end

    test "-v flag shows version string" do
      output = capture_output { Cli.start(["-v"]) }
      assert_match(/arnold_pipeline #{ArnoldPipeline::VERSION}/, output)
    end

    test "run calls orchestrator with nl_input and displays result" do
      mock_run = PipelineRun.create!(nl_input: "Build a todo app", status: :completed)

      mock_orchestrator = mock("orchestrator")
      mock_orchestrator.expects(:call).with(nl_input: "Build a todo app", stop_after: nil).returns(mock_run)

      ArnoldPipeline::Orchestrator.stubs(:new).returns(mock_orchestrator)

      output = capture_output { Cli.start(["run", "Build a todo app"]) }
      assert_match(/Starting pipeline for: Build a todo app/, output)
      assert_match(/Pipeline completed!/, output)
      assert_match(/Run ID: #{mock_run.id}/, output)
    end

    test "run --stop-after passes stop_after to orchestrator" do
      mock_run = PipelineRun.create!(nl_input: "test", status: :completed)
      mock_orchestrator = mock("orchestrator")
      mock_orchestrator.expects(:call).with(nl_input: "Build an app", stop_after: :spec).returns(mock_run)

      ArnoldPipeline::Orchestrator.stubs(:new).returns(mock_orchestrator)

      output = capture_output { Cli.start(["run", "Build an app", "--stop-after", "spec"]) }
      assert_match(/Starting pipeline/, output)
    end

    test "run --stop-after with invalid value exits with error" do
      assert_raises(SystemExit) do
        capture_output_and_errors { Cli.start(["run", "test", "--stop-after", "invalid"]) }
      end
    end

    test "resume calls orchestrator.resume with paused run" do
      run_record = PipelineRun.create!(nl_input: "Build a todo app", status: :paused)
      mock_orchestrator = mock("orchestrator")
      mock_orchestrator.expects(:resume).with(pipeline_run: run_record, stop_after: nil).returns(run_record)

      ArnoldPipeline::Orchestrator.stubs(:new).returns(mock_orchestrator)

      output = capture_output { Cli.start(["resume", run_record.id.to_s]) }
      assert_match(/Resuming pipeline run/, output)
    end

    test "resume calls orchestrator.resume with failed run" do
      run_record = PipelineRun.create!(nl_input: "Build a todo app", status: :failed)
      mock_orchestrator = mock("orchestrator")
      mock_orchestrator.expects(:resume).with(pipeline_run: run_record, stop_after: nil).returns(run_record)

      ArnoldPipeline::Orchestrator.stubs(:new).returns(mock_orchestrator)

      output = capture_output { Cli.start(["resume", run_record.id.to_s]) }
      assert_match(/Resuming pipeline run/, output)
    end

    test "resume with non-existent ID exits with error" do
      assert_raises(SystemExit) do
        capture_output_and_errors { Cli.start(["resume", "99999"]) }
      end
    end

    test "resume with completed run exits with error" do
      run_record = PipelineRun.create!(nl_input: "Build a todo app", status: :completed)

      assert_raises(SystemExit) do
        capture_output_and_errors { Cli.start(["resume", run_record.id.to_s]) }
      end
    end

    test "resume passes --stop-after to orchestrator" do
      run_record = PipelineRun.create!(nl_input: "Build a todo app", status: :paused)
      mock_orchestrator = mock("orchestrator")
      mock_orchestrator.expects(:resume).with(pipeline_run: run_record, stop_after: :tasks).returns(run_record)

      ArnoldPipeline::Orchestrator.stubs(:new).returns(mock_orchestrator)

      output = capture_output { Cli.start(["resume", run_record.id.to_s, "--stop-after", "tasks"]) }
      assert_match(/Resuming pipeline run/, output)
    end

    test "run shows friendly message for ConfigurationError" do
      ArnoldPipeline::Orchestrator.stubs(:new).raises(ArnoldPipeline::ConfigurationError, "LLM API key is required")

      stderr_output = capture_stderr_through_exit { Cli.start(["run", "Build an app"]) }
      assert_match(/Configuration error:.*LLM API key is required/, stderr_output)
    end

    test "run shows friendly message for missing config file" do
      stderr_output = capture_stderr_through_exit { Cli.start(["run", "Build an app", "--config", "/nonexistent/config.yml"]) }
      assert_match(/File not found/, stderr_output)
    end

    test "run shows friendly message for invalid YAML config" do
      bad_yaml = File.join(Dir.tmpdir, "arnold_bad_yaml_#{SecureRandom.hex(4)}.yml")
      File.write(bad_yaml, "invalid: yaml: [broken")

      stderr_output = capture_stderr_through_exit { Cli.start(["run", "Build an app", "--config", bad_yaml]) }
      assert_match(/Invalid YAML in config file/, stderr_output)
    ensure
      File.delete(bad_yaml) if bad_yaml && File.exist?(bad_yaml)
    end

    test "run with unexpected error shows clean message" do
      ArnoldPipeline::Orchestrator.stubs(:new).raises(RuntimeError, "something went wrong")

      stderr_output = capture_stderr_through_exit { Cli.start(["run", "Build an app"]) }
      assert_match(/Error:.*something went wrong/, stderr_output)
    end

    test "run with unexpected error and --verbose shows backtrace" do
      ArnoldPipeline::Orchestrator.stubs(:new).raises(RuntimeError, "something went wrong")

      stderr_output = capture_stderr_through_exit { Cli.start(["run", "Build an app", "--verbose"]) }
      assert_match(/Error:.*something went wrong/, stderr_output)
      assert_match(/\.rb/, stderr_output) # backtrace includes file references
    end

    test "resume shows friendly message for ConfigurationError" do
      run_record = PipelineRun.create!(nl_input: "Build an app", status: :paused)
      ArnoldPipeline::Orchestrator.stubs(:new).raises(ArnoldPipeline::ConfigurationError, "GitHub token is required")

      stderr_output = capture_stderr_through_exit { Cli.start(["resume", run_record.id.to_s]) }
      assert_match(/Configuration error:.*GitHub token is required/, stderr_output)
    end

    test "list --json outputs valid JSON array" do
      PipelineRun.create!(nl_input: "Build a todo app", status: :completed)
      PipelineRun.create!(nl_input: "Build an API", status: :pending)

      output = capture_output { Cli.start(["list", "--json"]) }

      parsed = JSON.parse(output)
      assert_kind_of Array, parsed
      assert_equal 2, parsed.length
      assert parsed.first.key?("id")
      assert parsed.first.key?("status")
      assert parsed.first.key?("description")
      assert parsed.first.key?("created_at")
    end

    test "list --json with no runs outputs empty array" do
      output = capture_output { Cli.start(["list", "--json"]) }

      parsed = JSON.parse(output)
      assert_equal [], parsed
    end

    test "status --json outputs valid JSON object" do
      run_record = PipelineRun.create!(nl_input: "Build a todo app", status: :completed)
      run_record.create_specification!(content: "# Spec", version: 2)

      output = capture_output { Cli.start(["status", run_record.id.to_s, "--json"]) }

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
      output = capture_output { Cli.start(["run", "--help"]) }
      assert_match(/DESCRIPTION/, output)
    end

    test "resume --help shows usage without crashing" do
      output = capture_output { Cli.start(["resume", "--help"]) }
      assert_match(/ID/, output)
    end

    test "run --dry-run shows summary without executing" do
      mock_run = PipelineRun.create!(nl_input: "Build a recipe app", status: :paused)
      mock_run.tasks.create!(title: "Setup project", tier: 0, position: 0, status: :pending)
      mock_run.tasks.create!(title: "Add models", tier: 1, position: 1, status: :pending)
      mock_run.tasks.create!(title: "Add views", tier: 1, position: 2, status: :pending)

      mock_orchestrator = mock("orchestrator")
      mock_orchestrator.expects(:call).with(nl_input: "Build a recipe app", stop_after: :tasks).returns(mock_run)

      ArnoldPipeline::Orchestrator.stubs(:new).returns(mock_orchestrator)

      ArnoldPipeline.configure { |c| c.github_repo = "test/repo" }

      output = capture_output { Cli.start(["run", "--dry-run", "Build a recipe app"]) }

      assert_match(/DRY RUN/, output)
      assert_match(/Repository: test\/repo/, output)
      assert_match(/Tasks to create: 3/, output)
      assert_match(/Tier 0: 1 task/, output)
      assert_match(/Tier 1: 2 tasks/, output)
      assert_match(/Run without --dry-run to execute/, output)
    ensure
      ArnoldPipeline.reset_configuration!
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

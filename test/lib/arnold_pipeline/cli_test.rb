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

      stderr_output = nil
      original_stderr = $stderr
      $stderr = StringIO.new
      begin
        capture_output { Cli.start(["spec", run_record.id.to_s, "--output", outfile]) }
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

      output = capture_output { Cli.start(["run", "--dry-run", "Build a recipe app"]) }

      assert_match(/DRY RUN/, output)
      assert_match(/Execution provider: github/, output)
      assert_match(/Repository:.*not configured/, output)
      assert_match(/Tasks to create: 3/, output)
      assert_match(/Tier 0: 1 task/, output)
      assert_match(/Tier 1: 2 tasks/, output)
      assert_match(/Run without --preview to execute/, output)
    end

    test "run --preview shows configured execution provider name" do
      mock_run = PipelineRun.create!(nl_input: "Build an app", status: :paused)
      mock_run.tasks.create!(title: "Setup", tier: 0, position: 0, status: :pending)

      mock_orchestrator = mock("orchestrator")
      mock_orchestrator.expects(:call).returns(mock_run)
      ArnoldPipeline::Orchestrator.stubs(:new).returns(mock_orchestrator)

      output = capture_output { Cli.start(["run", "--preview", "--execution-provider", "claude_code", "Build an app"]) }
      assert_match(/Execution provider: claude_code/, output)
      assert_match(/Repo path:.*not configured/, output)
    ensure
      ArnoldPipeline.reset_configuration!
    end

    test "resume applies CLI flags without --config" do
      run_record = PipelineRun.create!(nl_input: "Build a todo app", status: :paused)
      mock_orchestrator = mock("orchestrator")
      mock_orchestrator.expects(:resume).with(pipeline_run: run_record, stop_after: nil).returns(run_record)

      ArnoldPipeline::Orchestrator.stubs(:new).returns(mock_orchestrator)

      capture_output { Cli.start(["resume", run_record.id.to_s, "--execution-provider", "claude_code", "--repo", "owner/repo"]) }
      assert_equal :claude_code, ArnoldPipeline.configuration.execution_provider
      assert_equal "owner/repo", ArnoldPipeline.configuration.github_repo
    ensure
      ArnoldPipeline.reset_configuration!
    end

    test "run with empty description exits with error" do
      assert_raises(SystemExit) do
        capture_output_and_errors { Cli.start(["run", ""]) }
      end
    end

    test "run with whitespace-only description exits with error" do
      assert_raises(SystemExit) do
        capture_output_and_errors { Cli.start(["run", "   "]) }
      end
    end

    test "run with empty description shows error message on stderr" do
      stderr_output = capture_stderr_through_exit { Cli.start(["run", ""]) }
      assert_match(/Description cannot be empty/, stderr_output)
    end

    test "tasks outputs task list" do
      run_record = PipelineRun.create!(nl_input: "Build a todo app", status: :completed)
      run_record.tasks.create!(title: "Setup project", description: "Initialize the project", tier: 0, position: 0, priority: 1, status: :pending, labels: ["setup"], depends_on: [])
      run_record.tasks.create!(title: "Add models", description: "Create data models", tier: 1, position: 1, priority: 2, status: :pending, labels: ["backend"], depends_on: [0])

      output = capture_output { Cli.start(["tasks", run_record.id.to_s]) }

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
      run_record.tasks.create!(title: "Setup project", description: "Initialize", tier: 0, position: 0, priority: 1, status: :pending, labels: ["setup"], depends_on: [])
      run_record.tasks.create!(title: "Add models", description: "Models", tier: 1, position: 1, priority: 2, status: :pending, labels: [], depends_on: [0])

      output = capture_output { Cli.start(["tasks", run_record.id.to_s, "--json"]) }

      parsed = JSON.parse(output)
      assert_kind_of Array, parsed
      assert_equal 2, parsed.length
      first = parsed.first
      assert_equal "Setup project", first["title"]
      assert_equal 0, first["tier"]
      assert_equal 0, first["position"]
      assert_equal 1, first["priority"]
      assert_equal ["setup"], first["labels"]
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
        capture_output { Cli.start(["tasks", run_record.id.to_s, "--output", outfile]) }
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
        capture_output_and_errors { Cli.start(["tasks", "99999"]) }
      end
    end

    test "tasks with no tasks exits with error" do
      run_record = PipelineRun.create!(nl_input: "Build a todo app", status: :pending)

      assert_raises(SystemExit) do
        capture_output_and_errors { Cli.start(["tasks", run_record.id.to_s]) }
      end
    end

    test "spec --history shows revision timeline" do
      run_record = PipelineRun.create!(nl_input: "Build a todo app", status: :completed)
      spec = run_record.create_specification!(content: "# Spec v2", version: 2)
      spec.spec_revisions.create!(version: 1, content: "# Spec v1", change_source: "spec_generation")
      spec.spec_revisions.create!(
        version: 2,
        content: "# Spec v2",
        change_source: "iterate_spec",
        delta_summary: ["ADDED: Auth > Password Reset", "MODIFIED: Auth > Login"]
      )

      output = capture_output { Cli.start(["spec", run_record.id.to_s, "--history"]) }

      assert_match(/Specification Revision History:/, output)
      assert_match(/v1 \[spec_generation\]/, output)
      assert_match(/v2 \[iterate_spec\]/, output)
      assert_match(/ADDED: Auth > Password Reset/, output)
      assert_match(/MODIFIED: Auth > Login/, output)
    end

    test "spec --history with no revisions shows message" do
      run_record = PipelineRun.create!(nl_input: "Build a todo app", status: :completed)
      run_record.create_specification!(content: "# Spec", version: 1)

      output = capture_output { Cli.start(["spec", run_record.id.to_s, "--history"]) }

      assert_match(/No revision history available/, output)
    end

    test "spec --version shows specific version content" do
      run_record = PipelineRun.create!(nl_input: "Build a todo app", status: :completed)
      spec = run_record.create_specification!(content: "# Spec v2", version: 2)
      spec.spec_revisions.create!(version: 1, content: "# Spec version one content")
      spec.spec_revisions.create!(version: 2, content: "# Spec version two content")

      output = capture_output { Cli.start(["spec", run_record.id.to_s, "--version", "1"]) }

      assert_match(/# Spec version one content/, output)
      assert_no_match(/version two/, output)
    end

    test "spec --version with non-existent version exits with error" do
      run_record = PipelineRun.create!(nl_input: "Build a todo app", status: :completed)
      run_record.create_specification!(content: "# Spec", version: 1)

      assert_raises(SystemExit) do
        capture_output_and_errors { Cli.start(["spec", run_record.id.to_s, "--version", "99"]) }
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

      output = capture_output { Cli.start(["log", run_record.id.to_s]) }

      assert_match(/Event Timeline \(2 events\)/, output)
      assert_match(/spec_generation \/ library_selection/, output)
      assert_match(/Software Architect/, output)
      assert_match(/spec_generation \/ spec_generated/, output)
      assert_match(/3413ms/, output)
    end

    test "log filters by --stage" do
      run_record = PipelineRun.create!(nl_input: "Build a todo app", status: :completed)
      run_record.pipeline_events.create!(event_type: :library_selection, stage: "spec_generation", summary: {})
      run_record.pipeline_events.create!(event_type: :tasks_broken, stage: "task_breakdown", summary: {})
      run_record.pipeline_events.create!(event_type: :analysis_completed, stage: "analysis", summary: {})

      output = capture_output { Cli.start(["log", run_record.id.to_s, "--stage", "analysis"]) }

      assert_match(/1 events/, output)
      assert_match(/analysis \/ analysis_completed/, output)
      assert_no_match(/spec_generation/, output)
      assert_no_match(/task_breakdown/, output)
    end

    test "log --json outputs valid JSON array" do
      run_record = PipelineRun.create!(nl_input: "Build a todo app", status: :completed)
      run_record.pipeline_events.create!(
        event_type: :spec_generated, stage: "spec_generation",
        summary: { "content_length" => 100 }, duration_ms: 500.0
      )

      output = capture_output { Cli.start(["log", run_record.id.to_s, "--json"]) }

      parsed = JSON.parse(output)
      assert_kind_of Array, parsed
      assert_equal 1, parsed.length
      assert_equal "spec_generated", parsed.first["event_type"]
      assert_equal "spec_generation", parsed.first["stage"]
      assert_equal({ "content_length" => 100 }, parsed.first["summary"])
    end

    test "log --verbose includes payloads" do
      run_record = PipelineRun.create!(nl_input: "Build a todo app", status: :completed)
      run_record.pipeline_events.create!(
        event_type: :spec_generated, stage: "spec_generation",
        summary: { "content_length" => 100 },
        payload: { "full_response" => "test data" }
      )

      output = capture_output { Cli.start(["log", run_record.id.to_s, "--verbose"]) }

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

      output = capture_output { Cli.start(["log", run_record.id.to_s, "--json", "--verbose"]) }

      parsed = JSON.parse(output)
      assert_equal({ "response" => "data" }, parsed.first["payload"])
    end

    test "log with non-existent ID exits with error" do
      assert_raises(SystemExit) do
        capture_output_and_errors { Cli.start(["log", "99999"]) }
      end
    end

    test "log with no events shows message" do
      run_record = PipelineRun.create!(nl_input: "Build a todo app", status: :completed)

      output = capture_output { Cli.start(["log", run_record.id.to_s]) }

      assert_match(/No events found/, output)
    end

    test "log formats lifecycle events" do
      run_record = PipelineRun.create!(nl_input: "Build a todo app", status: :completed)
      run_record.pipeline_events.create!(
        event_type: :pipeline_completed, stage: "lifecycle",
        summary: { "total_iterations" => 2, "total_tasks" => 10 }
      )

      output = capture_output { Cli.start(["log", run_record.id.to_s]) }

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

      output = capture_output { Cli.start(["log", run_record.id.to_s]) }

      assert_match(/Criteria: 3 verified, 1 failed, 2 unverified/, output)
      # Without --verbose, individual criteria should not show
      assert_no_match(/PASS:/, output)
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

      output = capture_output { Cli.start(["log", run_record.id.to_s, "--verbose"]) }

      assert_match(/PASS: Gemfile exists \(file_exists\)/, output)
      assert_match(/FAIL: Health check route \(route_exists\)/, output)
    end

    test "log --verbose shows corrective tasks for tier_gate_evaluated" do
      run_record = PipelineRun.create!(nl_input: "Build a todo app", status: :completed)
      run_record.pipeline_events.create!(
        event_type: :tier_gate_evaluated, stage: "tier_gate",
        summary: {
          "pass" => false,
          "issues" => ["Missing route"],
          "corrective_task_count" => 1,
          "corrective_tasks" => [
            { "title" => "Add route", "description" => "Add GET /up to routes.rb" }
          ]
        },
        duration_ms: 5000.0
      )

      output = capture_output { Cli.start(["log", run_record.id.to_s, "--verbose"]) }

      assert_match(/Gate: FAILED — Missing route/, output)
      assert_match(/Corrective tasks:/, output)
      assert_match(/1\. Add route/, output)
      assert_match(/Add GET \/up to routes\.rb/, output)
    end

    test "run --quiet suppresses informational output" do
      mock_run = PipelineRun.create!(nl_input: "Build a todo app", status: :completed)

      mock_orchestrator = mock("orchestrator")
      mock_orchestrator.expects(:call).with(nl_input: "Build a todo app", stop_after: nil).returns(mock_run)

      ArnoldPipeline::Orchestrator.stubs(:new).returns(mock_orchestrator)

      output = capture_output { Cli.start(["run", "Build a todo app", "--quiet"]) }
      assert_equal "", output
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

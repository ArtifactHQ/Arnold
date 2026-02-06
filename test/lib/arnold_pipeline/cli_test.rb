require "test_helper"
require "arnold_pipeline/cli"

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

    test "status shows not found for invalid ID" do
      output = capture_output { Cli.start(["status", "99999"]) }
      assert_match(/not found/, output)
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

    test "spec shows not found for invalid ID" do
      output = capture_output { Cli.start(["spec", "99999"]) }
      assert_match(/not found/, output)
    end

    test "spec shows message when no specification exists" do
      run_record = PipelineRun.create!(nl_input: "Build a todo app", status: :pending)

      output = capture_output { Cli.start(["spec", run_record.id.to_s]) }
      assert_match(/No specification found/, output)
    end

    test "version shows version string" do
      output = capture_output { Cli.start(["version"]) }
      assert_match(/arnold_pipeline #{ArnoldPipeline::VERSION}/, output)
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

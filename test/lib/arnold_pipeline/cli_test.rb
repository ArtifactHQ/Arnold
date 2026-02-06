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

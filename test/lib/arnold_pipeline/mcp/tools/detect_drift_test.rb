require "test_helper"
require "arnold_pipeline/mcp/context"
require "arnold_pipeline/mcp/tools/detect_drift"

module ArnoldPipeline
  module Mcp
    module Tools
      class DetectDriftTest < ActiveSupport::TestCase
        cover "ArnoldPipeline::Mcp::Tools::DetectDrift*"

        setup do
          @context = Context.new
          @run = PipelineRun.create!(nl_input: "Build a todo app")
          @spec = @run.create_specification!(content: "# Todo App\n## Authentication\nLogin and signup\n## Todos\nCRUD operations", version: 1)
          @revision = @spec.spec_revisions.create!(version: 1, content: @spec.content, change_source: "spec_generation")

          @task_with_diff = Task.create!(
            pipeline_run: @run,
            title: "Setup auth",
            description: "Build authentication",
            position: 0,
            status: :completed,
            labels: ["authentication"],
            result_diff: "+class User < ApplicationRecord\n+end"
          )

          @task_empty_diff = Task.create!(
            pipeline_run: @run,
            title: "Build todos",
            description: "Create todo model",
            position: 1,
            status: :completed,
            labels: ["todos"],
            result_diff: nil
          )

          # Stub LLM build to avoid provider initialization
          @mock_llm = stub("llm")
          DetectDrift.stubs(:build_llm).returns(@mock_llm)
        end

        teardown do
          ArnoldPipeline.reset_configuration!
        end

        test "tool_name returns detect_drift" do
          assert_equal "detect_drift", DetectDrift.tool_name
        end

        test "description is present" do
          assert_kind_of String, DetectDrift.description
          refute_empty DetectDrift.description
        end

        test "input_schema has expected properties" do
          schema = DetectDrift.input_schema
          assert_equal "object", schema[:type]
          assert schema[:properties].key?(:scope)
          assert schema[:properties].key?(:target)
          assert schema[:properties].key?(:run_id)
          assert schema[:properties].key?(:depth)
        end

        test "returns findings for tasks with empty diffs using structural depth" do
          result = DetectDrift.call({ "depth" => "structural" }, @context)

          assert_equal "drift_detected", result[:status]
          assert result[:findings].any? { |f| f[:description].include?("no code changes") }
        end

        test "returns clean when all completed tasks have diffs" do
          @task_empty_diff.update!(result_diff: "+class Todo\n+end")

          result = DetectDrift.call({ "depth" => "structural" }, @context)

          # May still have structural section-coverage findings, but no empty-diff findings
          empty_diff_findings = result[:findings].select { |f| f[:description].include?("no code changes") }
          assert_empty empty_diff_findings
        end

        test "persists findings as DriftFinding records" do
          assert_difference "DriftFinding.count" do
            DetectDrift.call({ "depth" => "structural" }, @context)
          end

          finding = DriftFinding.last
          assert_equal @run.id, finding.pipeline_run_id
          assert_equal "structural", finding.drift_type
          assert_not_nil finding.description
        end

        test "excludes accepted findings for same revision" do
          # Create an accepted finding with the same description
          DriftFinding.create!(
            pipeline_run: @run,
            spec_revision: @revision,
            drift_type: "structural",
            severity: "warning",
            description: "Completed task 'Build todos' has no code changes (empty diff).",
            resolution: "accepted",
            resolved_at: Time.current
          )

          result = DetectDrift.call({ "depth" => "structural" }, @context)

          # The accepted finding should be excluded
          matching = result[:findings].select { |f| f[:description].include?("Build todos") && f[:description].include?("no code changes") }
          assert_empty matching
        end

        test "coverage stats are accurate" do
          result = DetectDrift.call({ "depth" => "structural" }, @context)

          coverage = result[:coverage]
          assert_kind_of Hash, coverage
          assert coverage.key?(:domains_checked)
          assert coverage.key?(:domains_clean)
          assert coverage.key?(:domains_drifted)
          assert coverage.key?(:tasks_checked)
          assert coverage.key?(:tasks_clean)
          assert coverage.key?(:tasks_drifted)
          assert_equal 2, coverage[:tasks_checked] # 2 completed tasks
        end

        test "scope filtering works for domain" do
          result = DetectDrift.call({ "scope" => "domain", "target" => "authentication", "depth" => "structural" }, @context)

          # Should not include findings about the todos task
          assert result[:findings].none? { |f| f[:description].include?("Build todos") && f[:description].include?("no code changes") }
        end

        test "scope filtering works for task" do
          result = DetectDrift.call({ "scope" => "task", "target" => @task_with_diff.id.to_s, "depth" => "structural" }, @context)

          # Should not include findings about the empty-diff task
          assert result[:findings].none? { |f| f[:description].include?("Build todos") && f[:description].include?("no code changes") }
        end

        test "returns error when no pipeline run found" do
          PipelineRun.destroy_all

          result = DetectDrift.call({}, @context)

          assert_equal "No pipeline run found", result[:error]
        end

        test "returns error when no specification found" do
          @run.specification.destroy!

          result = DetectDrift.call({}, @context)

          assert_includes result[:error], "No specification found"
        end

        test "returns run_id and revision in response" do
          result = DetectDrift.call({ "depth" => "structural" }, @context)

          assert_equal @run.id.to_s, result[:run_id]
          assert_equal @revision.version.to_s, result[:revision]
        end

        test "accepts run_id parameter" do
          other_run = PipelineRun.create!(nl_input: "Other project")
          other_spec = other_run.create_specification!(content: "# Other spec", version: 1)
          Task.create!(
            pipeline_run: other_run,
            title: "Other task",
            position: 0,
            status: :completed,
            labels: ["other"],
            result_diff: "+code"
          )

          result = DetectDrift.call({ "run_id" => other_run.id.to_s, "depth" => "structural" }, @context)

          assert_equal other_run.id.to_s, result[:run_id]
        end

        test "summary describes findings" do
          result = DetectDrift.call({ "depth" => "structural" }, @context)

          assert_kind_of String, result[:summary]
          if result[:status] == "drift_detected"
            assert_includes result[:summary], "finding"
          else
            assert_includes result[:summary], "No drift detected"
          end
        end

        test "depth parameter controls which checks run" do
          # Structural only - no LLM calls
          Agents::DriftDetector.any_instance.expects(:detect_behavioral_drift).never
          Agents::DriftDetector.any_instance.expects(:detect_intent_drift).never

          DetectDrift.call({ "depth" => "structural" }, @context)
        end

        test "findings have required keys" do
          result = DetectDrift.call({ "depth" => "structural" }, @context)

          next if result[:findings].empty?

          finding = result[:findings].first
          required_keys = %i[finding_id domain type severity description spec_expectation actual_state files_examined affected_tasks recommendation]
          required_keys.each do |key|
            assert finding.key?(key), "Finding missing key: #{key}"
          end
        end
      end
    end
  end
end

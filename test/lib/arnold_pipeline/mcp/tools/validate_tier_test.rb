require "test_helper"
require "arnold_pipeline/mcp/context"
require "arnold_pipeline/mcp/tools/validate_tier"

module ArnoldPipeline
  module Mcp
    module Tools
      class ValidateTierTest < ActiveSupport::TestCase
        cover "ArnoldPipeline::Mcp::Tools::ValidateTier*"

        setup do
          @context = Context.new
          @run = PipelineRun.create!(nl_input: "Build a todo app")
          @t0_task1 = Task.create!(
            pipeline_run: @run,
            title: "Setup database",
            description: "Create the database schema",
            position: 0,
            tier: 0,
            status: :completed,
            labels: ["backend"],
            depends_on: [],
            result_comments: [{ "body" => "Schema created" }],
            execution_metadata: { "files_changed" => ["db/schema.rb"] }
          )
          @t0_task2 = Task.create!(
            pipeline_run: @run,
            title: "Setup models",
            description: "Create ActiveRecord models",
            position: 1,
            tier: 0,
            status: :completed,
            labels: ["backend"],
            depends_on: [],
            result_comments: [{ "body" => "Models created" }],
            execution_metadata: { "files_changed" => ["app/models/todo.rb"] }
          )
          @t1_task1 = Task.create!(
            pipeline_run: @run,
            title: "Build API",
            description: "Create REST endpoints",
            position: 2,
            tier: 1,
            status: :pending,
            labels: ["backend", "api"],
            depends_on: [@t0_task1.id.to_s]
          )
          @t1_task2 = Task.create!(
            pipeline_run: @run,
            title: "Build controllers",
            description: "Create controllers",
            position: 3,
            tier: 1,
            status: :pending,
            labels: ["backend"],
            depends_on: [@t0_task2.id.to_s]
          )
        end

        teardown do
          ArnoldPipeline.reset_configuration!
        end

        test "tool_name returns validate_tier" do
          assert_equal "validate_tier", ValidateTier.tool_name
        end

        test "description is present" do
          assert_kind_of String, ValidateTier.description
          refute_empty ValidateTier.description
        end

        test "input_schema requires tier" do
          schema = ValidateTier.input_schema
          assert_equal "object", schema[:type]
          assert schema[:properties].key?(:tier)
          assert schema[:properties].key?(:run_id)
          assert schema[:properties].key?(:include_drift_check)
          assert_includes schema[:required], "tier"
        end

        test "call returns pass for fully completed tier 0" do
          result = ValidateTier.call({ "tier" => 0 }, @context)

          assert_equal 0, result[:tier]
          assert_equal "pass", result[:verdict]
          assert_kind_of String, result[:summary]
          assert_kind_of Array, result[:checks]
          assert_kind_of Array, result[:issues]
          assert_empty result[:issues]
        end

        test "call returns fail when tasks are incomplete" do
          @t0_task1.update!(status: :in_progress)

          result = ValidateTier.call({ "tier" => 0 }, @context)

          assert_equal "fail", result[:verdict]
          assert result[:issues].any? { |i| i[:severity] == "blocking" }
        end

        test "call includes task_completion check" do
          result = ValidateTier.call({ "tier" => 0 }, @context)

          completion_check = result[:checks].find { |c| c[:check] == "task_completion" }
          assert_not_nil completion_check
          assert_equal "pass", completion_check[:result]
          assert_includes completion_check[:detail], "2"
        end

        test "call includes dependencies check" do
          result = ValidateTier.call({ "tier" => 0 }, @context)

          dep_check = result[:checks].find { |c| c[:check] == "dependencies" }
          assert_not_nil dep_check
          assert_equal "pass", dep_check[:result]
        end

        test "call dependencies check passes for tier 0" do
          result = ValidateTier.call({ "tier" => 0 }, @context)

          dep_check = result[:checks].find { |c| c[:check] == "dependencies" }
          assert_equal "pass", dep_check[:result]
          assert_includes dep_check[:detail], "Tier 0"
        end

        test "call dependencies check fails when prior tier tasks incomplete" do
          @t0_task1.update!(status: :in_progress)
          @t1_task1.update!(status: :in_progress)
          @t1_task1.update!(status: :completed)
          @t1_task2.update!(status: :in_progress)
          @t1_task2.update!(status: :completed)

          result = ValidateTier.call({ "tier" => 1 }, @context)

          dep_check = result[:checks].find { |c| c[:check] == "dependencies" }
          assert_equal "fail", dep_check[:result]
          assert_includes dep_check[:detail], "Setup database"
        end

        test "call includes result_data check" do
          result = ValidateTier.call({ "tier" => 0 }, @context)

          result_check = result[:checks].find { |c| c[:check] == "result_data" }
          assert_not_nil result_check
          assert_equal "pass", result_check[:result]
        end

        test "call result_data check warns when completed tasks have no result data" do
          @t0_task1.update!(result_comments: [], execution_metadata: {})

          result = ValidateTier.call({ "tier" => 0 }, @context)

          result_check = result[:checks].find { |c| c[:check] == "result_data" }
          assert_equal "warning", result_check[:result]
          assert_includes result_check[:detail], "Setup database"
        end

        test "call returns conditional verdict for warnings only" do
          @t0_task1.update!(result_comments: [], execution_metadata: {})

          result = ValidateTier.call({ "tier" => 0 }, @context)

          assert_equal "conditional", result[:verdict]
          assert result[:issues].any? { |i| i[:severity] == "warning" }
          assert result[:issues].none? { |i| i[:severity] == "blocking" }
        end

        test "call returns next_tier info when passing" do
          result = ValidateTier.call({ "tier" => 0 }, @context)

          assert_not_nil result[:next_tier]
          assert_equal 1, result[:next_tier][:tier]
          assert_equal 2, result[:next_tier][:task_count]
          assert_equal true, result[:next_tier][:ready]
        end

        test "call returns nil next_tier when no tasks in next tier" do
          Task.where(tier: 1).destroy_all

          result = ValidateTier.call({ "tier" => 0 }, @context)

          assert_nil result[:next_tier]
        end

        test "call does not return next_tier when verdict is fail" do
          @t0_task1.update!(status: :in_progress)

          result = ValidateTier.call({ "tier" => 0 }, @context)

          assert_equal "fail", result[:verdict]
          assert_nil result[:next_tier]
        end

        test "call returns drift status clean by default" do
          result = ValidateTier.call({ "tier" => 0 }, @context)

          assert_equal "clean", result[:drift][:status]
          assert_empty result[:drift][:findings]
        end

        test "call returns drift placeholder when include_drift_check is true" do
          result = ValidateTier.call({ "tier" => 0, "include_drift_check" => true }, @context)

          assert_equal "clean", result[:drift][:status]
          assert result[:drift][:findings].any? { |f| f[:message].include?("Phase 3") }
        end

        test "call returns error when no pipeline run found" do
          PipelineRun.destroy_all
          result = ValidateTier.call({ "tier" => 0 }, @context)
          assert_equal "No pipeline run found", result[:error]
        end

        test "call returns error when no tasks in tier" do
          result = ValidateTier.call({ "tier" => 99 }, @context)
          assert_includes result[:error], "No tasks found for tier 99"
        end

        test "call returns error when tier is nil" do
          result = ValidateTier.call({}, @context)
          assert_equal "tier is required", result[:error]
        end

        test "call accepts run_id parameter" do
          other_run = PipelineRun.create!(nl_input: "Other project")
          Task.create!(
            pipeline_run: other_run,
            title: "Other task",
            position: 0,
            tier: 0,
            status: :completed,
            result_comments: [{ "body" => "done" }]
          )

          result = ValidateTier.call({
            "run_id" => other_run.id.to_s,
            "tier" => 0
          }, @context)

          assert_equal "pass", result[:verdict]
          assert_equal 1, result[:checks].find { |c| c[:check] == "task_completion" }[:detail].scan(/\d+/).first.to_i
        end

        test "call summary includes tier number and verdict" do
          result = ValidateTier.call({ "tier" => 0 }, @context)

          assert_includes result[:summary], "Tier 0"
          assert_includes result[:summary], "pass"
        end

        test "call issues include affected_tasks for blocking issues" do
          @t0_task1.update!(status: :in_progress)

          result = ValidateTier.call({ "tier" => 0 }, @context)

          blocking = result[:issues].find { |i| i[:severity] == "blocking" }
          assert_not_nil blocking
          assert_includes blocking[:affected_tasks], @t0_task1.id.to_s
          assert_kind_of String, blocking[:recommendation]
        end

        test "call checks do not include extra keys" do
          result = ValidateTier.call({ "tier" => 0 }, @context)

          result[:checks].each do |check|
            assert_equal %i[check detail result], check.keys.sort
          end
        end

        test "call handles tier with all tasks having result data" do
          result = ValidateTier.call({ "tier" => 0 }, @context)

          result_check = result[:checks].find { |c| c[:check] == "result_data" }
          assert_equal "pass", result_check[:result]
          assert_includes result_check[:detail], "All completed tasks have result data"
        end

        test "call dependencies satisfied for tier 1 when tier 0 complete" do
          @t1_task1.update!(status: :in_progress)
          @t1_task1.update!(status: :completed)
          @t1_task1.update!(result_comments: [{ "body" => "done" }])
          @t1_task2.update!(status: :in_progress)
          @t1_task2.update!(status: :completed)
          @t1_task2.update!(result_comments: [{ "body" => "done" }])

          result = ValidateTier.call({ "tier" => 1 }, @context)

          dep_check = result[:checks].find { |c| c[:check] == "dependencies" }
          assert_equal "pass", dep_check[:result]
        end
      end
    end
  end
end

require "test_helper"
require "arnold_pipeline/agents/tier_gate_check"

module ArnoldPipeline
  module Agents
    class TierGateCheckTest < ActiveSupport::TestCase
      setup do
        @llm = stub("llm")
        @agent = TierGateCheck.new(llm: @llm, logger: Logger.new(File::NULL))
      end

      test "returns pass=true result with context_summary" do
        result = {
          "pass" => true,
          "issues" => [],
          "context_summary" => "Set up Rails project with PostgreSQL and User model.",
          "corrective_tasks" => []
        }
        @llm.expects(:chat).returns("```json\n#{JSON.generate(result)}\n```")

        response = @agent.call(
          tier_number: 0,
          task_summaries: "- Setup DB",
          diffs: "diff content"
        )

        assert_equal true, response["pass"]
        assert_equal "Set up Rails project with PostgreSQL and User model.", response["context_summary"]
      end

      test "returns pass=false result with corrective_tasks" do
        result = {
          "pass" => false,
          "issues" => ["Missing database.yml configuration"],
          "context_summary" => "Attempted database setup but config is missing.",
          "corrective_tasks" => [
            { "title" => "Fix database config", "description" => "Add database.yml", "labels" => ["bugfix"] }
          ]
        }
        @llm.expects(:chat).returns("```json\n#{JSON.generate(result)}\n```")

        response = @agent.call(
          tier_number: 0,
          task_summaries: "- Setup DB",
          diffs: "diff content"
        )

        assert_equal false, response["pass"]
        assert_equal 1, response["corrective_tasks"].size
        assert_equal "Fix database config", response["corrective_tasks"].first["title"]
      end

      test "raises on invalid pass value" do
        result = {
          "pass" => "yes",
          "issues" => [],
          "context_summary" => "Summary",
          "corrective_tasks" => []
        }
        @llm.expects(:chat).returns("```json\n#{JSON.generate(result)}\n```")

        assert_raises(ArnoldPipeline::Error) do
          @agent.call(tier_number: 0, task_summaries: "tasks", diffs: "diffs")
        end
      end

      test "raises on missing context_summary" do
        result = {
          "pass" => true,
          "issues" => [],
          "context_summary" => "",
          "corrective_tasks" => []
        }
        @llm.expects(:chat).returns("```json\n#{JSON.generate(result)}\n```")

        assert_raises(ArnoldPipeline::Error) do
          @agent.call(tier_number: 0, task_summaries: "tasks", diffs: "diffs")
        end
      end

      test "raises on nil context_summary" do
        result = {
          "pass" => true,
          "issues" => [],
          "corrective_tasks" => []
        }
        @llm.expects(:chat).returns("```json\n#{JSON.generate(result)}\n```")

        assert_raises(ArnoldPipeline::Error) do
          @agent.call(tier_number: 0, task_summaries: "tasks", diffs: "diffs")
        end
      end

      test "raises on corrective_task without title" do
        result = {
          "pass" => false,
          "issues" => ["broken"],
          "context_summary" => "Something was built.",
          "corrective_tasks" => [{ "description" => "Fix it" }]
        }
        @llm.expects(:chat).returns("```json\n#{JSON.generate(result)}\n```")

        assert_raises(ArnoldPipeline::Error) do
          @agent.call(tier_number: 0, task_summaries: "tasks", diffs: "diffs")
        end
      end

      test "passes comments through to prompt" do
        result = {
          "pass" => true,
          "issues" => [],
          "context_summary" => "Built the foundation.",
          "corrective_tasks" => []
        }
        @llm.expects(:chat).with { |params|
          user_msg = params[:messages].first[:content]
          user_msg.include?("### Task Comments / Agent Feedback") &&
            user_msg.include?("Missing Gemfile")
        }.returns("```json\n#{JSON.generate(result)}\n```")

        @agent.call(
          tier_number: 0,
          task_summaries: "- Setup DB",
          diffs: "diff content",
          comments: "### Task: Setup DB (failed)\n[issue] copilot: Missing Gemfile"
        )
      end
    end
  end
end

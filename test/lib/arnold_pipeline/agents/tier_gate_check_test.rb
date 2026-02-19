require "test_helper"
require "arnold_pipeline/agents/tier_gate_check"
require "json_schemer"

module ArnoldPipeline
  module Agents
    class TierGateCheckTest < ActiveSupport::TestCase
      cover "ArnoldPipeline::Agents::TierGateCheck*"

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
        @llm.expects(:chat_json).returns(result)

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
        @llm.expects(:chat_json).returns(result)

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
        @llm.expects(:chat_json).returns(result)

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
        @llm.expects(:chat_json).returns(result)

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
        @llm.expects(:chat_json).returns(result)

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
        @llm.expects(:chat_json).returns(result)

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
        @llm.expects(:chat_json).with { |params|
          user_msg = params[:messages].first[:content]
          user_msg.include?("### Task Comments / Agent Feedback") &&
            user_msg.include?("Missing Gemfile")
        }.returns(result)

        @agent.call(
          tier_number: 0,
          task_summaries: "- Setup DB",
          diffs: "diff content",
          comments: "### Task: Setup DB (failed)\n[issue] copilot: Missing Gemfile"
        )
      end

      test "passes repo_context through to prompt" do
        result = {
          "pass" => true,
          "issues" => [],
          "context_summary" => "Built the foundation.",
          "corrective_tasks" => []
        }
        @llm.expects(:chat_json).with { |params|
          user_msg = params[:messages].first[:content]
          user_msg.include?("### Repository Baseline") &&
            user_msg.include?("db/migrate/") &&
            user_msg.include?("Do NOT flag them as missing")
        }.returns(result)

        @agent.call(
          tier_number: 0,
          task_summaries: "- Setup DB",
          diffs: "diff content",
          repo_context: "  db/migrate/ (2 files): 001_create_users.rb, 002_create_posts.rb"
        )
      end

      test "works without repo_context (backward compatible)" do
        result = {
          "pass" => true,
          "issues" => [],
          "context_summary" => "Built the foundation.",
          "corrective_tasks" => []
        }
        @llm.expects(:chat_json).with { |params|
          user_msg = params[:messages].first[:content]
          !user_msg.include?("Repository Baseline")
        }.returns(result)

        @agent.call(
          tier_number: 0,
          task_summaries: "- Setup DB",
          diffs: "diff content"
        )
      end

      test "passes verification_results through to prompt" do
        result = {
          "pass" => true,
          "issues" => [],
          "context_summary" => "Built the foundation.",
          "corrective_tasks" => []
        }
        @llm.expects(:chat_json).with { |params|
          user_msg = params[:messages].first[:content]
          user_msg.include?("### Empirical Verification Results") &&
            user_msg.include?("ALL PASSED")
        }.returns(result)

        @agent.call(
          tier_number: 0,
          task_summaries: "- Setup DB",
          diffs: "diff content",
          verification_results: {
            all_passed: true,
            summary: "1 passed, 0 failed: boot=OK",
            checks: [{ name: "boot", type: :boot, success: true, stdout: "", stderr: "" }]
          }
        )
      end

      test "works without verification_results (backward compatible)" do
        result = {
          "pass" => true,
          "issues" => [],
          "context_summary" => "Built the foundation.",
          "corrective_tasks" => []
        }
        @llm.expects(:chat_json).with { |params|
          user_msg = params[:messages].first[:content]
          !user_msg.include?("Empirical Verification Results")
        }.returns(result)

        @agent.call(
          tier_number: 0,
          task_summaries: "- Setup DB",
          diffs: "diff content"
        )
      end

      # -- Schema validation --

      test "RESPONSE_SCHEMA validates a passing gate result" do
        schemer = JSONSchemer.schema(TierGateCheck::RESPONSE_SCHEMA[:schema])
        data = {
          "pass" => true, "issues" => [], "context_summary" => "All good.",
          "corrective_tasks" => []
        }
        assert schemer.valid?(data), "Expected valid, got: #{schemer.validate(data).map(&:to_h)}"
      end

      test "RESPONSE_SCHEMA validates a failing gate result with corrective tasks" do
        schemer = JSONSchemer.schema(TierGateCheck::RESPONSE_SCHEMA[:schema])
        data = {
          "pass" => false, "issues" => ["Build broken"],
          "context_summary" => "Database setup failed.",
          "corrective_tasks" => [
            { "title" => "Fix DB", "description" => "Reconfigure", "labels" => ["bugfix"] }
          ]
        }
        assert schemer.valid?(data), "Expected valid, got: #{schemer.validate(data).map(&:to_h)}"
      end

      test "RESPONSE_SCHEMA rejects missing required fields" do
        schemer = JSONSchemer.schema(TierGateCheck::RESPONSE_SCHEMA[:schema])
        data = { "pass" => true }
        refute schemer.valid?(data)
      end
    end
  end
end

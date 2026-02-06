require "test_helper"
require "arnold_pipeline/prompts/tier_gate"

module ArnoldPipeline
  module Prompts
    class TierGateTest < ActiveSupport::TestCase
      test "system_prompt includes key terms" do
        prompt = TierGate.system_prompt
        assert_includes prompt, "pass"
        assert_includes prompt, "context_summary"
        assert_includes prompt, "corrective_tasks"
        assert_includes prompt, "issues"
      end

      test "system_prompt includes gate review guidelines" do
        prompt = TierGate.system_prompt
        assert_includes prompt, "tier gate reviewer"
        assert_includes prompt, "pass=false"
        assert_includes prompt, "minimal"
      end

      test "user_prompt includes tier number" do
        prompt = TierGate.user_prompt(
          tier_number: 2,
          task_summaries: "- Setup DB",
          diffs: "diff content"
        )
        assert_includes prompt, "Tier 2 Gate Review"
      end

      test "user_prompt includes task summaries and diffs" do
        prompt = TierGate.user_prompt(
          tier_number: 0,
          task_summaries: "- **Setup DB**: Create schema",
          diffs: "+class User < ApplicationRecord"
        )
        assert_includes prompt, "Setup DB"
        assert_includes prompt, "ApplicationRecord"
      end

      test "user_prompt includes comments when provided" do
        prompt = TierGate.user_prompt(
          tier_number: 0,
          task_summaries: "- Setup DB",
          diffs: "diff",
          comments: "### Task: Setup DB (failed)\n[issue] copilot: Missing Gemfile"
        )
        assert_includes prompt, "### Task Comments / Agent Feedback"
        assert_includes prompt, "Missing Gemfile"
      end

      test "user_prompt omits comments when empty" do
        prompt = TierGate.user_prompt(
          tier_number: 0,
          task_summaries: "- Setup DB",
          diffs: "diff",
          comments: ""
        )
        refute_includes prompt, "### Task Comments / Agent Feedback"
      end

      test "user_prompt omits comments when not provided" do
        prompt = TierGate.user_prompt(
          tier_number: 0,
          task_summaries: "- Setup DB",
          diffs: "diff"
        )
        refute_includes prompt, "### Task Comments / Agent Feedback"
      end
    end
  end
end

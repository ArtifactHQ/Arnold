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

      test "system_prompt includes empty diff handling guidance" do
        prompt = TierGate.system_prompt
        assert_includes prompt, "FAILED - EMPTY DIFF"
        assert_includes prompt, "ONE corrective task"
      end

      test "user_prompt omits comments when not provided" do
        prompt = TierGate.user_prompt(
          tier_number: 0,
          task_summaries: "- Setup DB",
          diffs: "diff"
        )
        refute_includes prompt, "### Task Comments / Agent Feedback"
      end

      test "system_prompt includes incremental pipeline awareness" do
        prompt = TierGate.system_prompt
        assert_includes prompt, "Incremental Pipeline Awareness"
        assert_includes prompt, "Repository Baseline"
        assert_includes prompt, "ALREADY EXIST"
      end

      test "user_prompt includes repo baseline when repo_context provided" do
        prompt = TierGate.user_prompt(
          tier_number: 0,
          task_summaries: "- Setup DB",
          diffs: "diff",
          repo_context: "  db/migrate/ (2 files): 001_create_users.rb, 002_create_posts.rb"
        )
        assert_includes prompt, "### Repository Baseline (files already in repo)"
        assert_includes prompt, "Do NOT flag them as missing"
        assert_includes prompt, "db/migrate/"
        assert_includes prompt, "001_create_users.rb"
      end

      test "user_prompt omits repo baseline when repo_context is nil" do
        prompt = TierGate.user_prompt(
          tier_number: 0,
          task_summaries: "- Setup DB",
          diffs: "diff",
          repo_context: nil
        )
        refute_includes prompt, "Repository Baseline"
      end

      test "user_prompt omits repo baseline when repo_context is empty" do
        prompt = TierGate.user_prompt(
          tier_number: 0,
          task_summaries: "- Setup DB",
          diffs: "diff",
          repo_context: ""
        )
        refute_includes prompt, "Repository Baseline"
      end

      test "user_prompt places repo baseline before comments" do
        prompt = TierGate.user_prompt(
          tier_number: 0,
          task_summaries: "- Setup DB",
          diffs: "diff",
          comments: "some feedback",
          repo_context: "  config/ (1 files): routes.rb"
        )
        baseline_pos = prompt.index("Repository Baseline")
        comments_pos = prompt.index("Task Comments / Agent Feedback")
        assert baseline_pos < comments_pos, "Repo baseline should appear before comments"
      end
    end
  end
end

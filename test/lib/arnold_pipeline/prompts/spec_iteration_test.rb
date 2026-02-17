require "test_helper"
require "arnold_pipeline/prompts/spec_iteration"

module ArnoldPipeline
  module Prompts
    class SpecIterationTest < ActiveSupport::TestCase
      test "system_prompt returns non-empty string" do
        prompt = SpecIteration.system_prompt
        assert_kind_of String, prompt
        refute_empty prompt
      end

      test "system_prompt includes core principles" do
        prompt = SpecIteration.system_prompt
        assert_includes prompt, "SURGICAL PRECISION"
        assert_includes prompt, "PRESERVE STRUCTURE"
        assert_includes prompt, "RIPPLE AWARENESS"
        assert_includes prompt, "RATIONALE ALWAYS"
      end

      test "system_prompt includes delta format instructions" do
        prompt = SpecIteration.system_prompt
        assert_includes prompt, "added"
        assert_includes prompt, "modified"
        assert_includes prompt, "removed"
        assert_includes prompt, "### Requirement:"
        assert_includes prompt, "#### Scenario:"
        assert_includes prompt, "GIVEN"
        assert_includes prompt, "WHEN"
        assert_includes prompt, "THEN"
      end

      test "system_prompt includes output format with summary and deltas" do
        prompt = SpecIteration.system_prompt
        assert_includes prompt, '"summary"'
        assert_includes prompt, '"deltas"'
      end

      test "system_prompt includes delta rules" do
        prompt = SpecIteration.system_prompt
        assert_includes prompt, "Delta Rules"
        assert_includes prompt, "REQ-DOMAIN-NNN"
      end

      test "user_prompt includes spec content" do
        prompt = SpecIteration.user_prompt(
          spec_content: "# My Application Spec\n## Features",
          change_request: "Add dark mode"
        )
        assert_includes prompt, "# My Application Spec"
        assert_includes prompt, "## Features"
      end

      test "user_prompt includes change request" do
        prompt = SpecIteration.user_prompt(
          spec_content: "# Spec",
          change_request: "Add user notifications with email and push"
        )
        assert_includes prompt, "Add user notifications with email and push"
      end

      test "user_prompt includes section headers" do
        prompt = SpecIteration.user_prompt(
          spec_content: "# Spec",
          change_request: "Change something"
        )
        assert_includes prompt, "# Current Specification"
        assert_includes prompt, "# Change Request"
      end
    end
  end
end

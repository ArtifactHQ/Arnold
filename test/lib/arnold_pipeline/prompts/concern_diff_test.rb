require "test_helper"
require "arnold_pipeline/prompts/concern_diff"

module ArnoldPipeline
  module Prompts
    class ConcernDiffTest < ActiveSupport::TestCase
      test "analysis_prompt includes change request" do
        prompt = ConcernDiff.analysis_prompt(
          as_built_spec: "# My App Spec\n## Purpose\nA test app",
          change_request: "Add OAuth authentication",
          concern_ids: [ "auth", "data_layer" ]
        )

        assert_includes prompt, "Add OAuth authentication"
        assert_includes prompt, "Concern Diff Analysis"
      end

      test "analysis_prompt includes all concern IDs" do
        prompt = ConcernDiff.analysis_prompt(
          as_built_spec: "# Spec",
          change_request: "Add feature",
          concern_ids: [ "auth", "data_layer", "api_layer" ]
        )

        assert_includes prompt, "auth"
        assert_includes prompt, "data_layer"
        assert_includes prompt, "api_layer"
      end

      test "analysis_prompt truncates long specs" do
        long_spec = "x" * 10_000
        prompt = ConcernDiff.analysis_prompt(
          as_built_spec: long_spec,
          change_request: "Add feature",
          concern_ids: [ "auth" ]
        )

        # Should truncate at 8000 chars
        assert prompt.length < long_spec.length + 1000
      end

      test "analysis_prompt includes delta_type options" do
        prompt = ConcernDiff.analysis_prompt(
          as_built_spec: "# Spec",
          change_request: "Add feature",
          concern_ids: [ "auth" ]
        )

        assert_includes prompt, "modify"
        assert_includes prompt, "extend"
        assert_includes prompt, "new"
      end

      test "schema is valid JSON Schema structure" do
        schema = ConcernDiff.schema

        assert_equal "concern_diff_analysis", schema[:name]
        assert schema[:strict]
        assert_equal "object", schema[:schema][:type]
        assert_includes schema[:schema][:required], "delta_concerns"
        assert_includes schema[:schema][:required], "summary"
      end
    end
  end
end

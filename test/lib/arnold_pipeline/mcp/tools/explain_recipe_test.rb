require "test_helper"
require "arnold_pipeline/mcp/context"
require "arnold_pipeline/mcp/tools/explain_recipe"

module ArnoldPipeline
  module Mcp
    module Tools
      class ExplainRecipeTest < ActiveSupport::TestCase
        cover "ArnoldPipeline::Mcp::Tools::ExplainRecipe*"

        setup do
          @context = Context.new
          @run = PipelineRun.create!(
            nl_input: "Build a web dashboard",
            metadata: {
              "library_selections" => {
                "persona" => "Software Architect",
                "recipe" => "Web App",
                "supporting_recipes" => [ "API Service" ],
                "domain_type" => "PRODUCTIVITY"
              }
            }
          )
          @spec = Specification.create!(
            pipeline_run: @run,
            content: "# Dashboard App\n\n## Features\n- Charts\n- User accounts",
            version: 1,
            structured_data: {}
          )
        end

        teardown do
          ArnoldPipeline.reset_configuration!
        end

        test "tool_name returns explain_recipe" do
          assert_equal "explain_recipe", ExplainRecipe.tool_name
        end

        test "description is present and non-empty" do
          assert_kind_of String, ExplainRecipe.description
          refute_empty ExplainRecipe.description
        end

        test "input_schema has recipe as required" do
          schema = ExplainRecipe.input_schema
          assert_equal "object", schema[:type]
          assert schema[:properties].key?(:recipe)
          assert schema[:properties].key?(:run_id)
          assert_includes schema[:required], "recipe"
        end

        test "call returns recipe details for exact match" do
          result = ExplainRecipe.call({ "recipe" => "Web App" }, @context)

          assert_equal "Web App", result[:recipe]
          assert_kind_of String, result[:purpose]
          refute_empty result[:purpose]
          assert_kind_of Array, result[:provides]
          assert result[:provides].length > 0, "Expected provides to list recipe sections"
          assert_kind_of String, result[:rationale]
          assert_kind_of Array, result[:trade_offs]
          assert_kind_of Hash, result[:configuration]
        end

        test "call matches recipe case-insensitively" do
          result = ExplainRecipe.call({ "recipe" => "web app" }, @context)
          assert_equal "Web App", result[:recipe]
        end

        test "call matches recipe by fuzzy keyword search" do
          result = ExplainRecipe.call({ "recipe" => "api backend service" }, @context)
          assert_equal "API Service", result[:recipe]
        end

        test "call returns error for unknown recipe" do
          result = ExplainRecipe.call({ "recipe" => "Quantum Computing Framework" }, @context)

          assert result[:error]
          assert_includes result[:error], "not found"
          assert_includes result[:error], "Available recipes"
        end

        test "call returns error when recipe is empty" do
          result = ExplainRecipe.call({ "recipe" => "" }, @context)
          assert_equal "recipe is required", result[:error]
        end

        test "call returns error when recipe is nil" do
          result = ExplainRecipe.call({}, @context)
          assert_equal "recipe is required", result[:error]
        end

        test "call extracts provides from recipe sections" do
          result = ExplainRecipe.call({ "recipe" => "Web App" }, @context)

          # Web App recipe has sections like "Local Development", "Models & Database", etc.
          assert result[:provides].any? { |p| p.include?("Local Development") || p.include?("Models") }
        end

        test "call extracts configuration from recipe framework" do
          result = ExplainRecipe.call({ "recipe" => "Web App" }, @context)

          assert result[:configuration].key?("primary")
          assert_includes result[:configuration]["primary"], "Rails"
        end

        test "call includes verification config" do
          result = ExplainRecipe.call({ "recipe" => "Web App" }, @context)

          # Verification commands should appear in config
          has_verification = result[:configuration].keys.any? { |k| k.start_with?("verification_") }
          assert has_verification, "Expected verification config keys"
        end

        test "call builds trade-offs comparing against other recipes" do
          result = ExplainRecipe.call({ "recipe" => "Web App" }, @context)

          assert_kind_of Array, result[:trade_offs]
          # Web App and API Service share keywords, so there should be a comparison
          assert result[:trade_offs].any? { |t| t.include?("API Service") },
                 "Expected trade-off comparison with API Service"
        end

        test "call explains rationale when recipe was selected as primary" do
          result = ExplainRecipe.call({ "recipe" => "Web App" }, @context)

          assert_includes result[:rationale], "primary recipe"
          assert_includes result[:rationale], "web dashboard"
        end

        test "call explains rationale when recipe was supporting" do
          result = ExplainRecipe.call({ "recipe" => "API Service" }, @context)

          assert_includes result[:rationale], "supporting recipe"
          assert_includes result[:rationale], "Web App"
        end

        test "call explains rationale when recipe was not selected" do
          result = ExplainRecipe.call({ "recipe" => "CLI Tool" }, @context)

          assert_includes result[:rationale], "not selected"
          assert_includes result[:rationale], "Web App"
        end

        test "call with run_id uses specific run for rationale" do
          other_run = PipelineRun.create!(
            nl_input: "Build a CLI tool",
            metadata: {
              "library_selections" => {
                "recipe" => "CLI Tool",
                "supporting_recipes" => [],
                "domain_type" => "SERVICE"
              }
            }
          )
          Specification.create!(
            pipeline_run: other_run,
            content: "# CLI Tool",
            version: 1
          )

          result = ExplainRecipe.call(
            { "recipe" => "CLI Tool", "run_id" => other_run.id.to_s },
            @context
          )

          assert_includes result[:rationale], "primary recipe"
        end

        test "call handles run with no library_selections" do
          @run.update!(metadata: {})

          result = ExplainRecipe.call({ "recipe" => "Web App" }, @context)

          assert_equal "Web App", result[:recipe]
          assert_includes result[:rationale], "not selected"
        end

        test "call handles run with nil metadata" do
          @run.update_column(:metadata, nil)

          result = ExplainRecipe.call({ "recipe" => "Web App" }, @context)

          assert_equal "Web App", result[:recipe]
          # Should not crash, still returns recipe data
          assert_kind_of String, result[:purpose]
        end

        test "call handles no pipeline run for rationale" do
          PipelineRun.destroy_all

          result = ExplainRecipe.call({ "recipe" => "Web App" }, @context)

          assert_equal "Web App", result[:recipe]
          assert_includes result[:rationale], "No pipeline run"
        end

        test "response has all expected keys with correct types" do
          result = ExplainRecipe.call({ "recipe" => "Web App" }, @context)

          assert_kind_of String, result[:recipe]
          assert_kind_of String, result[:purpose]
          assert_kind_of Array, result[:provides]
          result[:provides].each { |p| assert_kind_of String, p }
          assert_kind_of String, result[:rationale]
          assert_kind_of Array, result[:trade_offs]
          result[:trade_offs].each { |t| assert_kind_of String, t }
          assert_kind_of Hash, result[:configuration]
          result[:configuration].each do |k, v|
            assert_kind_of String, k
            assert_kind_of String, v
          end
        end

        test "call returns all available recipes in error message" do
          result = ExplainRecipe.call({ "recipe" => "nonexistent" }, @context)

          assert result[:error]
          # Should list some real recipes
          assert_includes result[:error], "Web App"
          assert_includes result[:error], "API Service"
        end

        test "provides includes post_pipeline phase annotation" do
          result = ExplainRecipe.call({ "recipe" => "Web App" }, @context)

          # Web App has a "Deployment & Infrastructure" section with phase: post_pipeline
          deployment = result[:provides].find { |p| p.include?("Deployment") }
          assert deployment, "Expected Deployment section in provides"
          assert_includes deployment, "post_pipeline"
        end
      end
    end
  end
end

require "test_helper"
require "arnold_pipeline/verification/recipe_verification_extractor"

module ArnoldPipeline
  module Verification
    class RecipeVerificationExtractorTest < ActiveSupport::TestCase
      setup do
        ArnoldPipeline.configure do |c|
          c.llm_api_key = "test"
        end

        @pipeline_run = ArnoldPipeline::PipelineRun.create!(
          nl_input: "Build a web app with dashboards",
          status: :pending
        )
      end

      teardown do
        ArnoldPipeline.reset_configuration!
      end

      test "extracts verification config from recipe matched via structured_data" do
        @pipeline_run.create_specification!(
          content: "test spec",
          version: 1,
          structured_data: { "recipe_type" => "web_app" }
        )

        result = RecipeVerificationExtractor.call(pipeline_run: @pipeline_run)

        assert_not_nil result
        assert_equal "bin/setup", result[:setup_command]
        assert_equal "bin/dev", result[:run_command]
        assert_equal({ url: "http://localhost:3000/up", expected_status: 200 }, result[:health_check])
      end

      test "extracts verification config from recipe matched via nl_input" do
        @pipeline_run.create_specification!(
          content: "test spec",
          version: 1,
          structured_data: {}
        )

        result = RecipeVerificationExtractor.call(pipeline_run: @pipeline_run)

        assert_not_nil result
        assert_equal "bin/setup", result[:setup_command]
        assert_equal "bin/dev", result[:run_command]
      end

      test "falls back to nl_input matching when no specification exists" do
        result = RecipeVerificationExtractor.call(pipeline_run: @pipeline_run)

        # nl_input "Build a web app with dashboards" matches web_app recipe
        assert_not_nil result
        assert_equal "bin/setup", result[:setup_command]
      end

      test "returns nil when recipe has empty verification block" do
        empty_recipe = ArnoldPipeline::Library::Recipe.new(
          name: "Empty", type: "empty", keywords: [], description: "",
          framework: {}, sections: [], verification: {}
        )
        manager = stub("manager")
        manager.stubs(:all_recipes).returns([empty_recipe])

        @pipeline_run.create_specification!(
          content: "test spec",
          version: 1,
          structured_data: { "recipe_type" => "empty" }
        )

        result = RecipeVerificationExtractor.call(
          pipeline_run: @pipeline_run,
          library_manager: manager
        )

        assert_nil result
      end

      test "normalizes health_check string to hash" do
        recipe = ArnoldPipeline::Library::Recipe.new(
          name: "Test", type: "test_recipe", keywords: [], description: "",
          framework: {}, sections: [],
          verification: {
            "setup_command" => "bin/setup",
            "health_check" => "http://localhost:4000/health"
          }
        )
        manager = stub("manager")
        manager.stubs(:all_recipes).returns([recipe])

        @pipeline_run.create_specification!(
          content: "test spec",
          version: 1,
          structured_data: { "recipe_type" => "test_recipe" }
        )

        result = RecipeVerificationExtractor.call(
          pipeline_run: @pipeline_run,
          library_manager: manager
        )

        assert_equal({ url: "http://localhost:4000/health", expected_status: 200 }, result[:health_check])
      end

      test "normalizes health_check hash with custom expected_status" do
        recipe = ArnoldPipeline::Library::Recipe.new(
          name: "Test", type: "test_recipe", keywords: [], description: "",
          framework: {}, sections: [],
          verification: {
            "health_check" => { "url" => "http://localhost:3000/up", "expected_status" => 204 }
          }
        )
        manager = stub("manager")
        manager.stubs(:all_recipes).returns([recipe])

        @pipeline_run.create_specification!(
          content: "test spec",
          version: 1,
          structured_data: { "recipe_type" => "test_recipe" }
        )

        result = RecipeVerificationExtractor.call(
          pipeline_run: @pipeline_run,
          library_manager: manager
        )

        assert_equal({ url: "http://localhost:3000/up", expected_status: 204 }, result[:health_check])
      end

      test "omits nil values from result" do
        recipe = ArnoldPipeline::Library::Recipe.new(
          name: "Minimal", type: "minimal", keywords: [], description: "",
          framework: {}, sections: [],
          verification: { "setup_command" => "bin/setup" }
        )
        manager = stub("manager")
        manager.stubs(:all_recipes).returns([recipe])

        @pipeline_run.create_specification!(
          content: "test spec",
          version: 1,
          structured_data: { "recipe_type" => "minimal" }
        )

        result = RecipeVerificationExtractor.call(
          pipeline_run: @pipeline_run,
          library_manager: manager
        )

        assert_equal({ setup_command: "bin/setup" }, result)
        refute result.key?(:run_command)
        refute result.key?(:health_check)
        refute result.key?(:test_command)
        refute result.key?(:cleanup_command)
      end

      test "falls back to nl_input matching when recipe_type not in structured_data" do
        @pipeline_run.create_specification!(
          content: "test spec",
          version: 1,
          structured_data: { "some_other_key" => "value" }
        )

        result = RecipeVerificationExtractor.call(pipeline_run: @pipeline_run)

        # nl_input "Build a web app with dashboards" should match web_app recipe
        assert_not_nil result
        assert_equal "bin/setup", result[:setup_command]
      end

      test "accepts custom library_manager" do
        recipe = ArnoldPipeline::Library::Recipe.new(
          name: "Custom", type: "custom", keywords: ["custom"], description: "",
          framework: {}, sections: [],
          verification: { "setup_command" => "custom_setup.sh", "run_command" => "custom_run.sh" }
        )
        manager = stub("manager")
        manager.stubs(:all_recipes).returns([recipe])

        @pipeline_run.create_specification!(
          content: "test spec",
          version: 1,
          structured_data: { "recipe_type" => "custom" }
        )

        result = RecipeVerificationExtractor.call(
          pipeline_run: @pipeline_run,
          library_manager: manager
        )

        assert_equal "custom_setup.sh", result[:setup_command]
        assert_equal "custom_run.sh", result[:run_command]
      end
    end
  end
end

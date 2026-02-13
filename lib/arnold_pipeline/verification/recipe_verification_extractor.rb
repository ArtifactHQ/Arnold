require "arnold_pipeline/library/manager"

module ArnoldPipeline
  module Verification
    class RecipeVerificationExtractor
      def self.call(pipeline_run:, library_manager: nil)
        new(pipeline_run:, library_manager:).call
      end

      def initialize(pipeline_run:, library_manager: nil)
        @pipeline_run = pipeline_run
        @library_manager = library_manager || ArnoldPipeline::Library::Manager.new(
          library_path: ArnoldPipeline.configuration.library_path
        )
      end

      def call
        recipe = resolve_recipe
        return nil unless recipe

        verification = recipe.verification
        return nil if verification.nil? || verification.empty?

        normalize(verification)
      end

      private

      def resolve_recipe
        structured_data = @pipeline_run.specification&.structured_data || {}
        recipe_type = structured_data["recipe_type"]

        if recipe_type
          @library_manager.all_recipes.find { |r| r.type == recipe_type }
        else
          @library_manager.find_recipe(@pipeline_run.nl_input)
        end
      end

      def normalize(verification)
        health_check = normalize_health_check(verification["health_check"])

        {
          setup_command: verification["setup_command"],
          run_command: verification["run_command"],
          health_check: health_check,
          test_command: verification["test_command"],
          cleanup_command: verification["cleanup_command"]
        }.compact
      end

      def normalize_health_check(value)
        case value
        when String
          { url: value, expected_status: 200 }
        when Hash
          {
            url: value["url"],
            expected_status: value["expected_status"] || 200
          }
        end
      end
    end
  end
end

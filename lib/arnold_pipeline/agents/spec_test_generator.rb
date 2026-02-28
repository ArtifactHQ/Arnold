require_relative "base_agent"
require "arnold_pipeline/prompts/spec_test_generation"
require "arnold_pipeline/library/manager"

module ArnoldPipeline
  module Agents
    class SpecTestGenerator < BaseAgent
      RESPONSE_SCHEMA = {
        name: "spec_test_generation_result",
        schema: {
          type: "object", additionalProperties: false,
          required: [ "test_files" ],
          properties: {
            test_files: {
              type: "array",
              items: {
                type: "object", additionalProperties: false,
                required: [ "path", "content", "requirement_ids" ],
                properties: {
                  path: { type: "string" },
                  content: { type: "string" },
                  requirement_ids: { type: "array", items: { type: "string" } }
                }
              }
            }
          }
        }
      }.freeze

      def call(spec_content:, recipe: nil, test_directory: nil)
        test_directory ||= ArnoldPipeline.configuration.spec_test_directory
        persona = load_persona

        logger.info { "Generating spec-scenario tests for #{test_directory}/" }

        system = Prompts::SpecTestGeneration.system_prompt(persona:, recipe:)
        user = Prompts::SpecTestGeneration.user_prompt(spec_content:, test_directory:)

        result = chat_json(
          messages: [ { role: :user, content: user } ],
          system: system,
          schema: RESPONSE_SCHEMA
        )

        validate_result!(result)
        result
      end

      private

      def load_persona
        persona_key = ArnoldPipeline.configuration.spec_test_persona
        manager = ArnoldPipeline::Library::Manager.new(
          library_path: ArnoldPipeline.configuration.library_path
        )
        manager.all_personas.find { |p| p.name.downcase.tr(" ", "_") == persona_key } ||
          manager.find_persona("testing integration scenario")
      end

      def validate_result!(result)
        raise Error, "Expected hash result, got #{result.class}" unless result.is_a?(Hash)

        test_files = result["test_files"]
        raise Error, "test_files must be an array" unless test_files.is_a?(Array)

        test_files.each_with_index do |file, i|
          raise Error, "test_files[#{i}] must be a hash" unless file.is_a?(Hash)
          raise Error, "test_files[#{i}] must have a path" unless file["path"].is_a?(String) && !file["path"].strip.empty?
          raise Error, "test_files[#{i}] must have content" unless file["content"].is_a?(String) && !file["content"].strip.empty?
        end
      end
    end
  end
end

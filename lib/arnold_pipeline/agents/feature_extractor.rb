require "arnold_pipeline/agents/base_agent"
require "arnold_pipeline/prompts/feature_extraction"

module ArnoldPipeline
  module Agents
    class FeatureExtractor < BaseAgent
      MAX_FILE_READ = 8_192

      def call(recipe_alignment:, artifacts:, stack_fingerprint:, change_surface: nil, reference_materials: [])
        @token_budget = ArnoldPipeline.configuration.brownfield_scan_budget
        @tokens_used = 0
        deep_dive_filter = ArnoldPipeline.configuration.brownfield_deep_dive_domains

        concerns = recipe_alignment["concerns"] || {}
        inventories = []

        concerns.each do |concern_id, concern_data|
          next if concern_data["status"] == "absent"
          next if deep_dive_filter && !deep_dive_filter.include?(concern_id)
          break unless budget_remaining?

          files = resolve_implementation_files(concern_data, artifacts)
          next if files.empty?

          inventory = extract_features(
            concern_id:,
            concern_name: concern_id.tr("_", " ").capitalize,
            files:,
            stack_fingerprint:,
            change_surface:,
            reference_materials:
          )

          inventories << inventory if inventory
        end

        inventories
      end

      private

      def extract_features(concern_id:, concern_name:, files:, stack_fingerprint:, change_surface:, reference_materials: [])
        change_request = change_surface&.dig("summary")

        prompt = if change_request
          Prompts::FeatureExtraction.scoped_extraction_prompt(
            concern_id:, concern_name:,
            implementation_files: files,
            stack_fingerprint:,
            change_request:,
            reference_materials:
          )
        else
          Prompts::FeatureExtraction.extraction_prompt(
            concern_id:, concern_name:,
            implementation_files: files,
            stack_fingerprint:,
            reference_materials:
          )
        end

        response = chat(messages: [{ role: "user", content: prompt }])
        track_tokens(prompt, response)
        parse_json(response)
      end

      def resolve_implementation_files(concern_data, artifacts)
        file_paths = concern_data["files"] || []
        result = {}

        file_paths.each do |path|
          # Try to find content from artifacts first
          artifact = artifacts.find { |a| a[:path] == path }
          if artifact && artifact[:content]
            result[path] = artifact[:content]
            next
          end

          # Try reading from repo
          repo_path = ArnoldPipeline.configuration.target_repo_path ||
                      ArnoldPipeline.configuration.claude_code_repo_path
          next unless repo_path

          full_path = File.join(repo_path, path)
          if File.exist?(full_path)
            begin
              content = File.read(full_path, encoding: "utf-8")
              result[path] = content.length > MAX_FILE_READ ? content[0, MAX_FILE_READ] : content
            rescue
              nil
            end
          end
        end

        result
      end

      def track_tokens(prompt, response)
        prompt_tokens = prompt.to_s.length / 4
        response_tokens = response.to_s.length / 4
        @tokens_used += prompt_tokens + response_tokens
      end

      def budget_remaining?
        @tokens_used < @token_budget
      end
    end
  end
end

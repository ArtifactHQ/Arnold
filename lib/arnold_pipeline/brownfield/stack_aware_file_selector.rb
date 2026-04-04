require "yaml"

module ArnoldPipeline
  module Brownfield
    module StackAwareFileSelector
      PATTERNS_PATH = File.join(__dir__, "data", "agent_file_patterns.yml")
      FAMILIES_PATH = File.join(__dir__, "data", "stack_families.yml")

      # Returns an array of matching file paths for the given stack and agent,
      # or nil if no patterns are defined for this stack (callers should fall
      # back to their hardcoded defaults).
      def self.select_files(context, agent_name)
        stack_key = resolve_stack_key(context)
        agent_config = patterns_for(stack_key, agent_name.to_s)
        return nil unless agent_config

        include_patterns = agent_config["patterns"] || []
        exclude_patterns = agent_config["excluded"] || []
        return nil if include_patterns.empty?

        manifest = context.file_manifest || {}
        manifest.keys.select do |path|
          matches_any?(path, include_patterns) && !matches_any?(path, exclude_patterns)
        end
      end

      def self.resolve_stack_key(context)
        fingerprint = context.stack_fingerprint
        return nil unless fingerprint

        framework = fingerprint[:framework]&.to_s
        return framework unless framework.nil? || framework.empty?

        fingerprint[:language]&.to_s
      end

      def self.patterns_for(stack_key, agent_name)
        return nil unless stack_key

        data = load_patterns_data
        data.dig("stacks", stack_key, agent_name)
      end

      def self.matches_any?(path, patterns)
        patterns.any? { |pattern| glob_match?(pattern, path) }
      end

      def self.glob_match?(pattern, path)
        s = pattern.gsub(".", "\\.")
        s = s.gsub("**/", "\x01").gsub("**", "\x02")
        s = s.gsub("*", "[^/]*")
        s = s.gsub("\x01", "(.*/)?").gsub("\x02", ".*")
        Regexp.new("\\A#{s}\\z").match?(path)
      end

      # Returns the stack family for the given context: "server_monolith",
      # "client_spa", "mobile", "systems", or nil if unknown.
      def self.stack_family(context)
        stack_key = resolve_stack_key(context)
        return nil unless stack_key

        families = load_families_data["families"] || {}
        families.each do |family_name, stacks|
          return family_name if Array(stacks).include?(stack_key)
        end
        nil
      end

      def self.load_patterns_data
        @patterns_data ||= YAML.load_file(PATTERNS_PATH)
      end

      def self.load_families_data
        @families_data ||= YAML.load_file(FAMILIES_PATH)
      end

      # Allow tests to reset cached data
      def self.reset! # mutant:disable
        @patterns_data = nil
        @families_data = nil
      end
    end
  end
end

require "yaml"

module ArnoldPipeline
  module Brownfield
    class ArtifactDiscoverer
      MAPS_PATH = File.expand_path("data/artifact_maps.yml", __dir__)
      MAX_CONTENT_SIZE = 10_240 # 10KB

      ROLES = %w[schema routes components dependency_manifest entry_point orm_config ci_config].freeze

      def self.call(repo_path:, stack_fingerprint:, additional_maps_path: nil)
        new(repo_path:, stack_fingerprint:, additional_maps_path:).call
      end

      def initialize(repo_path:, stack_fingerprint:, additional_maps_path: nil)
        @repo_path = repo_path
        @stack_fingerprint = stack_fingerprint
        @additional_maps_path = additional_maps_path
      end

      def call
        maps = load_maps
        stack_key = detect_stack_key(maps)
        return default_artifacts unless stack_key

        stack_map = maps[stack_key]
        artifacts = []

        ROLES.each do |role|
          entries = stack_map[role]

          if entries.is_a?(Array)
            resolved = resolve_entries(entries)
            if resolved.any?
              artifacts.concat(resolved.map { |r| r.merge(role:) })
            else
              artifacts << { role:, path: nil, content: nil, format: nil }
            end
          elsif entries.is_a?(String)
            # boot_command / test_command — not file artifacts
            next
          else
            artifacts << { role:, path: nil, content: nil, format: nil }
          end
        end

        artifacts
      end

      private

      def load_maps
        maps = YAML.safe_load_file(MAPS_PATH)["stacks"]

        if @additional_maps_path && File.exist?(@additional_maps_path)
          additional = YAML.safe_load_file(@additional_maps_path)["stacks"] || {}
          maps.merge!(additional)
        end

        maps
      end

      def detect_stack_key(maps)
        language = @stack_fingerprint[:language] || @stack_fingerprint["language"]
        framework = @stack_fingerprint[:framework] || @stack_fingerprint["framework"]

        # Try language_framework first, then language alone
        key = "#{language}_#{framework}" if framework
        return key if key && maps[key]

        maps.keys.find { |k| k.start_with?(language.to_s) }
      end

      def resolve_entries(entries)
        results = []

        entries.each do |entry|
          path_pattern = entry["path"]
          format = entry["format"]

          matches = Dir.glob(File.join(@repo_path, path_pattern))
          matches.each do |full_path|
            next unless File.file?(full_path)

            relative = full_path.sub("#{@repo_path}/", "")
            content = read_truncated(full_path)
            results << { path: relative, content:, format: }
          end
        end

        results
      end

      def read_truncated(path)
        content = File.read(path, encoding: "utf-8")
        if content.length > MAX_CONTENT_SIZE
          content[0, MAX_CONTENT_SIZE] + "\n...[truncated at #{MAX_CONTENT_SIZE} bytes]..."
        else
          content
        end
      rescue => e
        "[read error: #{e.message}]"
      end

      def default_artifacts
        ROLES.map { |role| { role:, path: nil, content: nil, format: nil } }
      end
    end
  end
end

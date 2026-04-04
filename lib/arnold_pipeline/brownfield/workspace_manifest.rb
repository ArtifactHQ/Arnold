require "yaml"

module ArnoldPipeline
  module Brownfield
    class WorkspaceManifest
      Root = Data.define(:name, :path, :hint)

      attr_reader :project_name, :roots

      def self.load(manifest_path)
        manifest_path = File.expand_path(manifest_path)
        unless File.exist?(manifest_path)
          raise ArgumentError, "Workspace manifest not found: #{manifest_path}"
        end

        data = YAML.safe_load_file(manifest_path)
        base_dir = File.dirname(manifest_path)
        new(data, base_dir:)
      end

      def initialize(data, base_dir: Dir.pwd)
        raise ArgumentError, "workspace manifest must be a Hash" unless data.is_a?(Hash)
        raise ArgumentError, "workspace manifest requires a 'project' key" unless data.key?("project")
        raise ArgumentError, "workspace manifest requires a 'roots' array" unless data["roots"].is_a?(Array)

        @project_name = data.fetch("project").to_s
        @roots = data.fetch("roots").map do |r|
          raise ArgumentError, "each root requires a 'path' key" unless r.is_a?(Hash) && r.key?("path")

          resolved_path = File.expand_path(r.fetch("path"), base_dir)
          Root.new(
            name: (r["name"] || File.basename(resolved_path)).to_s,
            path: resolved_path,
            hint: r["hint"]&.to_s
          )
        end

        validate!
      end

      def stack_overrides_for(root)
        return {} unless root.hint

        { framework: root.hint }
      end

      private

      def validate!
        raise ArgumentError, "workspace must have at least one root" if @roots.empty?

        names = @roots.map(&:name)
        dupes = names.tally.select { |_, v| v > 1 }.keys
        raise ArgumentError, "duplicate root names: #{dupes.join(', ')}" if dupes.any?
      end
    end
  end
end

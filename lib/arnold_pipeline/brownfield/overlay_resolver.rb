require "yaml"

module ArnoldPipeline
  module Brownfield
    class OverlayResolver
      OVERLAYS_PATH = File.expand_path("data/framework_overlays.yml", __dir__)

      def self.call(stack_fingerprint:, additional_path: nil)
        new(stack_fingerprint:, additional_path:).call
      end

      def initialize(stack_fingerprint:, additional_path: nil)
        @stack_fingerprint = stack_fingerprint
        @additional_path = additional_path
      end

      def call
        overlays = load_overlays
        stack_key = detect_stack_key(overlays)
        return {} unless stack_key

        overlays[stack_key] || {}
      end

      private

      def load_overlays
        builtin = YAML.safe_load_file(OVERLAYS_PATH)["stacks"]

        if @additional_path && File.exist?(@additional_path)
          user = YAML.safe_load_file(@additional_path)["stacks"] || {}
          deep_merge(builtin, user)
        else
          builtin
        end
      end

      def detect_stack_key(overlays)
        language = @stack_fingerprint[:language] || @stack_fingerprint["language"]
        framework = @stack_fingerprint[:framework] || @stack_fingerprint["framework"]

        key = "#{language}_#{framework}" if framework
        return key if key && overlays[key]

        overlays.keys.find { |k| k.start_with?(language.to_s) }
      end

      def deep_merge(base, override)
        base.merge(override) do |_key, old_val, new_val|
          if old_val.is_a?(Hash) && new_val.is_a?(Hash)
            deep_merge(old_val, new_val)
          else
            new_val
          end
        end
      end
    end
  end
end

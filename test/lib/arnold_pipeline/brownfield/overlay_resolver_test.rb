require "test_helper"
require "arnold_pipeline/brownfield/overlay_resolver"
require "tmpdir"

module ArnoldPipeline
  module Brownfield
    class OverlayResolverTest < ActiveSupport::TestCase
      test "returns overlay for Ruby/Rails stack" do
        fingerprint = { language: "ruby", framework: "rails" }
        overlay = OverlayResolver.call(stack_fingerprint: fingerprint)

        assert overlay.is_a?(Hash)
        assert overlay.key?("auth")
        assert overlay.key?("data_layer")
        assert overlay["auth"]["typical_implementations"].is_a?(Array)
        assert overlay["auth"]["expected_locations"].is_a?(Array)
      end

      test "returns overlay for TypeScript/Next.js stack" do
        fingerprint = { language: "typescript", framework: "nextjs" }
        overlay = OverlayResolver.call(stack_fingerprint: fingerprint)

        assert overlay.is_a?(Hash)
        assert overlay.key?("auth")
        assert_includes overlay["auth"]["typical_implementations"].join, "NextAuth"
      end

      test "returns empty hash for unknown stack" do
        fingerprint = { language: "unknown", framework: nil }
        overlay = OverlayResolver.call(stack_fingerprint: fingerprint)

        assert_equal({}, overlay)
      end

      test "deep merges user overlays over built-in" do
        Dir.mktmpdir do |dir|
          user_overlays = {
            "stacks" => {
              "ruby_rails" => {
                "auth" => {
                  "typical_implementations" => ["Custom JWT"],
                  "custom_field" => "user_value"
                }
              }
            }
          }
          path = File.join(dir, "overlays.yml")
          File.write(path, YAML.dump(user_overlays))

          fingerprint = { language: "ruby", framework: "rails" }
          overlay = OverlayResolver.call(stack_fingerprint: fingerprint, additional_path: path)

          # User's auth implementations should replace built-in
          assert_equal ["Custom JWT"], overlay["auth"]["typical_implementations"]
          # User's custom field should be present
          assert_equal "user_value", overlay["auth"]["custom_field"]
          # Other concerns from built-in should still be present
          assert overlay.key?("data_layer")
        end
      end

      test "handles string keys in fingerprint" do
        fingerprint = { "language" => "ruby", "framework" => "rails" }
        overlay = OverlayResolver.call(stack_fingerprint: fingerprint)

        assert overlay.key?("auth")
      end
    end
  end
end

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
                  "typical_implementations" => [ "Custom JWT" ],
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
          assert_equal [ "Custom JWT" ], overlay["auth"]["typical_implementations"]
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

      test "returns behavioral_files key for each concern" do
        fingerprint = { language: "ruby", framework: "rails" }
        overlay = OverlayResolver.call(stack_fingerprint: fingerprint)

        %w[auth data_layer api_layer background_jobs realtime testing frontend deployment].each do |concern|
          assert overlay[concern].key?("behavioral_files"),
            "Expected #{concern} overlay to have behavioral_files key"
          assert overlay[concern]["behavioral_files"].is_a?(Array),
            "Expected #{concern} behavioral_files to be an Array"
          assert overlay[concern]["behavioral_files"].any?,
            "Expected #{concern} behavioral_files to not be empty"
        end
      end

      test "all stacks have behavioral_files for all concerns" do
        %w[ruby_rails typescript_nextjs java_spring_boot python_django rust csharp_aspnet].each do |stack_key|
          parts = stack_key.split("_", 2)
          fingerprint = { language: parts[0], framework: parts[1] || parts[0] }
          overlay = OverlayResolver.call(stack_fingerprint: fingerprint)

          next if overlay.empty? # Unknown stack mapping

          overlay.each do |concern_id, concern_data|
            assert concern_data.key?("behavioral_files"),
              "Expected #{stack_key}/#{concern_id} to have behavioral_files"
          end
        end
      end
    end
  end
end

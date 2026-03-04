require "test_helper"
require "arnold_pipeline/brownfield/artifact_discoverer"
require "tmpdir"

module ArnoldPipeline
  module Brownfield
    class ArtifactDiscovererTest < ActiveSupport::TestCase
      test "discovers artifacts for a Rails project" do
        Dir.mktmpdir do |dir|
          # Create Rails-like artifacts
          FileUtils.mkdir_p(File.join(dir, "config"))
          FileUtils.mkdir_p(File.join(dir, "db/migrate"))
          File.write(File.join(dir, "db/schema.rb"), "ActiveRecord::Schema.define {}")
          File.write(File.join(dir, "config/routes.rb"), "Rails.application.routes.draw {}")
          File.write(File.join(dir, "Gemfile"), "gem 'rails'")
          File.write(File.join(dir, "Gemfile.lock"), "GEM\n  specs:\n    rails (8.0)")
          File.write(File.join(dir, "config/application.rb"), "module MyApp; end")
          File.write(File.join(dir, "config/database.yml"), "development:\n  adapter: sqlite3")

          fingerprint = { language: "ruby", framework: "rails" }
          artifacts = ArtifactDiscoverer.call(repo_path: dir, stack_fingerprint: fingerprint)

          roles = artifacts.map { |a| a[:role] }.uniq
          assert_includes roles, "schema"
          assert_includes roles, "routes"
          assert_includes roles, "dependency_manifest"
          assert_includes roles, "entry_point"
          assert_includes roles, "orm_config"

          schema = artifacts.find { |a| a[:role] == "schema" && a[:path] }
          assert_equal "db/schema.rb", schema[:path]
          assert_includes schema[:content], "ActiveRecord::Schema"
        end
      end

      test "returns nil artifacts for missing roles" do
        Dir.mktmpdir do |dir|
          fingerprint = { language: "ruby", framework: "rails" }
          artifacts = ArtifactDiscoverer.call(repo_path: dir, stack_fingerprint: fingerprint)

          # All roles should be present, but with nil path/content for missing files
          nil_artifacts = artifacts.select { |a| a[:path].nil? }
          assert nil_artifacts.any?, "Should have nil artifacts for missing files"
        end
      end

      test "truncates large files" do
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, "config"))
          File.write(File.join(dir, "Gemfile"), "x" * 20_000)

          fingerprint = { language: "ruby", framework: "rails" }
          artifacts = ArtifactDiscoverer.call(repo_path: dir, stack_fingerprint: fingerprint)

          manifest = artifacts.find { |a| a[:role] == "dependency_manifest" && a[:path] == "Gemfile" }
          assert manifest
          assert manifest[:content].length <= 10_300 # 10KB + truncation message
        end
      end

      test "returns default artifacts for unknown stack" do
        Dir.mktmpdir do |dir|
          fingerprint = { language: "unknown", framework: nil }
          artifacts = ArtifactDiscoverer.call(repo_path: dir, stack_fingerprint: fingerprint)

          assert artifacts.all? { |a| a[:path].nil? }
        end
      end

      test "discovers artifacts for TypeScript/Next.js project" do
        Dir.mktmpdir do |dir|
          File.write(File.join(dir, "package.json"), '{"name": "myapp", "dependencies": {"next": "14.0"}}')
          File.write(File.join(dir, "next.config.js"), "module.exports = {}")
          File.write(File.join(dir, "tsconfig.json"), "{}")

          fingerprint = { language: "typescript", framework: "nextjs" }
          artifacts = ArtifactDiscoverer.call(repo_path: dir, stack_fingerprint: fingerprint)

          manifest = artifacts.find { |a| a[:role] == "dependency_manifest" && a[:path] == "package.json" }
          assert manifest
          assert_includes manifest[:content], "myapp"
        end
      end
    end
  end
end

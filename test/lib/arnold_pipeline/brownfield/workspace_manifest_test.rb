require "test_helper"
require "arnold_pipeline/brownfield/workspace_manifest"
require "tmpdir"
require "yaml"

module ArnoldPipeline
  module Brownfield
    class WorkspaceManifestTest < ActiveSupport::TestCase
      test "loads valid manifest from file" do
        Dir.mktmpdir do |dir|
          backend = File.join(dir, "backend")
          frontend = File.join(dir, "frontend")
          Dir.mkdir(backend)
          Dir.mkdir(frontend)

          manifest_path = File.join(dir, "workspace.yml")
          File.write(manifest_path, YAML.dump({
            "project" => "MyApp",
            "roots" => [
              { "path" => "./backend", "hint" => "rails" },
              { "path" => "./frontend", "hint" => "react", "name" => "web" }
            ]
          }))

          manifest = WorkspaceManifest.load(manifest_path)

          assert_equal "MyApp", manifest.project_name
          assert_equal 2, manifest.roots.size

          assert_equal "backend", manifest.roots[0].name
          assert_equal backend, manifest.roots[0].path
          assert_equal "rails", manifest.roots[0].hint

          assert_equal "web", manifest.roots[1].name
          assert_equal frontend, manifest.roots[1].path
          assert_equal "react", manifest.roots[1].hint
        end
      end

      test "name defaults to directory basename" do
        manifest = WorkspaceManifest.new({
          "project" => "Test",
          "roots" => [{ "path" => "/tmp/my-api" }]
        })

        assert_equal "my-api", manifest.roots[0].name
      end

      test "hint is optional and defaults to nil" do
        manifest = WorkspaceManifest.new({
          "project" => "Test",
          "roots" => [{ "path" => "/tmp/app" }]
        })

        assert_nil manifest.roots[0].hint
      end

      test "raises on missing project key" do
        error = assert_raises(ArgumentError) do
          WorkspaceManifest.new({ "roots" => [{ "path" => "/tmp/app" }] })
        end
        assert_match(/project/, error.message)
      end

      test "raises on missing roots key" do
        error = assert_raises(ArgumentError) do
          WorkspaceManifest.new({ "project" => "Test" })
        end
        assert_match(/roots/, error.message)
      end

      test "raises on empty roots array" do
        error = assert_raises(ArgumentError) do
          WorkspaceManifest.new({ "project" => "Test", "roots" => [] })
        end
        assert_match(/at least one root/, error.message)
      end

      test "raises on duplicate root names" do
        error = assert_raises(ArgumentError) do
          WorkspaceManifest.new({
            "project" => "Test",
            "roots" => [
              { "path" => "/tmp/a", "name" => "api" },
              { "path" => "/tmp/b", "name" => "api" }
            ]
          })
        end
        assert_match(/duplicate/, error.message)
      end

      test "raises on root missing path" do
        error = assert_raises(ArgumentError) do
          WorkspaceManifest.new({
            "project" => "Test",
            "roots" => [{ "name" => "oops" }]
          })
        end
        assert_match(/path/, error.message)
      end

      test "raises when manifest is not a Hash" do
        error = assert_raises(ArgumentError) do
          WorkspaceManifest.new("not a hash")
        end
        assert_match(/must be a Hash/, error.message)
      end

      test "load raises on missing file" do
        error = assert_raises(ArgumentError) do
          WorkspaceManifest.load("/nonexistent/workspace.yml")
        end
        assert_match(/not found/, error.message)
      end

      test "resolves paths relative to manifest directory" do
        Dir.mktmpdir do |dir|
          sub = File.join(dir, "sub")
          Dir.mkdir(sub)

          manifest_path = File.join(dir, "workspace.yml")
          File.write(manifest_path, YAML.dump({
            "project" => "Test",
            "roots" => [{ "path" => "./sub" }]
          }))

          manifest = WorkspaceManifest.load(manifest_path)
          assert_equal sub, manifest.roots[0].path
        end
      end

      test "stack_overrides_for returns framework hint" do
        manifest = WorkspaceManifest.new({
          "project" => "Test",
          "roots" => [
            { "path" => "/tmp/api", "hint" => "rails" },
            { "path" => "/tmp/web" }
          ]
        })

        assert_equal({ framework: "rails" }, manifest.stack_overrides_for(manifest.roots[0]))
        assert_equal({}, manifest.stack_overrides_for(manifest.roots[1]))
      end

      test "Root is a Data value object" do
        root = WorkspaceManifest::Root.new(name: "api", path: "/tmp/api", hint: "rails")

        assert_equal "api", root.name
        assert_equal "/tmp/api", root.path
        assert_equal "rails", root.hint
        assert root.frozen?
      end
    end
  end
end

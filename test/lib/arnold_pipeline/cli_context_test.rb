require "test_helper"
require "arnold_pipeline/cli"
require "yaml"

module ArnoldPipeline
  class CliContextTest < ActiveSupport::TestCase
    test "context command requires valid directory" do
      assert_raises(SystemExit) do
        capture_output_and_errors { Cli.start([ "context", "/nonexistent/path/foo" ]) }
      end
    end

    test "context with no path and no workspace exits with error" do
      assert_raises(SystemExit) do
        capture_output_and_errors { Cli.start([ "context" ]) }
      end
    end

    test "context single path outputs JSON with stack, artifacts, and file_summary" do
      Dir.mktmpdir do |dir|
        # Create a minimal Rails-like structure
        FileUtils.mkdir_p(File.join(dir, "app/models"))
        FileUtils.mkdir_p(File.join(dir, "app/controllers"))
        FileUtils.mkdir_p(File.join(dir, "config"))
        FileUtils.mkdir_p(File.join(dir, "db/migrate"))
        File.write(File.join(dir, "Gemfile"), 'gem "rails"')
        File.write(File.join(dir, "config/routes.rb"), "Rails.application.routes.draw { }")
        File.write(File.join(dir, "config/application.rb"), "module App; end")
        File.write(File.join(dir, "app/models/user.rb"), "class User; end")
        File.write(File.join(dir, "db/migrate/001_create_users.rb"), "class CreateUsers; end")

        output = capture_output { Cli.start([ "context", dir ]) }
        result = JSON.parse(output)

        assert_equal File.basename(dir), result["name"]
        assert_equal dir, result["path"]

        # Stack detection
        assert_equal "ruby", result["stack"]["language"]
        assert_equal "rails", result["stack"]["framework"]
        assert result["stack"]["confidence"] > 0

        # Artifacts discovered
        assert_instance_of Array, result["artifacts"]
        roles = result["artifacts"].map { |a| a["role"] }.uniq
        assert_includes roles, "routes"

        # File summary
        assert result["file_summary"]["total_files"] > 0
        assert result["file_summary"]["by_extension"].key?(".rb")
      end
    end

    test "context with --hint overlays framework on auto-detected stack" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "package.json"), '{"name": "app"}')
        FileUtils.mkdir_p(File.join(dir, "src"))
        File.write(File.join(dir, "src/App.jsx"), "export default function App() {}")

        output = capture_output { Cli.start([ "context", dir, "--hint", "react" ]) }
        result = JSON.parse(output)

        assert_equal "react", result["stack"]["framework"]
        assert_includes result["stack"]["signals_matched"], "hint_override:react"
      end
    end

    test "context --workspace outputs project with multiple roots" do
      Dir.mktmpdir do |dir|
        backend = File.join(dir, "backend")
        frontend = File.join(dir, "frontend")
        FileUtils.mkdir_p(File.join(backend, "app/models"))
        FileUtils.mkdir_p(File.join(backend, "config"))
        File.write(File.join(backend, "Gemfile"), 'gem "rails"')
        File.write(File.join(backend, "config/application.rb"), "module App; end")
        FileUtils.mkdir_p(File.join(frontend, "src"))
        File.write(File.join(frontend, "package.json"), '{"name": "web"}')
        File.write(File.join(frontend, "src/index.js"), "console.log('hi')")

        manifest_path = File.join(dir, "workspace.yml")
        File.write(manifest_path, YAML.dump({
          "project" => "TestApp",
          "roots" => [
            { "path" => "./backend", "name" => "api", "hint" => "rails" },
            { "path" => "./frontend", "name" => "web", "hint" => "react" }
          ]
        }))

        output = capture_output { Cli.start([ "context", "--workspace", manifest_path ]) }
        result = JSON.parse(output)

        assert_equal "TestApp", result["project"]
        assert_equal 2, result["roots"].size

        api_root = result["roots"].find { |r| r["name"] == "api" }
        web_root = result["roots"].find { |r| r["name"] == "web" }

        assert_equal "rails", api_root["stack"]["framework"]
        assert_equal "react", web_root["stack"]["framework"]
        assert api_root["file_summary"]["total_files"] > 0
        assert web_root["file_summary"]["total_files"] > 0
      end
    end

    test "context --workspace with missing root directory exits with error" do
      Dir.mktmpdir do |dir|
        manifest_path = File.join(dir, "workspace.yml")
        File.write(manifest_path, YAML.dump({
          "project" => "Bad",
          "roots" => [{ "path" => "./nope" }]
        }))

        assert_raises(SystemExit) do
          capture_output_and_errors do
            Cli.start([ "context", "--workspace", manifest_path ])
          end
        end
      end
    end

    test "context file_summary skips node_modules and .git" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "node_modules/lodash"))
        File.write(File.join(dir, "node_modules/lodash/index.js"), "module.exports = {}")
        FileUtils.mkdir_p(File.join(dir, ".git/objects"))
        File.write(File.join(dir, ".git/objects/abc"), "blob")
        File.write(File.join(dir, "index.js"), "console.log('app')")

        output = capture_output { Cli.start([ "context", dir ]) }
        result = JSON.parse(output)

        # Only index.js should be counted, not node_modules or .git contents
        assert_equal 1, result["file_summary"]["total_files"]
      end
    end

    private

    def capture_output_and_errors(&block)
      out = StringIO.new
      err = StringIO.new
      $stdout = out
      $stderr = err
      yield
      out.string + err.string
    ensure
      $stdout = STDOUT
      $stderr = STDERR
    end

    def capture_output(&block)
      out = StringIO.new
      $stdout = out
      yield
      out.string
    ensure
      $stdout = STDOUT
    end
  end
end

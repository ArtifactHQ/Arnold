require "test_helper"
require "arnold_pipeline/brownfield/stack_detector"
require "tmpdir"

module ArnoldPipeline
  module Brownfield
    class StackDetectorTest < ActiveSupport::TestCase
      test "detects a Rails project" do
        Dir.mktmpdir do |dir|
          # Create Rails-like structure
          FileUtils.mkdir_p(File.join(dir, "app/models"))
          FileUtils.mkdir_p(File.join(dir, "app/controllers"))
          FileUtils.mkdir_p(File.join(dir, "config"))
          FileUtils.mkdir_p(File.join(dir, "db/migrate"))
          FileUtils.mkdir_p(File.join(dir, "bin"))
          File.write(File.join(dir, "Gemfile"), "source 'https://rubygems.org'\ngem 'rails'")
          File.write(File.join(dir, "config/application.rb"), "module MyApp; class Application < Rails::Application; end; end")
          File.write(File.join(dir, "config/routes.rb"), "Rails.application.routes.draw { root to: 'home#index' }")
          File.write(File.join(dir, "config/database.yml"), "development:\n  adapter: sqlite3")
          File.write(File.join(dir, "bin/rails"), "#!/usr/bin/env ruby")
          File.write(File.join(dir, "Rakefile"), "require_relative 'config/application'")
          File.write(File.join(dir, "db/migrate/001_create_users.rb"), "class CreateUsers < ActiveRecord::Migration; end")

          result = StackDetector.call(repo_path: dir)

          assert_equal "ruby", result[:language]
          assert_equal "rails", result[:framework]
          assert result[:confidence] >= 50, "Confidence should be >= 50, got #{result[:confidence]}"
          assert result[:signals_matched].any?
        end
      end

      test "detects a Next.js project" do
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, "app"))
          FileUtils.mkdir_p(File.join(dir, "pages"))
          File.write(File.join(dir, "package.json"), '{"dependencies": {"next": "14.0.0"}}')
          File.write(File.join(dir, "next.config.js"), "module.exports = {}")
          File.write(File.join(dir, "tsconfig.json"), "{}")
          File.write(File.join(dir, "app/page.tsx"), "export default function Home() {}")
          File.write(File.join(dir, "app/layout.tsx"), "export default function RootLayout() {}")

          result = StackDetector.call(repo_path: dir)

          assert_equal "typescript", result[:language]
          assert_equal "nextjs", result[:framework]
          assert result[:confidence] >= 50
        end
      end

      test "detects a Rust project" do
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, "src"))
          File.write(File.join(dir, "Cargo.toml"), "[package]\nname = \"myapp\"")
          File.write(File.join(dir, "Cargo.lock"), "")
          File.write(File.join(dir, "src/main.rs"), "fn main() {}")

          result = StackDetector.call(repo_path: dir)

          assert_equal "rust", result[:language]
          assert_nil result[:framework]
          assert result[:confidence] >= 50
        end
      end

      test "returns override result when overrides provided" do
        Dir.mktmpdir do |dir|
          result = StackDetector.call(
            repo_path: dir,
            overrides: { language: "python", framework: "django" }
          )

          assert_equal "python", result[:language]
          assert_equal "django", result[:framework]
          assert_equal 100, result[:confidence]
          assert_includes result[:signals_matched], "manual_override"
        end
      end

      test "returns unknown for empty directory" do
        Dir.mktmpdir do |dir|
          result = StackDetector.call(repo_path: dir)

          assert_equal "unknown", result[:language]
          assert_nil result[:framework]
          assert_equal 0, result[:confidence]
          assert_empty result[:signals_matched]
        end
      end

      test "returns unknown when no stack meets minimum threshold" do
        Dir.mktmpdir do |dir|
          # Only a single weak signal
          File.write(File.join(dir, "Rakefile"), "task :default")

          result = StackDetector.call(repo_path: dir)

          assert_equal "unknown", result[:language]
          assert_equal 0, result[:confidence]
        end
      end

      test "loads additional rules from custom path" do
        Dir.mktmpdir do |dir|
          additional_rules = {
            "stacks" => {
              "elixir_phoenix" => {
                "language" => "elixir",
                "framework" => "phoenix",
                "signals" => [
                  { "type" => "file_exists", "path" => "mix.exs", "weight" => 5 },
                  { "type" => "dir_exists", "path" => "lib", "weight" => 3 }
                ]
              }
            }
          }
          rules_path = File.join(dir, "custom_rules.yml")
          File.write(rules_path, YAML.dump(additional_rules))

          FileUtils.mkdir_p(File.join(dir, "lib"))
          File.write(File.join(dir, "mix.exs"), "defmodule MyApp.MixProject do")

          result = StackDetector.call(repo_path: dir, additional_rules_path: rules_path)

          assert_equal "elixir", result[:language]
          assert_equal "phoenix", result[:framework]
        end
      end

      test "detects React Native project" do
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, "ios"))
          FileUtils.mkdir_p(File.join(dir, "android"))
          FileUtils.mkdir_p(File.join(dir, "src"))
          File.write(File.join(dir, "package.json"), '{"dependencies": {"react-native": "0.73.2", "react": "18.2.0"}}')
          File.write(File.join(dir, "metro.config.js"), "module.exports = {}")
          File.write(File.join(dir, "app.json"), '{"name": "MyApp"}')
          File.write(File.join(dir, "index.js"), "import { AppRegistry } from 'react-native'")
          File.write(File.join(dir, "tsconfig.json"), "{}")
          File.write(File.join(dir, "src/App.tsx"), "export default function App() {}")

          result = StackDetector.call(repo_path: dir)

          assert_equal "javascript", result[:language]
          assert_equal "react_native", result[:framework]
          assert result[:confidence] >= 50, "Confidence should be >= 50, got #{result[:confidence]}"
        end
      end

      test "react_native detection does not confuse with nextjs" do
        Dir.mktmpdir do |dir|
          # Next.js project should not match react_native
          FileUtils.mkdir_p(File.join(dir, "app"))
          File.write(File.join(dir, "package.json"), '{"dependencies": {"next": "14.0.0"}}')
          File.write(File.join(dir, "next.config.js"), "module.exports = {}")
          File.write(File.join(dir, "tsconfig.json"), "{}")
          File.write(File.join(dir, "app/page.tsx"), "export default function Home() {}")
          File.write(File.join(dir, "app/layout.tsx"), "export default function RootLayout() {}")

          result = StackDetector.call(repo_path: dir)

          refute_equal "react_native", result[:framework]
        end
      end

      test "detects Django project" do
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, "myapp"))
          File.write(File.join(dir, "manage.py"), "#!/usr/bin/env python")
          File.write(File.join(dir, "requirements.txt"), "django>=4.0")
          File.write(File.join(dir, "myapp/settings.py"), "INSTALLED_APPS = []")
          File.write(File.join(dir, "myapp/urls.py"), "urlpatterns = []")
          File.write(File.join(dir, "myapp/wsgi.py"), "application = get_wsgi_application()")

          result = StackDetector.call(repo_path: dir)

          assert_equal "python", result[:language]
          assert_equal "django", result[:framework]
          assert result[:confidence] >= 50
        end
      end
    end
  end
end

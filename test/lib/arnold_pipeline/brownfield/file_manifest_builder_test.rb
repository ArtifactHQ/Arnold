require "test_helper"
require "arnold_pipeline/brownfield/file_manifest_builder"
require "tmpdir"

module ArnoldPipeline
  module Brownfield
    class FileManifestBuilderTest < ActiveSupport::TestCase
      test "builds manifest from a repo with Ruby files" do
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, "app/models"))
          File.write(File.join(dir, "app/models/user.rb"), <<~RUBY)
            class User < ApplicationRecord
              has_many :posts
              validates :email, presence: true

              def full_name
                "\#{first_name} \#{last_name}"
              end
            end
          RUBY

          result = FileManifestBuilder.call(repo_path: dir)

          assert_includes result.keys, "app/models/user.rb"
          entry = result["app/models/user.rb"]
          assert_equal :ruby, entry[:language]
          assert entry[:size] > 0
          assert_equal 1, entry[:parsed][:classes].length
          assert_equal "User", entry[:parsed][:classes][0][:name]
          assert_equal 1, entry[:parsed][:associations].length
          assert_equal 1, entry[:parsed][:validations].length
          assert_equal 1, entry[:parsed][:methods].length
        end
      end

      test "builds manifest from a repo with JavaScript files" do
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, "src"))
          File.write(File.join(dir, "src/app.js"), <<~JS)
            import express from 'express';

            const PORT = 3000;

            function startServer() {
              const app = express();
              app.listen(PORT);
            }
          JS

          result = FileManifestBuilder.call(repo_path: dir)

          assert_includes result.keys, "src/app.js"
          entry = result["src/app.js"]
          assert_equal :javascript, entry[:language]
          assert entry[:parsed][:includes].length >= 1
          assert entry[:parsed][:constants].length >= 1
        end
      end

      test "detects language from file extension" do
        Dir.mktmpdir do |dir|
          File.write(File.join(dir, "main.rb"), "class Foo; end")
          File.write(File.join(dir, "app.js"), "const x = 1;")
          File.write(File.join(dir, "component.jsx"), "const App = () => {};")
          File.write(File.join(dir, "index.ts"), "const y: number = 1;")
          File.write(File.join(dir, "page.tsx"), "const Page = () => {};")
          File.write(File.join(dir, "main.py"), "def foo(): pass")
          File.write(File.join(dir, "Main.java"), "public class Main {}")
          File.write(File.join(dir, "main.rs"), "fn main() {}")
          File.write(File.join(dir, "config.yml"), "key: value")

          result = FileManifestBuilder.call(repo_path: dir)

          assert_equal :ruby, result["main.rb"][:language]
          assert_equal :javascript, result["app.js"][:language]
          assert_equal :javascript, result["component.jsx"][:language]
          assert_equal :javascript, result["index.ts"][:language]
          assert_equal :javascript, result["page.tsx"][:language]
          assert_equal :python, result["main.py"][:language]
          assert_equal :java, result["Main.java"][:language]
          assert_equal :rust, result["main.rs"][:language]
          assert_equal :generic, result["config.yml"][:language]
        end
      end

      test "skips .git directory" do
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, ".git/objects"))
          File.write(File.join(dir, ".git/HEAD"), "ref: refs/heads/main")
          File.write(File.join(dir, "app.rb"), "class App; end")

          result = FileManifestBuilder.call(repo_path: dir)

          refute result.keys.any? { |k| k.start_with?(".git") }
          assert_includes result.keys, "app.rb"
        end
      end

      test "skips node_modules directory" do
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, "node_modules/express/lib"))
          File.write(File.join(dir, "node_modules/express/lib/index.js"), "module.exports = {};")
          File.write(File.join(dir, "index.js"), "const app = require('express')();")

          result = FileManifestBuilder.call(repo_path: dir)

          refute result.keys.any? { |k| k.start_with?("node_modules") }
          assert_includes result.keys, "index.js"
        end
      end

      test "skips vendor directory" do
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, "vendor/bundle"))
          File.write(File.join(dir, "vendor/bundle/foo.rb"), "class Foo; end")
          File.write(File.join(dir, "app.rb"), "class App; end")

          result = FileManifestBuilder.call(repo_path: dir)

          refute result.keys.any? { |k| k.start_with?("vendor") }
          assert_includes result.keys, "app.rb"
        end
      end

      test "skips all SKIP_DIRS" do
        Dir.mktmpdir do |dir|
          FileManifestBuilder::SKIP_DIRS.each do |skip_dir|
            FileUtils.mkdir_p(File.join(dir, skip_dir))
            File.write(File.join(dir, skip_dir, "file.rb"), "class Ignored; end")
          end
          File.write(File.join(dir, "main.rb"), "class Main; end")

          result = FileManifestBuilder.call(repo_path: dir)

          assert_equal 1, result.length
          assert_includes result.keys, "main.rb"
        end
      end

      test "skips files larger than MAX_FILE_SIZE" do
        Dir.mktmpdir do |dir|
          # Create a file just under the limit
          small_content = "x" * (FileManifestBuilder::MAX_FILE_SIZE - 1)
          File.write(File.join(dir, "small.rb"), small_content)

          # Create a file over the limit
          large_content = "x" * (FileManifestBuilder::MAX_FILE_SIZE + 1)
          File.write(File.join(dir, "large.rb"), large_content)

          result = FileManifestBuilder.call(repo_path: dir)

          assert_includes result.keys, "small.rb"
          refute_includes result.keys, "large.rb"
        end
      end

      test "handles nested directories" do
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, "app/models/concerns"))
          File.write(File.join(dir, "app/models/concerns/searchable.rb"), <<~RUBY)
            module Searchable
              extend ActiveSupport::Concern
            end
          RUBY

          result = FileManifestBuilder.call(repo_path: dir)

          assert_includes result.keys, "app/models/concerns/searchable.rb"
          entry = result["app/models/concerns/searchable.rb"]
          assert_equal 1, entry[:parsed][:modules].length
          assert_equal "Searchable", entry[:parsed][:modules][0][:name]
        end
      end

      test "returns relative paths from repo root" do
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, "lib"))
          File.write(File.join(dir, "lib/utils.rb"), "module Utils; end")

          result = FileManifestBuilder.call(repo_path: dir)

          result.keys.each do |path|
            refute path.start_with?("/"), "Path should be relative: #{path}"
            refute path.include?(dir), "Path should not contain repo root: #{path}"
          end
        end
      end

      test "includes file size in manifest entries" do
        Dir.mktmpdir do |dir|
          content = "class Foo; end"
          File.write(File.join(dir, "app.rb"), content)

          result = FileManifestBuilder.call(repo_path: dir)

          assert_equal content.bytesize, result["app.rb"][:size]
        end
      end

      test "handles empty repository" do
        Dir.mktmpdir do |dir|
          result = FileManifestBuilder.call(repo_path: dir)

          assert_equal({}, result)
        end
      end

      test "handles mixed language repo" do
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, "backend"))
          FileUtils.mkdir_p(File.join(dir, "frontend/src"))

          File.write(File.join(dir, "backend/app.rb"), "class App; end")
          File.write(File.join(dir, "frontend/src/index.js"), "import React from 'react';")
          File.write(File.join(dir, "README.md"), "# My Project")

          result = FileManifestBuilder.call(repo_path: dir)

          assert_equal :ruby, result["backend/app.rb"][:language]
          assert_equal :javascript, result["frontend/src/index.js"][:language]
          assert_equal :generic, result["README.md"][:language]
        end
      end

      test "accepts stack_fingerprint parameter" do
        Dir.mktmpdir do |dir|
          File.write(File.join(dir, "app.rb"), "class App; end")

          fingerprint = { language: "ruby", framework: "rails" }
          result = FileManifestBuilder.call(repo_path: dir, stack_fingerprint: fingerprint)

          assert_includes result.keys, "app.rb"
        end
      end

      test "handles binary-like content gracefully" do
        Dir.mktmpdir do |dir|
          # Write a file with invalid UTF-8 bytes
          File.binwrite(File.join(dir, "data.bin"), "\xFF\xFE\x00\x01class Foo; end")

          result = FileManifestBuilder.call(repo_path: dir)

          # Should not crash, file should be in manifest
          assert_includes result.keys, "data.bin"
        end
      end

      test "walks directory in sorted order" do
        Dir.mktmpdir do |dir|
          File.write(File.join(dir, "z_file.rb"), "class Z; end")
          File.write(File.join(dir, "a_file.rb"), "class A; end")
          File.write(File.join(dir, "m_file.rb"), "class M; end")

          result = FileManifestBuilder.call(repo_path: dir)
          keys = result.keys

          assert_equal %w[a_file.rb m_file.rb z_file.rb], keys
        end
      end

      test "Python files are parsed with Python parser" do
        Dir.mktmpdir do |dir|
          File.write(File.join(dir, "app.py"), <<~PYTHON)
            from flask import Flask

            class MyApp:
                def run(self):
                    pass
          PYTHON

          result = FileManifestBuilder.call(repo_path: dir)

          entry = result["app.py"]
          assert_equal :python, entry[:language]
          assert_equal 1, entry[:parsed][:classes].length
          assert_equal "MyApp", entry[:parsed][:classes][0][:name]
        end
      end

      test "Java files are parsed with Java parser" do
        Dir.mktmpdir do |dir|
          File.write(File.join(dir, "Main.java"), <<~JAVA)
            import java.util.List;

            public class Main {
                public static void main(String[] args) {
                    System.out.println("Hello");
                }
            }
          JAVA

          result = FileManifestBuilder.call(repo_path: dir)

          entry = result["Main.java"]
          assert_equal :java, entry[:language]
          assert_equal 1, entry[:parsed][:classes].length
          assert_equal "Main", entry[:parsed][:classes][0][:name]
        end
      end

      test "Rust files are parsed with Rust parser" do
        Dir.mktmpdir do |dir|
          File.write(File.join(dir, "main.rs"), <<~RUST)
            use std::io;

            pub struct Config {
                debug: bool,
            }

            fn main() {
                println!("Hello");
            }
          RUST

          result = FileManifestBuilder.call(repo_path: dir)

          entry = result["main.rs"]
          assert_equal :rust, entry[:language]
          assert_equal 1, entry[:parsed][:classes].length
          assert_equal "Config", entry[:parsed][:classes][0][:name]
        end
      end
    end
  end
end

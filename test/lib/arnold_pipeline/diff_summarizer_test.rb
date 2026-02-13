require "test_helper"
require "arnold_pipeline/diff_summarizer"

module ArnoldPipeline
  class DiffSummarizerTest < ActiveSupport::TestCase
    setup do
      ArnoldPipeline.reset_configuration!
    end

    teardown do
      ArnoldPipeline.reset_configuration!
    end

    # --- JSON parsing ---

    test "parses JSON array of file diffs" do
      diffs = [
        [{ filename: "app/models/user.rb", patch: "+class User; end", status: "added" }].to_json
      ]

      result = DiffSummarizer.call(diffs)

      assert_includes result, "app/models/user.rb"
      assert_includes result, "+class User; end"
    end

    test "handles multiple tasks with JSON diffs" do
      diff1 = [{ filename: "file1.rb", patch: "+code1", status: "added" }].to_json
      diff2 = [{ filename: "file2.rb", patch: "+code2", status: "modified" }].to_json

      result = DiffSummarizer.call([diff1, diff2])

      assert_includes result, "file1.rb"
      assert_includes result, "file2.rb"
    end

    test "parses JSON with string keys" do
      diffs = [
        [{ "filename" => "app.rb", "patch" => "+hello", "status" => "added" }].to_json
      ]

      result = DiffSummarizer.call(diffs)

      assert_includes result, "app.rb"
      assert_includes result, "+hello"
    end

    # --- Noise filtering ---

    test "filters out lock files" do
      diffs = [
        [
          { filename: "Gemfile.lock", patch: "+gem data", status: "modified" },
          { filename: "app/models/user.rb", patch: "+class User; end", status: "added" }
        ].to_json
      ]

      result = DiffSummarizer.call(diffs)

      refute_includes result, "Gemfile.lock"
      assert_includes result, "user.rb"
      assert_includes result, "1 noise file(s) excluded"
    end

    test "filters out package-lock.json" do
      diffs = [
        [
          { filename: "package-lock.json", patch: "+lots of json", status: "modified" },
          { filename: "src/index.js", patch: "+code", status: "added" }
        ].to_json
      ]

      result = DiffSummarizer.call(diffs)

      refute_includes result, "package-lock.json"
      assert_includes result, "index.js"
    end

    test "filters out tmp/ and log/ directories" do
      diffs = [
        [
          { filename: "tmp/cache/bootsnap/compile-cache-iseq/foo", patch: "binary", status: "added" },
          { filename: "log/development.log", patch: "+log line", status: "modified" },
          { filename: "app/controllers/home_controller.rb", patch: "+code", status: "added" }
        ].to_json
      ]

      result = DiffSummarizer.call(diffs)

      refute_includes result, "tmp/cache"
      refute_includes result, "development.log"
      assert_includes result, "home_controller.rb"
      assert_includes result, "2 noise file(s) excluded"
    end

    test "filters out node_modules" do
      diffs = [
        [
          { filename: "node_modules/express/index.js", patch: "+code", status: "added" },
          { filename: "app.js", patch: "+main code", status: "added" }
        ].to_json
      ]

      result = DiffSummarizer.call(diffs)

      refute_includes result, "node_modules"
      assert_includes result, "app.js"
    end

    test "filters out binary file extensions" do
      diffs = [
        [
          { filename: "logo.png", patch: "binary", status: "added" },
          { filename: "font.woff2", patch: "binary", status: "added" },
          { filename: "app.rb", patch: "+code", status: "added" }
        ].to_json
      ]

      result = DiffSummarizer.call(diffs)

      refute_includes result, "logo.png"
      refute_includes result, "font.woff2"
      assert_includes result, "app.rb"
    end

    test "filters out .idea/ directory" do
      diffs = [
        [
          { filename: ".idea/workspace.xml", patch: "+xml stuff", status: "added" },
          { filename: "app.rb", patch: "+code", status: "added" }
        ].to_json
      ]

      result = DiffSummarizer.call(diffs)

      refute_includes result, ".idea"
      assert_includes result, "app.rb"
    end

    test "filters out bootsnap paths" do
      diffs = [
        [
          { filename: "bootsnap/compile-cache/foo.rb", patch: "cache", status: "added" },
          { filename: "app.rb", patch: "+code", status: "added" }
        ].to_json
      ]

      result = DiffSummarizer.call(diffs)

      refute_includes result, "bootsnap"
      assert_includes result, "app.rb"
    end

    # --- Truncation ---

    test "truncates individual file patches exceeding max_per_file_chars" do
      long_patch = "x" * 20_000
      diffs = [
        [{ filename: "big.rb", patch: long_patch, status: "modified" }].to_json
      ]

      result = DiffSummarizer.call(diffs, max_per_file_chars: 500)

      assert_includes result, "[truncated]"
      assert result.length < long_patch.length
    end

    test "respects max_total_chars budget" do
      files = (1..20).map do |i|
        { filename: "file#{i}.rb", patch: "a" * 10_000, status: "added" }
      end
      diffs = [files.to_json]

      result = DiffSummarizer.call(diffs, max_total_chars: 5_000, max_per_file_chars: 10_000)

      assert result.length <= 5_200 # Allow for summary lines
      assert_includes result, "more file(s) omitted"
    end

    test "budget message reports remaining file count" do
      files = (1..5).map do |i|
        { filename: "file#{i}.rb", patch: "a" * 3_000, status: "added" }
      end
      diffs = [files.to_json]

      result = DiffSummarizer.call(diffs, max_total_chars: 4_000, max_per_file_chars: 10_000)

      assert_match(/\d+ more file\(s\) omitted/, result)
    end

    # --- Prioritization ---

    test "source code appears before config/docs" do
      diffs = [
        [
          { filename: "config/database.yml", patch: "+db config", status: "modified" },
          { filename: "README.md", patch: "+docs", status: "modified" },
          { filename: "app/models/user.rb", patch: "+class User", status: "added" }
        ].to_json
      ]

      result = DiffSummarizer.call(diffs)

      user_pos = result.index("user.rb")
      config_pos = result.index("database.yml")
      readme_pos = result.index("README.md")

      assert user_pos < config_pos, "Source code should appear before config"
      assert user_pos < readme_pos, "Source code should appear before docs"
    end

    # --- Legacy fallback ---

    test "handles non-JSON legacy diff text" do
      raw_diff = <<~DIFF
        diff --git a/file.rb b/file.rb
        +class Foo; end
      DIFF

      result = DiffSummarizer.call([raw_diff])

      assert_includes result, "diff --git"
      assert_includes result, "+class Foo; end"
    end

    test "handles empty and nil diffs" do
      result = DiffSummarizer.call(["", nil, "  "])

      assert_equal "", result.strip
    end

    test "handles empty array" do
      result = DiffSummarizer.call([])

      assert_equal "", result
    end

    # --- Configuration ---

    test "uses configuration defaults" do
      ArnoldPipeline.configure do |c|
        c.max_diff_chars = 500
        c.max_diff_per_file_chars = 100
      end

      long_patch = "x" * 1_000
      diffs = [
        [{ filename: "big.rb", patch: long_patch, status: "modified" }].to_json
      ]

      result = DiffSummarizer.call(diffs)

      assert_includes result, "[truncated]"
    end

    test "call parameters override configuration" do
      ArnoldPipeline.configure do |c|
        c.max_diff_per_file_chars = 50
      end

      patch = "x" * 100
      diffs = [
        [{ filename: "file.rb", patch: patch, status: "modified" }].to_json
      ]

      # Override to be generous — should NOT truncate
      result = DiffSummarizer.call(diffs, max_per_file_chars: 10_000)

      refute_includes result, "[truncated]"
    end

    # --- Mixed scenarios ---

    test "mixed JSON and legacy diffs in same call" do
      json_diff = [{ filename: "app.rb", patch: "+json code", status: "added" }].to_json
      legacy_diff = "diff --git a/old.rb b/old.rb\n+legacy code"

      result = DiffSummarizer.call([json_diff, legacy_diff])

      assert_includes result, "app.rb"
      assert_includes result, "legacy code"
    end

    test "all files filtered produces only noise summary" do
      diffs = [
        [
          { filename: "Gemfile.lock", patch: "+data", status: "modified" },
          { filename: "tmp/cache/foo", patch: "+cache", status: "added" }
        ].to_json
      ]

      result = DiffSummarizer.call(diffs)

      assert_includes result, "2 noise file(s) excluded"
      refute_includes result, "Gemfile.lock"
    end

    test "vendor/bundle is filtered" do
      diffs = [
        [
          { filename: "vendor/bundle/ruby/3.2.0/gems/foo/lib/foo.rb", patch: "+code", status: "added" },
          { filename: "app.rb", patch: "+main", status: "added" }
        ].to_json
      ]

      result = DiffSummarizer.call(diffs)

      refute_includes result, "vendor/bundle"
      assert_includes result, "app.rb"
    end
  end
end

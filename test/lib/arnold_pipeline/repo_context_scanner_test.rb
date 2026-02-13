require "test_helper"
require "arnold_pipeline/repo_context_scanner"

module ArnoldPipeline
  class RepoContextScannerTest < ActiveSupport::TestCase
    setup do
      ArnoldPipeline.configure do |c|
        c.llm_api_key = "test"
      end
    end

    teardown do
      ArnoldPipeline.reset_configuration!
    end

    test "returns nil when repo_path is nil" do
      result = RepoContextScanner.call(repo_path: nil)
      assert_nil result
    end

    test "returns nil when repo_path does not exist" do
      result = RepoContextScanner.call(repo_path: "/nonexistent/path/12345")
      assert_nil result
    end

    test "returns sorted file list for valid repo" do
      # Use the project root as a known git repo
      repo_path = File.expand_path("../../..", __dir__)
      result = RepoContextScanner.call(
        repo_path: repo_path,
        scan_patterns: %w[lib/arnold_pipeline/agents/],
        scan_files: %w[Gemfile]
      )

      assert_kind_of Array, result
      assert_includes result, "Gemfile"
      assert result.any? { |f| f.start_with?("lib/arnold_pipeline/agents/") },
        "Expected files under lib/arnold_pipeline/agents/"
      assert_equal result, result.sort, "Results should be sorted"
    end

    test "returns empty array when no matching files found" do
      repo_path = File.expand_path("../../..", __dir__)
      result = RepoContextScanner.call(
        repo_path: repo_path,
        scan_patterns: %w[nonexistent_dir_xyz/],
        scan_files: %w[nonexistent_file_xyz.rb]
      )

      assert_kind_of Array, result
      assert_empty result
    end

    test "handles non-git directory gracefully" do
      result = RepoContextScanner.call(repo_path: Dir.tmpdir)
      assert(result.nil? || result.empty?, "Expected nil or empty array for non-git dir, got: #{result.inspect}")
    end

    test "handles empty repo gracefully" do
      Dir.mktmpdir do |tmpdir|
        system("git", "-C", tmpdir, "init", "--quiet", out: File::NULL, err: File::NULL)
        # Empty repo — no HEAD, so git ls-tree fails
        result = RepoContextScanner.call(repo_path: tmpdir)
        # Should return nil (git ls-tree fails on empty repo) or empty array
        assert(result.nil? || result.empty?, "Expected nil or empty array for empty repo, got: #{result.inspect}")
      end
    end

    test "respects configured scan patterns" do
      repo_path = File.expand_path("../../..", __dir__)

      ArnoldPipeline.configure do |c|
        c.llm_api_key = "test"
        c.repo_context_scan_patterns = %w[app/models/]
        c.repo_context_scan_files = %w[Gemfile]
      end

      result = RepoContextScanner.call(repo_path: repo_path)

      assert_kind_of Array, result
      assert_includes result, "Gemfile"
      # Should only have files from app/models/ and Gemfile, not from lib/ etc.
      lib_files = result.select { |f| f.start_with?("lib/") }
      assert_empty lib_files, "Should not include lib/ files when custom patterns exclude it"
    end

    test "deduplicates files found via both patterns and files" do
      repo_path = File.expand_path("../../..", __dir__)
      result = RepoContextScanner.call(
        repo_path: repo_path,
        scan_patterns: %w[lib/arnold_pipeline/],
        scan_files: %w[lib/arnold_pipeline/orchestrator.rb]
      )

      assert_kind_of Array, result
      # orchestrator.rb would match both pattern and file — should only appear once
      occurrences = result.count { |f| f == "lib/arnold_pipeline/orchestrator.rb" }
      assert_equal 1, occurrences, "File should only appear once (deduped)"
    end
  end
end

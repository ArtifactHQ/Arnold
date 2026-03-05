require "test_helper"
require "arnold_pipeline/brownfield/file_content_cache"
require "tmpdir"

module ArnoldPipeline
  module Brownfield
    class FileContentCacheTest < ActiveSupport::TestCase
      setup do
        @dir = Dir.mktmpdir("cache_test_")
        File.write(File.join(@dir, "hello.rb"), "puts 'hello'")
        File.write(File.join(@dir, "big.txt"), "x" * 100_000)
        FileUtils.mkdir_p(File.join(@dir, "sub"))
        File.write(File.join(@dir, "sub", "nested.rb"), "class Nested; end")
        @cache = FileContentCache.new(repo_path: @dir)
      end

      teardown do
        FileUtils.rm_rf(@dir)
      end

      test "reads file content" do
        content = @cache.read("hello.rb")
        assert_equal "puts 'hello'", content
      end

      test "returns nil for nonexistent file" do
        assert_nil @cache.read("nonexistent.rb")
      end

      test "returns nil for files exceeding max_size" do
        assert_nil @cache.read("big.txt")
      end

      test "respects custom max_size" do
        content = @cache.read("big.txt", max_size: 200_000)
        assert_equal 100_000, content.length
      end

      test "caches results on subsequent reads" do
        content1 = @cache.read("hello.rb")
        # Delete file — cache should still serve it
        File.delete(File.join(@dir, "hello.rb"))
        content2 = @cache.read("hello.rb")
        assert_equal content1, content2
      end

      test "caches nil for missing files" do
        @cache.read("missing.rb")
        assert_equal 1, @cache.size
        assert_nil @cache.read("missing.rb")
      end

      test "reads nested files" do
        content = @cache.read("sub/nested.rb")
        assert_equal "class Nested; end", content
      end

      test "read_batch returns hash of contents" do
        result = @cache.read_batch([ "hello.rb", "sub/nested.rb", "missing.rb" ])
        assert_equal 2, result.size
        assert_equal "puts 'hello'", result["hello.rb"]
        assert_equal "class Nested; end", result["sub/nested.rb"]
        refute result.key?("missing.rb")
      end

      test "cached_paths tracks what has been read" do
        @cache.read("hello.rb")
        @cache.read("sub/nested.rb")
        assert_includes @cache.cached_paths, "hello.rb"
        assert_includes @cache.cached_paths, "sub/nested.rb"
      end

      test "size reflects cache entries" do
        assert_equal 0, @cache.size
        @cache.read("hello.rb")
        assert_equal 1, @cache.size
      end

      test "is thread-safe for concurrent reads" do
        threads = 10.times.map do |i|
          Thread.new { @cache.read("hello.rb") }
        end

        results = threads.map(&:value)
        assert results.all? { |r| r == "puts 'hello'" }
        assert_equal 1, @cache.size
      end

      test "returns nil for directories" do
        assert_nil @cache.read("sub")
      end
    end
  end
end

module ArnoldPipeline
  module Brownfield
    class FileContentCache
      DEFAULT_MAX_SIZE = 50 * 1024 # 50KB

      def initialize(repo_path:)
        @repo_path = repo_path
        @cache = {}
        @mutex = Mutex.new
      end

      def read(relative_path, max_size: DEFAULT_MAX_SIZE)
        @mutex.synchronize do
          return @cache[relative_path] if @cache.key?(relative_path)
        end

        content = read_file(relative_path, max_size)

        @mutex.synchronize do
          @cache[relative_path] = content
        end

        content
      end

      def read_batch(paths, max_size: DEFAULT_MAX_SIZE)
        paths.each_with_object({}) do |path, result|
          content = read(path, max_size:)
          result[path] = content if content
        end
      end

      def cached_paths
        @mutex.synchronize { @cache.keys }
      end

      def size
        @mutex.synchronize { @cache.size }
      end

      private

      def read_file(relative_path, max_size)
        full_path = File.join(@repo_path, relative_path)
        return nil unless File.file?(full_path)

        stat = File.stat(full_path)
        return nil if stat.size > max_size

        content = File.read(full_path, encoding: "utf-8")
        content.encode("UTF-8", invalid: :replace, undef: :replace, replace: "")
      rescue Errno::ENOENT, Errno::EACCES, Errno::EISDIR
        nil
      rescue => e
        nil
      end
    end
  end
end

require "arnold_pipeline/brownfield/parsers/ruby"
require "arnold_pipeline/brownfield/parsers/javascript"
require "arnold_pipeline/brownfield/parsers/python"
require "arnold_pipeline/brownfield/parsers/java"
require "arnold_pipeline/brownfield/parsers/rust"
require "arnold_pipeline/brownfield/parsers/generic"

module ArnoldPipeline
  module Brownfield
    class FileManifestBuilder
      MAX_FILE_SIZE = 50 * 1024 # 50KB
      SKIP_DIRS = %w[.git node_modules vendor tmp log .bundle coverage].freeze

      EXTENSION_MAP = {
        ".rb" => :ruby,
        ".js" => :javascript,
        ".jsx" => :javascript,
        ".ts" => :javascript,
        ".tsx" => :javascript,
        ".py" => :python,
        ".java" => :java,
        ".rs" => :rust
      }.freeze

      PARSER_MAP = {
        ruby: Parsers::Ruby,
        javascript: Parsers::Javascript,
        python: Parsers::Python,
        java: Parsers::Java,
        rust: Parsers::Rust,
        generic: Parsers::Generic
      }.freeze

      def self.call(repo_path:, stack_fingerprint: {})
        new(repo_path:, stack_fingerprint:).call
      end

      def initialize(repo_path:, stack_fingerprint: {})
        @repo_path = File.expand_path(repo_path)
        @stack_fingerprint = stack_fingerprint
      end

      def call
        manifest = {}

        walk_repo do |full_path, relative_path|
          size = File.size(full_path)
          next if size > MAX_FILE_SIZE

          language = detect_language(relative_path)
          content = File.read(full_path, encoding: "utf-8")
          # Skip binary files that fail to read as UTF-8
          content.encode!("UTF-8", invalid: :replace, undef: :replace, replace: "")

          parser = PARSER_MAP.fetch(language, Parsers::Generic)
          parsed = parser.call(content: content)

          manifest[relative_path] = {
            size: size,
            language: language,
            parsed: parsed
          }
        rescue Errno::EACCES, Errno::ENOENT
          # Skip unreadable files silently
          next
        end

        manifest
      end

      private

      def walk_repo
        walk_directory(@repo_path, "") do |full_path, relative_path|
          yield(full_path, relative_path)
        end
      end

      def walk_directory(base_path, relative_prefix, &block)
        entries = Dir.entries(base_path)
        entries.sort.each do |entry|
          next if entry == "." || entry == ".."

          full_path = File.join(base_path, entry)
          relative_path = relative_prefix.empty? ? entry : File.join(relative_prefix, entry)

          if File.directory?(full_path)
            next if SKIP_DIRS.include?(entry)
            walk_directory(full_path, relative_path, &block)
          elsif File.file?(full_path)
            yield(full_path, relative_path)
          end
        end
      end

      def detect_language(relative_path)
        ext = File.extname(relative_path).downcase
        EXTENSION_MAP.fetch(ext, :generic)
      end
    end
  end
end

require "open3"

module ArnoldPipeline
  class RepoContextScanner
    MAX_FILES_PER_DIR = 20

    DEFAULT_SCAN_PATTERNS = %w[
      db/migrate/
      config/
      app/models/
      app/controllers/
      lib/
    ].freeze

    DEFAULT_SCAN_FILES = %w[
      Gemfile
      config/routes.rb
      config/database.yml
      db/schema.rb
      db/structure.sql
    ].freeze

    def self.call(repo_path:, scan_patterns: nil, scan_files: nil)
      return nil unless repo_path && Dir.exist?(repo_path)

      config = ArnoldPipeline.configuration
      patterns = scan_patterns || config.repo_context_scan_patterns || DEFAULT_SCAN_PATTERNS
      files = scan_files || config.repo_context_scan_files || DEFAULT_SCAN_FILES
      new(repo_path:, scan_patterns: patterns, scan_files: files).call
    end

    def initialize(repo_path:, scan_patterns:, scan_files:)
      @repo_path = repo_path
      @scan_patterns = scan_patterns
      @scan_files = scan_files
    end

    def call
      results = []

      @scan_patterns.each do |pattern|
        output, status = Open3.capture2("git", "-C", @repo_path, "ls-tree", "-r", "--name-only", "HEAD", pattern)
        next unless status.success?

        output.each_line do |line|
          path = line.strip
          results << path unless path.empty?
        end
      end

      @scan_files.each do |file|
        output, status = Open3.capture2("git", "-C", @repo_path, "ls-tree", "--name-only", "HEAD", file)
        next unless status.success?

        path = output.strip
        results << path unless path.empty?
      end

      results.uniq.sort
    rescue => e
      nil
    end
  end
end

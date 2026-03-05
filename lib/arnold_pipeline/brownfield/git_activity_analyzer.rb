require "open3"

module ArnoldPipeline
  module Brownfield
    class GitActivityAnalyzer
      TIMEOUT = 30

      def self.call(repo_path:, since: nil)
        new(repo_path:, since:).call
      end

      def initialize(repo_path:, since: nil)
        @repo_path = repo_path
        @since = since || "6 months ago"
      end

      def call
        output = run_git_log
        return {} if output.nil? || output.strip.empty?

        parse_log(output)
      rescue => e
        {}
      end

      private

      def run_git_log
        command = "git log --name-only --format=\"%H|%an|%aI\" --since=\"#{@since}\""
        stdout, _stderr, status = Open3.capture3(
          command,
          chdir: @repo_path,
          timeout: TIMEOUT
        )
        return nil unless status.success?

        stdout
      rescue => e
        nil
      end

      def parse_log(output)
        result = {}
        current_date = nil
        current_author = nil

        output.each_line do |raw_line|
          line = raw_line.strip
          next if line.empty?

          if line.match?(/\A[0-9a-f]+\|.+\|.+\z/)
            # Commit header line: hash|author|iso_date
            parts = line.split("|", 3)
            current_author = parts[1]
            current_date = parse_date(parts[2])
          else
            # File path line
            file_path = line
            entry = result[file_path] ||= { commits: 0, last_modified: nil, authors: [] }
            entry[:commits] += 1
            entry[:authors] << current_author unless entry[:authors].include?(current_author)

            if current_date
              if entry[:last_modified].nil? || current_date > entry[:last_modified]
                entry[:last_modified] = current_date
              end
            end
          end
        end

        result
      end

      def parse_date(iso_string)
        # Extract just the date portion from ISO 8601 timestamp
        iso_string[0, 10]
      rescue => e
        nil
      end
    end
  end
end

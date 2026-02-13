require "json"

module ArnoldPipeline
  class DiffSummarizer
    NOISE_PATTERNS = %w[
      Gemfile.lock
      package-lock.json
      yarn.lock
      pnpm-lock.yaml
    ].freeze

    NOISE_DIRS = %w[
      tmp/
      log/
      node_modules/
      vendor/bundle/
      .bundle/
      .idea/
      bootsnap
    ].freeze

    BINARY_EXTENSIONS = %w[
      .png .jpg .jpeg .gif .ico .svg .woff .woff2 .ttf .eot .otf
      .zip .tar .gz .bz2 .rar .7z
      .exe .dll .so .dylib
      .sqlite3 .db
    ].freeze

    # Lower priority — summarized last, truncated first
    LOW_PRIORITY_PATTERNS = %w[
      config/
      .yml
      .yaml
      .json
      .md
      .txt
      .lock
      .generated
    ].freeze

    def self.call(result_diffs, max_total_chars: nil, max_per_file_chars: nil)
      new(result_diffs,
        max_total_chars: max_total_chars || ArnoldPipeline.configuration.max_diff_chars,
        max_per_file_chars: max_per_file_chars || ArnoldPipeline.configuration.max_diff_per_file_chars
      ).call
    end

    def initialize(result_diffs, max_total_chars:, max_per_file_chars:)
      @result_diffs = result_diffs
      @max_total_chars = max_total_chars
      @max_per_file_chars = max_per_file_chars
    end

    def call
      all_files = parse_all_diffs
      deduped = deduplicate_files(all_files)
      filtered = filter_noise(deduped)
      sorted = prioritize(filtered)
      excluded_count = deduped.size - filtered.size

      build_output(sorted, excluded_count)
    end

    private

    def parse_all_diffs
      @result_diffs.flat_map { |diff_text| parse_one(diff_text) }
    end

    def parse_one(diff_text)
      return [] if diff_text.nil? || diff_text.strip.empty?

      parsed = try_parse_json(diff_text)
      return parsed if parsed

      # Legacy format: raw unified diff text
      [{ filename: "(raw diff)", patch: diff_text, status: "unknown" }]
    end

    def try_parse_json(text)
      data = JSON.parse(text)

      case data
      when Array
        data.map do |entry|
          {
            filename: entry["filename"] || entry[:filename] || "unknown",
            patch: entry["patch"] || entry[:patch] || "",
            status: entry["status"] || entry[:status] || "unknown"
          }
        end
      else
        nil
      end
    rescue JSON::ParserError
      nil
    end

    # When multiple entries exist for the same filename (e.g., original task
    # created a file, corrective task modified it), keep only the last entry.
    # Tasks are ordered by position/id, so the last entry is the most recent.
    def deduplicate_files(files)
      seen = {}
      files.each_with_index do |file, index|
        seen[file[:filename]] = index
      end
      seen.values.sort.map { |i| files[i] }
    end

    def filter_noise(files)
      files.reject { |f| noise?(f[:filename]) }
    end

    def noise?(filename)
      return false if filename == "(raw diff)"

      NOISE_PATTERNS.any? { |p| filename == p } ||
        NOISE_DIRS.any? { |d| filename.include?(d) } ||
        BINARY_EXTENSIONS.any? { |ext| filename.downcase.end_with?(ext) }
    end

    def prioritize(files)
      files.sort_by do |f|
        low = LOW_PRIORITY_PATTERNS.any? { |p| f[:filename].include?(p) } ? 1 : 0
        [low, f[:filename]]
      end
    end

    def build_output(files, excluded_count)
      parts = []
      total_chars = 0

      files.each do |file|
        patch = file[:patch]
        truncated = false

        if patch.length > @max_per_file_chars
          patch = patch[0, @max_per_file_chars]
          truncated = true
        end

        entry = format_entry(file[:filename], file[:status], patch, truncated)

        if total_chars + entry.length > @max_total_chars
          remaining = files.size - parts.size
          parts << "\n[Budget exceeded — #{remaining} more file(s) omitted]"
          break
        end

        parts << entry
        total_chars += entry.length
      end

      if excluded_count > 0
        parts << "\n[#{excluded_count} noise file(s) excluded: lock files, cache dirs, binaries]"
      end

      parts.join("\n\n")
    end

    def format_entry(filename, status, patch, truncated)
      header = "### #{filename} (#{status})"
      header += " [truncated]" if truncated
      "#{header}\n```\n#{patch}\n```"
    end
  end
end

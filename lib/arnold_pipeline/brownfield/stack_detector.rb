require "yaml"

module ArnoldPipeline
  module Brownfield
    class StackDetector
      RULES_PATH = File.expand_path("data/detection_rules.yml", __dir__)
      MIN_CONFIDENCE = 0.5

      def self.call(repo_path:, overrides: {}, additional_rules_path: nil)
        new(repo_path:, overrides:, additional_rules_path:).call
      end

      def initialize(repo_path:, overrides: {}, additional_rules_path: nil)
        @repo_path = repo_path
        @overrides = overrides || {}
        @additional_rules_path = additional_rules_path
      end

      def call
        return override_result if @overrides.any?

        rules = load_rules
        file_index = build_file_index

        scores = rules.map do |stack_id, rule|
          score, matched = evaluate_signals(rule["signals"], file_index)
          max_possible = rule["signals"].sum { |s| s["weight"] }
          confidence = max_possible > 0 ? (score.to_f / max_possible).round(2) : 0.0
          { stack_id:, rule:, score:, confidence:, matched: }
        end

        best = scores.max_by { |s| s[:score] }

        if best.nil? || best[:confidence] < MIN_CONFIDENCE
          return unknown_result
        end

        {
          language: best[:rule]["language"],
          framework: best[:rule]["framework"],
          version: nil,
          confidence: (best[:confidence] * 100).round,
          signals_matched: best[:matched],
          ecosystem: {}
        }
      end

      private

      def override_result
        {
          language: @overrides[:language] || @overrides["language"],
          framework: @overrides[:framework] || @overrides["framework"],
          version: @overrides[:version] || @overrides["version"],
          confidence: 100,
          signals_matched: ["manual_override"],
          ecosystem: {}
        }
      end

      def unknown_result
        {
          language: "unknown",
          framework: nil,
          version: nil,
          confidence: 0,
          signals_matched: [],
          ecosystem: {}
        }
      end

      def load_rules
        rules = YAML.safe_load_file(RULES_PATH)["stacks"]

        if @additional_rules_path && File.exist?(@additional_rules_path)
          additional = YAML.safe_load_file(@additional_rules_path)["stacks"] || {}
          rules.merge!(additional)
        end

        rules
      end

      def build_file_index
        entries = Set.new

        # Scan top 2 levels + key subdirectories
        scan_patterns = [
          "*",
          "*/*",
          "src/**/*",
          "app/**/*",
          "lib/**/*",
          "config/**/*",
          "db/**/*"
        ]

        scan_patterns.each do |pattern|
          Dir.glob(File.join(@repo_path, pattern)).each do |path|
            relative = path.sub("#{@repo_path}/", "")
            entries << relative
          end
        end

        entries
      end

      def evaluate_signals(signals, file_index)
        total_score = 0
        matched = []

        signals.each do |signal|
          if signal_matches?(signal, file_index)
            total_score += signal["weight"]
            matched << signal_description(signal)
          end
        end

        [total_score, matched]
      end

      def signal_matches?(signal, file_index)
        case signal["type"]
        when "file_exists"
          path = signal["path"]
          if file_index.include?(path)
            if signal["contains"]
              file_contains?(path, signal["contains"])
            else
              true
            end
          else
            false
          end
        when "dir_exists"
          path = signal["path"]
          Dir.exist?(File.join(@repo_path, path))
        when "file_glob"
          matches = Dir.glob(File.join(@repo_path, signal["pattern"]))
          if matches.any?
            if signal["contains"]
              matches.any? { |f| File.file?(f) && File.read(f).include?(signal["contains"]) }
            else
              true
            end
          else
            false
          end
        else
          false
        end
      end

      def file_contains?(relative_path, search_string)
        full_path = File.join(@repo_path, relative_path)
        return false unless File.file?(full_path)

        File.read(full_path).include?(search_string)
      rescue
        false
      end

      def signal_description(signal)
        case signal["type"]
        when "file_exists"
          desc = "file:#{signal['path']}"
          desc += "(contains:#{signal['contains']})" if signal["contains"]
          desc
        when "dir_exists"
          "dir:#{signal['path']}"
        when "file_glob"
          "glob:#{signal['pattern']}"
        end
      end
    end
  end
end

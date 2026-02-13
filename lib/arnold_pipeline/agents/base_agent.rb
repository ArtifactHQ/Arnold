require "arnold_pipeline/providers/llm/base"
require "logger"

module ArnoldPipeline
  module Agents
    class BaseAgent
      attr_reader :llm, :logger

      def initialize(llm: nil, logger: nil)
        @llm = llm || Providers::Llm.build
        @logger = logger || default_logger
      end

      def call(**)
        raise NotImplementedError, "#{self.class}#call must be implemented"
      end

      private

      def chat(messages:, system: nil)
        logger.debug { "#{self.class.name} sending #{messages.size} message(s)" }
        response = llm.chat(messages:, system:)
        logger.debug { "#{self.class.name} received #{response.size} chars" }
        response
      end

      def chat_json(messages:, system: nil, schema:)
        logger.debug { "#{self.class.name} sending #{messages.size} message(s) (structured output: #{schema[:name]})" }
        result = llm.chat_json(messages:, system:, schema:)
        logger.debug { "#{self.class.name} received structured output (#{result.class})" }
        result
      end

      def parse_json(text)
        raw = extract_json(text)
        sanitized = raw.gsub(/[\x00-\x08\x0b\x0c\x0e-\x1f]/, "")
        JSON.parse(sanitized, allow_trailing_comma: true)
      rescue JSON::ParserError => e
        logger.error { "JSON parse failed: #{e.message}" }
        logger.debug { "Extracted content (first 200 chars): #{raw&.slice(0, 200).inspect}" }
        raise
      end

      def extract_json(text)
        extract_from_code_fences(text) ||
          extract_by_bracket_matching(text) ||
          text
      end

      def extract_from_code_fences(text)
        fences = text.scan(/```(\w*)\s*\n(.*?)\n\s*```/m)
        return nil if fences.empty?

        json_tagged = fences.select { |lang, _| lang.downcase == "json" }
        untagged = fences.select { |lang, _| lang.empty? }
        candidates = json_tagged.any? ? json_tagged : untagged
        return nil if candidates.empty?
        candidates.max_by { |_, content| content.strip.length }&.last
      end

      def extract_by_bracket_matching(text)
        start_idx = text.index(/[\[{]/)
        return nil unless start_idx

        opener = text[start_idx]
        closer = opener == "{" ? "}" : "]"
        depth = 0
        in_string = false
        i = start_idx

        while i < text.length
          char = text[i]

          if in_string
            if char == "\\" then i += 1 # skip escaped char
            elsif char == '"' then in_string = false
            end
          else
            case char
            when '"' then in_string = true
            when opener then depth += 1
            when closer
              depth -= 1
              return text[start_idx..i] if depth == 0
            end
          end

          i += 1
        end

        nil
      end

      def default_logger
        Logger.new($stdout, level: Logger::WARN)
      end
    end
  end
end

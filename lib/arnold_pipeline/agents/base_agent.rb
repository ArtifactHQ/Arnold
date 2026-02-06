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

      def parse_json(text)
        json_match = text.match(/```(?:json)?\s*\n?(.*?)\n?```/m)
        raw = json_match ? json_match[1] : text
        JSON.parse(raw)
      rescue JSON::ParserError => e
        logger.error { "JSON parse failed: #{e.message}" }
        raise
      end

      def default_logger
        Logger.new($stdout, level: Logger::WARN)
      end
    end
  end
end

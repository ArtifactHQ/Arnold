require "arnold_pipeline/agents/base_agent"
require "arnold_pipeline/prompts/concern_diff"

module ArnoldPipeline
  module Agents
    class ConcernDiffAnalyzer < BaseAgent
      def call(as_built_spec:, change_request:, concern_ids:)
        prompt = Prompts::ConcernDiff.analysis_prompt(
          as_built_spec:,
          change_request:,
          concern_ids:
        )

        result = chat_json(
          messages: [ { role: "user", content: prompt } ],
          schema: Prompts::ConcernDiff.schema
        )

        result
      end
    end
  end
end

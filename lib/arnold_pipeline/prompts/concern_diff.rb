module ArnoldPipeline
  module Prompts
    module ConcernDiff
      def self.analysis_prompt(as_built_spec:, change_request:, concern_ids:)
        concerns_list = concern_ids.map { |id| "  - #{id}" }.join("\n")

        <<~PROMPT
          You are analyzing how a change request would affect an existing codebase.

          ## Task: Concern Diff Analysis

          Given the as-built specification below and a change request, identify which
          concern areas need deeper analysis to understand the full impact of the change.

          ## As-Built Specification (Summary)
          #{as_built_spec[0, 8000]}

          ## Change Request
          #{change_request}

          ## Known Concern Areas
          #{concerns_list}

          ## Instructions

          For each concern area, determine if it needs deeper behavioral analysis to
          understand the impact of the change request. A concern needs deep analysis if:

          1. **modify**: The change directly modifies behavior in this concern
          2. **extend**: The change adds new capabilities to this concern
          3. **new**: The change introduces an entirely new concern not in the current spec

          Only include concerns that are actually affected. If the change is isolated to
          one or two concerns, only list those.

          Return a JSON object:
          ```json
          {
            "delta_concerns": [
              {
                "concern_id": "string",
                "delta_type": "modify|extend|new",
                "rationale": "Brief explanation of why this concern needs deep analysis"
              }
            ],
            "summary": "One-sentence summary of the change's scope"
          }
          ```
        PROMPT
      end

      def self.schema
        {
          name: "concern_diff_analysis",
          strict: true,
          schema: {
            type: "object",
            required: [ "delta_concerns", "summary" ],
            additionalProperties: false,
            properties: {
              delta_concerns: {
                type: "array",
                items: {
                  type: "object",
                  required: [ "concern_id", "delta_type", "rationale" ],
                  additionalProperties: false,
                  properties: {
                    concern_id: { type: "string" },
                    delta_type: { type: "string", enum: [ "modify", "extend", "new" ] },
                    rationale: { type: "string" }
                  }
                }
              },
              summary: { type: "string" }
            }
          }
        }
      end
    end
  end
end

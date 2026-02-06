module ArnoldPipeline
  module Prompts
    module Analysis
      def self.system_prompt(persona:)
        <<~PROMPT
          #{persona.system_prompt}

          You are analyzing code implementation results against a specification.
          Your job is to determine alignment and decide the next action.

          Decision Options:
          - "done" — Implementation aligns with the spec. No further changes needed.
          - "iterate_tasks" — Implementation has bugs or missing features that need code fixes.
            Provide corrective tasks.
          - "iterate_spec" — The specification is ambiguous or incomplete.
            Provide clarifications to add to the spec.

          Output Format:
          Return a JSON block fenced with ```json containing:
          {
            "decision": "done|iterate_tasks|iterate_spec",
            "confidence": 0-100,
            "reasoning": "Detailed explanation of your analysis",
            "corrective_data": {
              "tasks": [...], // if iterate_tasks (see task format below)
              "spec_changes": "..." // if iterate_spec: description of needed spec changes
            }
          }

          When decision is "iterate_tasks", each task in corrective_data.tasks must have:
          {
            "title": "Short descriptive title",
            "description": "Detailed description with acceptance criteria",
            "priority": 0,
            "labels": ["backend", "bugfix"],
            "depends_on": []
          }

          Confidence Guidelines:
          - 90-100: Strong alignment, minor or no issues
          - 70-89: Mostly aligned, some issues but manageable
          - 50-69: Significant gaps, needs attention (will be flagged for human review)
          - 0-49: Major misalignment, likely needs spec revision
        PROMPT
      end

      def self.user_prompt(spec_content:, diffs:, iteration_number:)
        <<~PROMPT
          Iteration #{iteration_number}: Analyze the following implementation against the spec.

          ## Specification
          #{spec_content}

          ## Code Diffs / Results
          #{diffs}

          Provide your analysis with decision, confidence score, and reasoning.
        PROMPT
      end
    end
  end
end

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

          # Completeness Tests

          Apply these three tests to the specification and implementation:

          1. NEW READER TEST — Could someone who has never spoken to the user read the spec and
             fully understand what exists, why it exists, how it behaves in normal and edge
             conditions, and how to know if it is working correctly?

          2. CODING AGENT TEST — Could a coding agent implement the spec without making
             assumptions about undefined behavior, guessing at data types, inventing UI elements
             not specified, or creating logic not documented?

          3. CHANGE REQUEST TEST — If someone wanted to change something, could they find where
             it is defined, understand what else would be affected, and trace the change through
             all connected sections?

          Score each test from 0-100. Include these scores in your output.

          # Anti-Pattern Detection

          Check the specification for these anti-patterns and report any found:

          - ORPHANED REFERENCE: A concept referenced but never defined elsewhere
          - CONTRADICTORY SPECIFICATION: Conflicting numbers, rules, or behaviors in different sections
          - VAGUE QUANTITY: Imprecise amounts like "more points" or "appears higher" without formulas
          - MISSING NEGATIVE: Features that describe what CAN happen but not limits, restrictions, or error states
          - LAZY IDEA DROP: Ideas mentioned casually without full treatment or explicit deferral
          - ASSUMED UNDERSTANDING: Phrases like "works as expected" or "standard flow"
          - TECHNICAL LEAK: Implementation details (SQL types, API formats) instead of behavioral descriptions

          # Output Format

          Return a JSON block fenced with ```json containing:
          {
            "decision": "done|iterate_tasks|iterate_spec",
            "confidence": 0-100,
            "reasoning": "Detailed explanation of your analysis",
            "completeness_scores": {
              "new_reader_test": 0-100,
              "coding_agent_test": 0-100,
              "change_request_test": 0-100
            },
            "anti_patterns_found": ["ORPHANED_REFERENCE: details...", ...],
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

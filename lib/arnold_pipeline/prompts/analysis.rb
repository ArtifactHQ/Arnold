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

          Task Results:
          Some tasks may not produce code diffs. Instead, the coding agent may post comments
          on the issue explaining why it could not produce a PR — missing dependencies,
          ambiguous requirements, no scaffolded app code, etc. When tasks have comments
          instead of diffs, factor this feedback into your decision:
          - If the agent's comments indicate blocked dependencies, use "iterate_tasks" to
            reorder or add prerequisite tasks.
          - If the agent's comments indicate ambiguous requirements, use "iterate_spec" to
            clarify the specification.
          - Failed tasks with explanatory comments are not necessarily a sign of spec problems;
            evaluate whether the issue is in task ordering, missing context, or spec gaps.

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

          Your response will be validated against a JSON schema. Return valid JSON matching this structure:
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
              "deltas": [...]  // if iterate_spec (see delta format below)
            },
            "requirement_coverage": [  // include when spec contains [REQ-*] IDs
              {"id": "REQ-AUTH-001", "status": "implemented|partial|missing|not_applicable", "notes": "..."}
            ]
          }

          When decision is "iterate_tasks", each task in corrective_data.tasks must have:
          {
            "title": "Short descriptive title",
            "description": "Detailed description with acceptance criteria",
            "priority": 0,
            "labels": ["backend", "bugfix"],
            "depends_on": []
          }

          When decision is "iterate_spec", corrective_data.deltas must be an array of
          structured deltas. Each delta targets a specific requirement in the spec:

          For ADDING a new requirement:
          {
            "operation": "added",
            "section": "Authentication",
            "content": "### Requirement: Password Reset\\nUsers SHALL be able to reset their password via email token.\\n\\n#### Scenario: Successful Reset\\n- GIVEN a registered user\\n- WHEN they request a password reset\\n- THEN a reset email is sent within 60 seconds",
            "rationale": "Missing feature identified during analysis"
          }

          For MODIFYING an existing requirement:
          {
            "operation": "modified",
            "section": "Authentication",
            "requirement": "User Login",
            "before_content": "### Requirement: User Login\\nUsers SHALL be able to authenticate with their credentials.",
            "after_content": "### Requirement: User Login\\nUsers SHALL be able to authenticate with email/password or OAuth2.\\n\\n#### Scenario: Successful Login\\n- GIVEN a registered user\\n- WHEN they submit valid credentials\\n- THEN they are authenticated\\n\\n#### Scenario: OAuth Login\\n- GIVEN a user with a Google account\\n- WHEN they click Login with Google\\n- THEN they are authenticated via OAuth",
            "rationale": "Spec was ambiguous about supported authentication methods"
          }

          For REMOVING a requirement:
          {
            "operation": "removed",
            "section": "Authentication",
            "requirement": "SMS Verification",
            "rationale": "Contradicts project scope defined in Overview"
          }

          Delta rules:
          - Each delta targets ONE requirement in ONE section
          - "content" (for added) and "after_content" (for modified) MUST use the
            `### Requirement:` / `#### Scenario:` / GIVEN-WHEN-THEN format
          - Each requirement in delta content MUST have at least one #### Scenario: block
          - "requirement" is required for modified and removed operations
          - "rationale" explains WHY the change is needed
          - Prefer surgical, targeted deltas over broad rewrites

          Confidence Guidelines:
          - 90-100: Strong alignment, minor or no issues
          - 70-89: Mostly aligned, some issues but manageable
          - 50-69: Significant gaps, needs attention (will be flagged for human review)
          - 0-49: Major misalignment, likely needs spec revision
        PROMPT
      end

      def self.user_prompt(spec_content:, diffs:, iteration_number:, comments: "")
        prompt = <<~PROMPT
          Iteration #{iteration_number}: Analyze the following implementation against the spec.

          ## Specification
          #{spec_content}

          ## Code Diffs / Results
          #{diffs}
        PROMPT

        if comments.present?
          prompt += <<~COMMENTS

            ## Task Comments / Agent Feedback
            #{comments}
          COMMENTS
        end

        prompt += "\nProvide your analysis with decision, confidence score, and reasoning.\n"
        prompt
      end
    end
  end
end

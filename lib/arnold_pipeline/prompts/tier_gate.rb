module ArnoldPipeline
  module Prompts
    module TierGate
      def self.system_prompt
        <<~PROMPT
          You are a tier gate reviewer for an automated code pipeline.
          After each tier of tasks is executed and merged, you evaluate whether the tier's
          output is sound enough for the next tier to build upon.

          Your job is to return a JSON assessment with:

          1. **pass** (boolean): true unless there are obvious, critical failures that would
             cause downstream tiers to fail. Be lenient — minor issues, style problems, or
             incomplete features are NOT grounds for failure. Only fail for broken builds,
             missing critical files, or fundamentally wrong implementations.

          2. **context_summary** (string): A 2-3 sentence summary of what was built/changed
             in this tier. This will be prepended to the next tier's task descriptions to give
             coding agents explicit context about what already exists.

          3. **issues** (array of strings): List of issues found, if any. Include even minor
             observations, but only set pass=false for critical ones.

          4. **corrective_tasks** (array): Only when pass=false. Minimal corrective tasks to
             fix the critical issues. Each task has "title", "description", and "labels".
             Keep corrections minimal — fix only what's broken, don't improve or refactor.

          Your response will be validated against a JSON schema. Return valid JSON matching this structure:
          {
            "pass": true|false,
            "issues": ["..."],
            "context_summary": "2-3 sentence summary of what was built",
            "corrective_tasks": [{"title": "...", "description": "...", "labels": [...]}]
          }

          Guidelines:
          - ALWAYS provide a context_summary, even when pass=true
          - pass=true is the default — only fail for critical, build-breaking issues
          - corrective_tasks should only appear when pass=false
          - Keep corrective tasks minimal and focused on the critical fix

          ## Handling Total Task Failures

          When a task is annotated with [FAILED - EMPTY DIFF]:
          - This means the coding agent ran but produced zero code changes
          - Create exactly ONE corrective task that replaces the failed task entirely
          - Do NOT decompose into multiple subtasks — the original scope was appropriate
          - Copy the original task's description and add context about the failure

          ## Acceptance Criteria Evaluation

          When acceptance criteria are provided for this tier's tasks, evaluate the diffs
          against each criterion specifically:
          - **Verified (programmatic)**: These criteria were already checked automatically.
            Treat them as confirmed facts — do not re-evaluate them.
          - **Failed (programmatic)**: These criteria failed automatic checks. Flag these as
            issues and create corrective tasks if critical.
          - **Unverified**: These criteria require your evaluation. Check the diffs to
            determine if each criterion is satisfied.

          Focus your evaluation on the specific acceptance criteria rather than making
          open-ended judgments about alignment.

          ## Empirical Verification Results

          When verification results are provided, they represent configurable checks
          (boot, test suite, custom commands) run after this tier's merge. Treat them
          as empirical evidence:
          - Each check reports PASSED or FAILED with its output
          - If all checks PASSED: the implementation satisfies its verification suite
          - If any check FAILED: evaluate whether the failure is critical based on the
            check type and output. Create corrective tasks targeting specific failures.
          - Required checks that fail are particularly important — they indicate
            fundamental issues that must be resolved.

          ## Spec-Scenario Test Progression

          When spec-scenario test results are provided, they represent independently
          generated integration tests derived from the specification's GIVEN/WHEN/THEN
          scenarios. These tests were written BEFORE implementation began and validate
          the behavioral contract:
          - Track how many spec tests now pass compared to the previous tier
          - "Newly passing" tests indicate forward progress on spec alignment
          - "Regressions" (previously passing tests that now fail) are critical issues —
            create corrective tasks to restore passing tests
          - A high spec-test pass rate is strong evidence of spec alignment
          - A low pass rate after late tiers may indicate fundamental implementation gaps

          ## Incremental Pipeline Awareness

          This pipeline may be running incrementally on a repository that already contains
          code from previous pipeline runs. When a "Repository Baseline" section is provided:
          - Files listed there ALREADY EXIST in the repository — they are NOT missing
          - Do NOT flag these files as missing from diffs — they were created by earlier runs
          - Only evaluate the CURRENT tier's diffs for correctness and completeness
          - A task that references an existing file (e.g., a migration, model, or config)
            does not need to recreate it — the file is already present in the repo
          - However, if a task's requirements imply existing files should have specific content
            (e.g., a migration should create specific columns), you MAY flag content mismatches
            if the task diffs indicate the existing files are insufficient for the current work
        PROMPT
      end

      def self.user_prompt(tier_number:, task_summaries:, diffs:, comments: "", repo_context: nil,
                           acceptance_criteria_summary: nil, verification_results: nil,
                           spec_test_progress_summary: nil)
        prompt = <<~PROMPT
          ## Tier #{tier_number} Gate Review

          ### Tasks Completed
          #{task_summaries}

          ### Code Diffs
          #{diffs}
        PROMPT

        if acceptance_criteria_summary.present?
          prompt += <<~CRITERIA

            ### Acceptance Criteria Results
            #{acceptance_criteria_summary}
          CRITERIA
        end

        if verification_results.present?
          prompt += <<~VERIFICATION

            ### Empirical Verification Results
            #{format_verification_results(verification_results)}
          VERIFICATION
        end

        if spec_test_progress_summary.present?
          prompt += <<~SPEC_TESTS

            ### Spec-Scenario Test Progression
            #{spec_test_progress_summary}
          SPEC_TESTS
        end

        if repo_context.present?
          prompt += <<~BASELINE

            ### Repository Baseline (files already in repo)
            These files exist in the repository before this tier ran. Do NOT flag them as missing.
            #{repo_context}
          BASELINE
        end

        if comments.present?
          prompt += <<~COMMENTS

            ### Task Comments / Agent Feedback
            #{comments}
          COMMENTS
        end

        prompt += "\nEvaluate this tier and provide your gate assessment.\n"
        prompt
      end

      def self.format_verification_results(results)
        return "No verification results available." unless results.is_a?(Hash)

        lines = []
        lines << "**Overall: #{results[:all_passed] ? 'ALL PASSED' : 'SOME FAILED'}**"
        lines << "Summary: #{results[:summary]}"

        checks = results[:checks] || []
        checks.each do |check|
          status = check[:success] ? "PASSED" : "FAILED"
          lines << ""
          lines << "- **#{check[:name]}** (#{check[:type]}): #{status}"
          unless check[:success]
            output = check[:stderr].to_s.strip
            output = check[:stdout].to_s.strip if output.empty?
            unless output.empty?
              # Cap failure output at 50 lines
              output_lines = output.lines.first(50).join
              lines << "  ```"
              lines << "  #{output_lines.strip}"
              lines << "  ```"
            end
          end
        end

        lines.join("\n")
      end
    end
  end
end

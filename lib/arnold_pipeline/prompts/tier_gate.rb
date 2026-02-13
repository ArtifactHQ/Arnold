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

      def self.user_prompt(tier_number:, task_summaries:, diffs:, comments: "", repo_context: nil)
        prompt = <<~PROMPT
          ## Tier #{tier_number} Gate Review

          ### Tasks Completed
          #{task_summaries}

          ### Code Diffs
          #{diffs}
        PROMPT

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
    end
  end
end

# Hook Auto-Commit & Merge Failure Distinction Design

**Goal:** Prevent post-merge hooks from leaving dirty files that block worktree merges, and give the analysis agent accurate failure reasons when merges fail.

**Root cause:** Pipeline #94 — "Regenerate schema" hook ran `db:prepare` which modified 4 schema files but only committed 1. The 3 dirty files blocked all subsequent worktree merges (28 of 37 tasks). The analysis agent was told "empty_diff" for all of them and generated wrong corrective tasks.

## Fix 1: Auto-commit dirty files after hooks

In `PostMergeHookRunner#run_hook`:
1. Before executing the hook command, snapshot dirty files via `git status --porcelain`
2. After `commit_derived_files` (which commits the user-listed `commit_paths`), check for newly dirty files
3. If any exist, auto-commit them with a descriptive message and log a warning

New method `auto_commit_remaining!(hook, pre_hook_dirty)`:
- Run `git status --porcelain` again to get post-hook dirty files
- Subtract the pre-hook set to find files dirtied by the hook
- If any remain: `git add` them, commit with `"Auto-commit files modified by hook '#{hook.name}'"`
- Log warning naming the unexpected files so users can fix their `commit_paths`

**Files:** `lib/arnold_pipeline/post_merge_hook_runner.rb`, test file

## Fix 2: Distinguish merge failures from empty diffs

In `TierExecutionEngine#task_failure_reason`:
- Check `result_comments` for `"Merge failed:"` prefix (already written by `claude_code.rb` merge rescue)
- Return `"merge_failed"` instead of `"empty_diff"` for these tasks
- This gives the analysis agent correct signal: the task was built but couldn't land

**Files:** `lib/arnold_pipeline/tier_execution_engine.rb`, test file

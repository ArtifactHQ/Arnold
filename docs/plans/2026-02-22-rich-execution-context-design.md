# Rich Execution Context for Claude Code Provider

**Date:** 2026-02-22
**Status:** Approved
**Motivation:** Pipeline runs #92 and #93 show that Claude Code tasks make wrong decisions because they lack awareness of the project's current state. Tasks reinvent existing models, create conflicting migrations, and corrective tasks thrash because they don't see actual test output.

## Problem

Each Claude Code task receives:
- A 9-line system prompt ("run tests, fix them, commit")
- A task title and description from the TaskBreaker
- Prior tier context (a text summary)
- A generic CLAUDE.md from the library recipe

This is insufficient. A task that says "add password reset" without showing the existing User model, routes, and mailer setup will reinvent things that already exist. A corrective task that says "fix test failures" without showing the actual test output will guess at the fix and often introduce new failures.

## Design

### 1. CLAUDE.md Enrichment (static project context, per-worktree)

`ClaudeMdGenerator` gains an optional `repo_path:` parameter. When present, it reads key files from the worktree and appends them to the generated CLAUDE.md.

**Files included:**

| File | Purpose | Truncation |
|------|---------|------------|
| `db/schema.rb` | What tables/columns exist | Strip boilerplate, keep `create_table` blocks |
| `config/routes.rb` | What endpoints exist | Full file |
| `Gemfile` | What libraries are available | Strip comments |

**Where called:** `write_claude_md!` in `claude_code.rb` already has `worktree_path`. The worktree is branched from master, so these files reflect the current merged state.

### 2. Corrective Task Prompt Enrichment (dynamic context, per-task)

`build_corrective_description` in `TierExecutionEngine` gains a `verification_output:` parameter. When present, it appends a `## Test Output` section with truncated stdout/stderr from the test suite verification check.

**Data flow:**

```
run_verification_checks()
  → verification_results[:checks] (includes stdout/stderr)
    → handle_tier_gate_failure!(... verification_results:)
      → build_corrective_description(... verification_output: extracted_output)
        → task.description includes actual test failures
          → Claude Code sees exact error messages
```

**Plumbing changes:**

1. `handle_tier_gate_failure!` receives `verification_results:` as a new keyword argument
2. `execute_tiers!` passes the verification results from line 99 into the gate failure handler at line 127
3. After retry verification at line 547, the retry results are used for the next loop iteration's corrective descriptions
4. `build_corrective_description` extracts the test suite check's stdout/stderr, truncates to last 3000 chars, and appends as `## Test Output`

### 3. Truncation Strategy

- **Schema:** Strip `ActiveRecord::Schema` wrapper, index definitions, and `enable_extension` lines. Keep `create_table` blocks only.
- **Routes:** Include full file (typically <50 lines for new apps).
- **Gemfile:** Strip comment lines and blank lines. Keep `gem` declarations.
- **Test output:** Last 3000 characters of combined stdout+stderr. Minitest/rspec print the failure summary at the bottom, so truncating from the top preserves the most useful information.

### 4. Files Changed

| File | Change |
|------|--------|
| `lib/arnold_pipeline/services/claude_md_generator.rb` | Add `repo_path:` param, read/truncate schema+routes+Gemfile, append as sections |
| `lib/arnold_pipeline/providers/execution/claude_code.rb` | Pass `worktree_path` to `ClaudeMdGenerator.call` |
| `lib/arnold_pipeline/tier_execution_engine.rb` | Pass `verification_results` into `handle_tier_gate_failure!`, thread through to `build_corrective_description` |
| Tests for all of the above | |

### 5. What This Doesn't Fix

- **Solid Queue `connects_to` issue** — spec generation prompt problem, not execution context
- **Analysis loop thrashing** — separate issue with how the analyzer generates corrective task descriptions
- **Iteration count** — should improve quality per iteration but doesn't change `max_iterations`

### 6. Expected Impact

Tasks that touch existing models/routes/tables will make correct decisions on the first try. Corrective tasks will fix actual failures instead of guessing. The password-reset thrashing pattern from run #93 (3 iterations of partial fixes) should resolve in 1 iteration when Claude Code can see the existing User model and the exact test errors.

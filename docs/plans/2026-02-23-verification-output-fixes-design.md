# Verification Output Pipeline Fixes Design

**Date:** 2026-02-23
**Spec Items:** SPEC-TIER-008, SPEC-VCHECK-007
**Problem:** Pipeline 99 tier 8 boot check failed across 8 retries — executor never received the actual error message

## Problem Statement

When a required verification check (boot, solid_stack) fails, three bugs conspire to hide the error from the execution agent:

1. `run_check` doesn't include `required:` in the result hash → `evaluate_with_verification`'s required-check-failure path is dead code → boot failures fall through to LLM judgment instead of triggering `build_boot_fix_task`
2. `tail_capture` keeps the last N chars of stderr → boot error exceptions (at the top) are truncated, leaving only a useless stack trace bottom
3. `extract_test_output` only extracts `:test_suite` check output → when boot fails and short-circuits verification, no output reaches the corrective task description

Pipeline 99 evidence: tier 8 boot check failed 8 times with `decision_source: llm_judgment` (should have been `verification_required_failed`). The LLM correctly inferred "boot check fails" from reading code, but the corrective task had no actual error message — so the executor couldn't fix the root cause.

## Root Causes

### Bug 1: Missing `required` flag in verification result

`verification_runner.rb:51-59` builds the result hash without `required:`. The tier engine at `tier_execution_engine.rb:299` checks `c[:required] && !c[:success]` — always nil because the key doesn't exist. The entire `verification_required_failed` decision path is dead code.

### Bug 2: tail_capture discards boot error messages

`verification_runner.rb:120-123` keeps the last `STDERR_CAP` (2000) characters. For boot errors, the exception class and message appear at the top of stderr, with the Ruby stack trace filling the rest. A 2000-char tail gets only the bottom of the stack trace — no actionable information.

### Bug 3: extract_test_output ignores non-test-suite checks

`tier_execution_engine.rb:1009-1013` filters for `c[:type] == :test_suite` only. When boot check fails and short-circuits the verification runner (line 26-29), no test_suite check exists in results. The corrective task description's `## Test Output` section is empty.

## Design

### Change 1: Add `required` to verification check result hash

Add `required: check.required?` to both the success and rescue result hashes in `run_check`. This unblocks the `evaluate_with_verification` required-check-failure path — boot failures will trigger `build_boot_fix_task` with `decision_source: "verification_required_failed"` and include the actual check output.

### Change 2: Smart stderr capture per check type

Add `head_and_tail_capture(output, cap)` method to VerificationRunner. It keeps the first `cap/2` chars (exception message) and last `cap/2` chars (recent context), joined with `\n...[truncated]...\n` when truncation occurs.

In `run_check`, choose capture strategy based on check type:
- `:test_suite` → `tail_capture` (failure summaries at bottom)
- All other types (`:boot`, `:solid_stack`, `:custom`) → `head_and_tail_capture` (exception at top)

Both stdout and stderr use the same strategy per check type. Cap constants unchanged (STDOUT_CAP=5000, STDERR_CAP=2000).

### Change 3: Broaden verification output extraction

Rename `extract_test_output` → `extract_verification_output`. Instead of filtering for `:test_suite` only, extract output from all failed checks. Format each check as a labeled section:

```
### Boot check (FAILED, exit code 1)
[stderr output]

### Test suite (FAILED, exit code 1)
[stdout+stderr output]
```

The corrective task description section header changes from `## Test Output` to `## Verification Output`. This flows through the existing `verification_output:` parameter in `build_corrective_description` — no structural changes needed.

## Files Changed

- `lib/arnold_pipeline/verification_runner.rb` — add `required:` to result, add `head_and_tail_capture`, smart capture selection
- `lib/arnold_pipeline/tier_execution_engine.rb` — rename `extract_test_output` → `extract_verification_output`, broaden to all failed checks, update section header
- `test/lib/arnold_pipeline/verification_runner_test.rb` — test head_and_tail_capture, test required flag propagation
- `test/lib/arnold_pipeline/tier_execution_engine_test.rb` — test extract_verification_output with boot failures, test required-check gate path

## What This Starts

- Boot failures trigger the `verification_required_failed` decision path with actual error output
- Corrective tasks include the actual exception message for boot/solid_stack failures
- Executor agents can read the error and fix the root cause instead of guessing

## What This Stops

- LLM judgment guessing about boot failures it can't see
- Useless stack trace bottoms in error output
- Empty verification output sections in corrective task descriptions
- Repeated blind retries where the executor has no actionable error information

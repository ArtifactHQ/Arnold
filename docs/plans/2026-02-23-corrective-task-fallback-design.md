# Corrective Task Fallback Design

**Date:** 2026-02-23
**Spec Items:** SPEC-TIER-008, SPEC-TIER-009
**Problem:** Pipeline 99 accumulates test failures across tiers with 0 corrective tasks generated

## Problem Statement

When the tier gate detects test failures (`decision_source: "verification_tests_failed"`), it calls `CorrectiveTaskGenerator` to create fix tasks. But when the test result parser can't extract individual failure blocks from the output, `test_result.failures` is empty and the generator returns `[]`. The tier execution engine then silently returns — skipping the retry loop entirely — and the pipeline proceeds to the next tier with unfixed test failures.

Pipeline 99 evidence:
- Tier 1: 14 errors, 0 assertions → 0 corrective tasks → proceeds
- Tier 2: 1 failure, 80 assertions → 0 corrective tasks → proceeds
- Tier 3: 2 failures, 124 assertions → 0 corrective tasks → proceeds
- Tier 4: 1 failure, 218 assertions → 0 corrective tasks → proceeds

## Root Causes

### Bug 1: Regex misses minitest error blocks
`extract_minitest_failures` regex expects `[path:line]:` location format. Minitest errors use a different format (colon after test name + stack trace). The regex silently returns `[]` for error blocks.

### Bug 2: OR instead of AND in early return
`corrective_task_generator.rb:85`: `return [] if @test_result.passed || @test_result.failures.empty?`
When tests failed (`passed == false`) but failures array is empty (parsing failed), the `||` short-circuits and returns `[]`.

### Bug 3: Silent return on empty corrective tasks
`tier_execution_engine.rb:563`: `return if created_tasks.empty?`
When no corrective tasks are generated, the handler silently returns instead of consuming a retry or pausing. The gate failure is swallowed.

## Design

### Change 1: Fix minitest error block extraction

Split `extract_minitest_failures` into two passes:
1. Failure blocks: existing regex for `Failure:` with `[path:line]` location
2. Error blocks: new regex for `Error:` with stack trace format

Error blocks look like:
```
  1) Error:
UsersControllerTest#test_should_get_index:
NameError: uninitialized constant UsersController
    app/controllers/users_controller.rb:1:in `<main>'
```

New extraction handles both formats and merges results.

### Change 2: Fallback generic corrective task

In `CorrectiveTaskGenerator#call`, when `test_result.failures.empty?` but `test_result.passed == false`, generate a single generic corrective task containing the raw test output summary:

```ruby
def call
  return [] if @test_result.passed

  if @test_result.failures.empty?
    return [generic_failure_task]
  end

  # ... existing categorized generation
end
```

The generic task includes the raw test output (truncated) so the execution agent can diagnose and fix the failures even without parsed structure.

### Change 3: Fix silent return in handle_tier_gate_failure!

Change `return if created_tasks.empty?` to `next if created_tasks.empty?`.

This makes empty corrective tasks consume a retry attempt and loop back to re-check. If all retries produce empty corrective tasks, the loop exhausts and pauses the pipeline — which is correct behavior (human review needed when the system can't self-heal).

### Change 4: Add has_issues? to TestResult

Add `has_issues?` method that returns true when tests didn't pass, regardless of whether individual failures were parsed. Used for clearer intent in conditional checks.

## Files Changed

- `lib/arnold_pipeline/test_execution/test_result_parser.rb` — fix error block regex
- `lib/arnold_pipeline/corrective_task_generator.rb` — fallback generic task
- `lib/arnold_pipeline/tier_execution_engine.rb` — fix silent return
- `lib/arnold_pipeline/test_execution/test_result.rb` — add `has_issues?`
- `test/lib/arnold_pipeline/test_execution/test_result_parser_test.rb` — error block tests
- `test/lib/arnold_pipeline/corrective_task_generator_test.rb` — fallback task tests
- `test/lib/arnold_pipeline/tier_execution_engine_test.rb` — retry loop tests

## What This Starts

- Corrective tasks fire on every test failure, even when parser can't extract details
- Pipeline pauses instead of silently proceeding when self-healing fails
- Error blocks (not just assertion failures) generate corrective tasks

## What This Stops

- Silent gate failure swallowing when corrective_tasks is empty
- Accumulated test failures across tiers without correction attempts
- Regex-dependent corrective task generation with no fallback

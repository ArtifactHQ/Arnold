# Implementation Plan: Post-Merge Hooks & Verification Checks

## Context

Pipeline run #53 produced a Rails 8 app with a 25% test failure rate (97 of 376 tests). Root causes:
- **RC1**: No test execution in tier gates — gate does static analysis only, never runs tests
- **RC2**: Schema drift from parallel worktree merges — `schema.rb` stale after branch merges (55 errors)
- **RC3**: Model deleted but tests/references not updated (19 errors)
- **RC4**: Wrong framework idioms — Sidekiq retry syntax used with Solid Queue (9 errors)
- **RC5**: Tests written before controller refactors (11 failures)

All five root causes would have been caught by running the test suite after merge. RC2 could have been prevented entirely by regenerating derived files post-merge.

## Design Principles

1. **Framework-agnostic** — No Rails-specific logic in the provider or engine
2. **Provider-native** — Claude Code provider runs checks locally; GitHub provider will consume CI results (future)
3. **Composable** — Individual checks are independent, ordered, and can short-circuit
4. **Non-fatal by default** — Hook/check failures produce structured results for the gate, not pipeline crashes
5. **Follows existing patterns** — Configuration via YAML/Ruby block, non-fatal rescue chains, PipelineEvent recording

## Architecture

```
Tier tasks execute → Branches merge → Post-merge hooks run (NEW) → Verification checks run (NEW) → Tier gate check (MODIFIED)
```

## Decision: Replace Existing Verification & Test Execution

This plan REPLACES the existing `Verification::*` and `TierExecutionEngine#run_verification!/run_test_execution!` with a configurable system. `TestExecution::*` module is kept (used by SpecTestProgressTracker).

### Removed:
- `lib/arnold_pipeline/verification/` directory (3 files)
- `TierExecutionEngine#run_verification!`, `#run_test_execution!`, `#verification_enabled?`, `#test_execution_enabled?`
- Config: `verification_enabled`, `verification_timeout`, `verification_health_check_retries`, `verification_health_check_interval`
- Config: `test_execution_enabled`, `test_command`, `test_boot_command`, `test_boot_timeout`

### Added:
- `PostMergeHook` + `PostMergeHookRunner` (prevention: fix derived files after merge)
- `VerificationCheck` + `VerificationRunner` (detection: run empirical checks)
- Config: `post_merge_hooks` (Array, default []), `verification_checks` (Array, default [])

### Kept:
- `TestExecution::*` module (used by SpecTestProgressTracker)
- `test_timeout` config (used by SpecTestProgressTracker)
- `SpecTestProgressTracker` and `spec_test_generation_enabled` features
- `CriteriaChecker` and `AcceptanceCriterion` features

## Implementation Steps

### Step 1: New Value Objects + Runners
- PostMergeHook, PostMergeHookRunner, VerificationCheck, VerificationRunner + tests

### Step 2: Configuration Changes
- Add `post_merge_hooks`, `verification_checks` attrs
- Remove old verification/test_execution attrs

### Step 3: Remove Old Code
- Delete Verification::* module and its tests
- Remove integration test references

### Step 4: TierExecutionEngine Integration
- Replace `run_verification!`/`run_test_execution!` with new methods
- Add `run_post_merge_hooks`/`run_verification_checks`

### Step 5: Tier Gate Updates
- Update prompt to receive verification_results (replaces verification_summary + test_execution_summary)
- Update agent to pass new parameter

### Step 6: Full Test Suite Validation

# CLI-Driven Spec Iteration Design

**Date:** 2026-02-17
**Status:** Approved
**Branch:** enable-iteration

## Problem

The pipeline is one-directional — users cannot intervene in the spec between runs. The OpenSpec infrastructure (delta merging, SpecRevisions, version tracking) exists but is not exposed as a user-initiated workflow.

## Solution

New CLI command `arnold iterate ID "change request"` that lets users refine specs via natural language, with changes applied through the existing delta merge chain.

```
arnold run "Build a chat app" --stop-after spec
arnold iterate 1 "Add typing indicators and read receipts"
arnold iterate 1 "Remove the admin dashboard"
arnold resume 1
```

## Resolved Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Agent strategy | Dedicated SpecIterationAgent | Different prompt needs than Analyzer |
| Task invalidation | `superseded` status (enum 4), visible with label | Audit trail + clean re-execution |
| Completed runs | Fork (new PipelineRun) | Keeps completed runs immutable |
| Fork input | Copy original NL input + metadata annotation | Preserves lineage context |
| Active runs | Block (pause first, then iterate) | Predictable blast radius |
| Analysis version skew | Suppress `iterate_spec` when spec advanced | User iteration takes priority |
| Multi-iteration | Each bumps version, resume uses latest | Natural SpecRevision behavior |
| Rate limiting | None | User controls cost |
| Batch from file | Deferred to v2 | Agent accepts string, trivial addition later |

## Implementation Phases

### Phase 1: Core Iteration Command
- New `SpecIterationAgent` + prompt template
- `arnold iterate` CLI command registration
- `Orchestrator#iterate_spec!` method
- `SpecRevision` support for `change_source: "user_iterate"`
- Pipeline event recording for user iterations

### Phase 2: Task Invalidation + Resume Awareness
- `superseded` status on Task model (enum value 4)
- `ResumeInferrer` handles all-superseded → `:break_tasks`
- `arnold tasks` displays `[superseded]` label

### Phase 3: Fork from Completed Run
- `Orchestrator#fork` method
- `forked_from_run_id` in PipelineRun metadata
- CLI triggers fork flow when run is completed

### Phase 4: Dry-Run and Interactive Confirmation
- `DeltaPresenter` for terminal-formatted delta display
- `--dry-run` flag shows proposed changes without applying
- `--json` output for deltas
- `--verbose` shows full before/after content

## Spec Items

- SPEC-CLI-ITERATE-001: Basic iteration
- SPEC-CLI-ITERATE-002: Dry run preview
- SPEC-CLI-ITERATE-003: Fork from completed
- SPEC-CLI-ITERATE-004: Multiple iterations before resume
- SPEC-CLI-ITERATE-005: Stale analysis after user iteration

# Agent Team Orchestration Guide

## Overview

This is a 5-agent review pipeline for evaluating a Ruby CLI spec-to-code workflow. The agents have strict ordering dependencies — follow the phases below.

## Quick Reference

```
Phase 1:  Agent 1 (Spec Analyst)           → produces spec-items.md
               │
Phase 2:  Agent 2 (Traceability Mapper)    → produces traceability-map.md
          Agent 3 (CLI Ergonomics Auditor)  → produces cli-ergonomics-audit.md
          Agent 4 (Architecture Reviewer)   → produces architecture-review.md
               │  (Phase 2 agents run in parallel — no dependencies between them)
               │
Phase 3:  Agent 5 (Reconciliation Lead)    → produces final-review.md
```

## Before You Start

Fill in the `## Context` section at the top of EACH agent prompt with your actual values:

```
- Repository root: /path/to/your/repo
- Spec location: /path/to/your/repo/docs/spec
- CLI entry point: exe/mytool
- Config files: .mytool.yml, config/defaults.yml
- Test suite location: spec/
```

## Running the Agents

### Phase 1 — Run Agent 1 alone
```
Paste agent-1-spec-analyst.md into a Claude Code session.
Wait for it to produce spec-items.md.
```

### Phase 2 — Run Agents 2, 3, 4 (in parallel or sequentially)

Each agent in Phase 2 reads `spec-items.md` but is otherwise independent. You can:

**Option A — Parallel (3 Claude Code sessions):**
Run Agents 2, 3, and 4 simultaneously in separate sessions. Each reads `spec-items.md` from Phase 1.

**Option B — Sequential (1 session):**
Run them one after another in the same session. This is simpler but slower.

```
Paste agent-2-traceability-mapper.md → wait for traceability-map.md
Paste agent-3-cli-ergonomics-auditor.md → wait for cli-ergonomics-audit.md
Paste agent-4-architecture-reviewer.md → wait for architecture-review.md
```

### Phase 3 — Run Agent 5 last
```
Ensure all 4 output files are present:
  - spec-items.md
  - traceability-map.md
  - cli-ergonomics-audit.md
  - architecture-review.md

Paste agent-5-reconciliation-lead.md into a Claude Code session.
Wait for it to produce final-review.md.
```

## Output Files

| File | Produced By | Contains |
|------|------------|---------|
| `spec-items.md` | Agent 1 | Canonical spec inventory, gaps, ambiguities |
| `traceability-map.md` | Agent 2 | Spec ↔ code ↔ test mapping matrix |
| `cli-ergonomics-audit.md` | Agent 3 | Hands-on CLI testing results and DX scores |
| `architecture-review.md` | Agent 4 | Code structure, quality, and test design analysis |
| `final-review.md` | Agent 5 | Executive summary, scorecard, recommendations, punch list |

## Tips

- **Start with Agent 1.** Its output quality determines everything downstream. If the spec inventory is wrong, every other agent's findings will be misaligned.
- **Re-run selectively.** If you fix spec issues and want to re-evaluate, you can re-run Agent 1 + Agent 2 without re-running Agents 3 and 4 (unless code changed too).
- **Use the punch list.** `final-review.md` ends with an assignable, PR-sized work list. Put it directly into your issue tracker.
- **Schedule regular re-runs.** Run the full pipeline after major features to catch drift early. Run Agents 3 and 5 after any CLI interface change.

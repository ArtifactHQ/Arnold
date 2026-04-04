# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Session Start Convention

When returning to a session after any break, run `/spec-recap` before starting
new work. This takes 30 seconds and prevents building on top of spec drift.

## Specification-Driven Development

This project follows spec-driven development. The source of truth for requirements is:
- `specification.md` — Primary requirements document (Given-When-Then scenarios)
- `README.md` — User-facing behavioral documentation

### Rules for ALL changes:

1. Before implementing any feature or fix, check if it's covered by an existing spec item.
   - If yes, reference the spec item in your plan and commit message.
   - If no, flag this as a spec gap and suggest whether to add a spec item or proceed without one.

2. Never implement behavior that contradicts `specification.md`. If the spec is wrong,
   say so and suggest a spec update — do not silently diverge.

3. When completing a feature, check if `specification.md` needs updating to reflect
   what was actually built. Use the spec-updater agent for this.

4. Commit messages should reference spec items: `fix(cli): guard --help flag [SPEC-CLI-001]`

### Spec Item ID Format:
SPEC-{DOMAIN}-{NNN} (e.g., SPEC-CONFIG-001, SPEC-CLI-003, SPEC-TIER-002)

Domains: PIPELINE, INPUT, SPECGEN, TASK, EXEC, ANALYSIS, TIER, WORKFLOW,
         RESUME, CONFIG, CLI, MODEL, GEM, JOB, PROVIDER, ERROR, OUTPUT, LIBRARY


## Project Overview

Arnold Pipeline is an agentic workflow system that transforms natural language descriptions of applications into executable code using AI agents. It operates in two modes:

1. **GitHub bypass mode:** Uses GitHub API directly — Issues as tasks, Actions/Copilot for execution, PRs for results. Toggled via CLI flag.

## Architecture

The pipeline flows through four core agents in sequence:

```
NL Input → Spec Generation Agent → Task Breakdown Agent → Execution (GitHub) → Analysis Agent → (iterate or done)
```

**Spec Generation Agent** — Accepts natural language input, retrieves matching personas and recipes from the library, produces a structured spec (Markdown/JSON) with features, tech stack, data models, user flows.

**Task Breakdown Agent** — Converts a structured spec into 5–20 granular tasks with title, description, priority, labels, and dependency ordering. Output format: JSON array.

**Analysis Agent** — Post-execution feedback loop. Compares code diffs against the spec using a QA Analyst persona. Decides `iterate_tasks` (implementation fixes) or `iterate_spec` (clarify ambiguities). Uses confidence scores (0–100%); flags low-confidence decisions (<70%) for human review. Configurable iteration limit (1-10, default 3).

**Library Manager** — Maintains agent personas (Software Architect, Domain Expert, General Analyst, QA Analyst) and application recipes (Web App, API Service, etc.) as YAML files. Supports keyword-based retrieval from YAML files. Falls back to a generic persona on mismatch.

## Key Design Constraints

- Tasks MUST be ordered by dependencies (e.g., database setup before API endpoints)
- The feedback loop MUST terminate after the configured max iterations (1-10, default 3)
- The system should default to a generic persona when library retrieval fails
- Bypass mode uses GitHub API polling for PR/issue events in the feedback loop
- Implementation language: Ruby 4+ / Rails 8+

## Technology Stack

- **Ruby 4+** and **Rails 8+**
- Prefer Rails generators and built-in commands (`rails generate`, `rails db:migrate`, `rails routes`, etc.) over hand-written boilerplate

## Development Guidelines

- Follow Rails conventions and paradigms: convention over configuration, RESTful resources, ActiveRecord patterns, concerns, and service objects where appropriate
- Use Rails CLI commands and generators before writing custom code
- Follow Rails best practices for routing, controllers, models, views, jobs, mailers, and migrations

## Testing

- Create tests for all new features
- Run the full test suite after changes to ensure nothing is broken

## Current Status

Active development. The pipeline is fully implemented with:
- 13 CLI commands (run, resume, iterate, analyze, setup, status, list, spec, tasks, log, mcp, doctor, version)
- 2063 tests (Minitest, 6743 assertions, 0 failures)
- Anthropic and OpenAI LLM providers
- GitHub and Claude Code execution providers with tiered task management
- Tier gate checking with context propagation and baseline awareness
- Workflow status monitoring
- Pause/resume with stage checkpoints
- Configurable iteration limits (1-10, default 3)
- Brownfield codebase analysis (stack detection, feature extraction, as-built spec)
- MCP server for Claude Code plugin integration
- Drift detection and resolution

<!-- gitnexus:start -->
# GitNexus — Code Intelligence

This project is indexed by GitNexus as **Arnold** (464 symbols, 447 relationships, 0 execution flows). Use the GitNexus MCP tools to understand code, assess impact, and navigate safely.

> If any GitNexus tool warns the index is stale, run `npx gitnexus analyze` in terminal first.

## Always Do

- **MUST run impact analysis before editing any symbol.** Before modifying a function, class, or method, run `gitnexus_impact({target: "symbolName", direction: "upstream"})` and report the blast radius (direct callers, affected processes, risk level) to the user.
- **MUST run `gitnexus_detect_changes()` before committing** to verify your changes only affect expected symbols and execution flows.
- **MUST warn the user** if impact analysis returns HIGH or CRITICAL risk before proceeding with edits.
- When exploring unfamiliar code, use `gitnexus_query({query: "concept"})` to find execution flows instead of grepping. It returns process-grouped results ranked by relevance.
- When you need full context on a specific symbol — callers, callees, which execution flows it participates in — use `gitnexus_context({name: "symbolName"})`.

## When Debugging

1. `gitnexus_query({query: "<error or symptom>"})` — find execution flows related to the issue
2. `gitnexus_context({name: "<suspect function>"})` — see all callers, callees, and process participation
3. `READ gitnexus://repo/Arnold/process/{processName}` — trace the full execution flow step by step
4. For regressions: `gitnexus_detect_changes({scope: "compare", base_ref: "main"})` — see what your branch changed

## When Refactoring

- **Renaming**: MUST use `gitnexus_rename({symbol_name: "old", new_name: "new", dry_run: true})` first. Review the preview — graph edits are safe, text_search edits need manual review. Then run with `dry_run: false`.
- **Extracting/Splitting**: MUST run `gitnexus_context({name: "target"})` to see all incoming/outgoing refs, then `gitnexus_impact({target: "target", direction: "upstream"})` to find all external callers before moving code.
- After any refactor: run `gitnexus_detect_changes({scope: "all"})` to verify only expected files changed.

## Never Do

- NEVER edit a function, class, or method without first running `gitnexus_impact` on it.
- NEVER ignore HIGH or CRITICAL risk warnings from impact analysis.
- NEVER rename symbols with find-and-replace — use `gitnexus_rename` which understands the call graph.
- NEVER commit changes without running `gitnexus_detect_changes()` to check affected scope.

## Tools Quick Reference

| Tool | When to use | Command |
|------|-------------|---------|
| `query` | Find code by concept | `gitnexus_query({query: "auth validation"})` |
| `context` | 360-degree view of one symbol | `gitnexus_context({name: "validateUser"})` |
| `impact` | Blast radius before editing | `gitnexus_impact({target: "X", direction: "upstream"})` |
| `detect_changes` | Pre-commit scope check | `gitnexus_detect_changes({scope: "staged"})` |
| `rename` | Safe multi-file rename | `gitnexus_rename({symbol_name: "old", new_name: "new", dry_run: true})` |
| `cypher` | Custom graph queries | `gitnexus_cypher({query: "MATCH ..."})` |

## Impact Risk Levels

| Depth | Meaning | Action |
|-------|---------|--------|
| d=1 | WILL BREAK — direct callers/importers | MUST update these |
| d=2 | LIKELY AFFECTED — indirect deps | Should test |
| d=3 | MAY NEED TESTING — transitive | Test if critical path |

## Resources

| Resource | Use for |
|----------|---------|
| `gitnexus://repo/Arnold/context` | Codebase overview, check index freshness |
| `gitnexus://repo/Arnold/clusters` | All functional areas |
| `gitnexus://repo/Arnold/processes` | All execution flows |
| `gitnexus://repo/Arnold/process/{name}` | Step-by-step execution trace |

## Self-Check Before Finishing

Before completing any code modification task, verify:
1. `gitnexus_impact` was run for all modified symbols
2. No HIGH/CRITICAL risk warnings were ignored
3. `gitnexus_detect_changes()` confirms changes match expected scope
4. All d=1 (WILL BREAK) dependents were updated

## CLI

- Re-index: `npx gitnexus analyze`
- Check freshness: `npx gitnexus status`
- Generate docs: `npx gitnexus wiki`

<!-- gitnexus:end -->

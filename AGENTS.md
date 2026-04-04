# AGENTS.md

Instructions in this file apply to the entire repository.

## Project Context

- Arnold Pipeline is a Ruby gem that orchestrates AI coding agents through a multi-stage workflow.
- Treat `specification.md` as the source of truth for product behavior and `README.md` as the user-facing contract.
- Before implementing a feature or fix, check whether the behavior is already covered in `specification.md`.
- If a requested change is not covered by the spec, call it out as a spec gap instead of silently inventing behavior.
- Do not intentionally implement behavior that contradicts `specification.md`; propose a spec update first.

## Stack And Architecture

- Primary stack: Ruby and Rails.
- Prefer Rails conventions, built-in commands, and generators over handwritten boilerplate.
- Follow existing service-object and stateless-agent patterns already used in the codebase.
- Keep changes focused and minimal; avoid incidental refactors unless they are required for correctness.

## Workflow Expectations

- Check for existing repository guidance before making changes, especially `CLAUDE.md`, `CONTRIBUTING.md`, and relevant docs under `docs/`.
- One logical change at a time; do not bundle unrelated fixes.
- Do not add new gem dependencies unless the change has already been discussed and approved.
- When behavior changes, update documentation or specs if needed so the repo stays internally consistent.

## Testing And Validation

- Add or update tests for any behavior change or bug fix.
- Run the most specific test(s) that cover the change first, then run the full suite when practical.
- Primary validation commands:
  - `bundle exec rails test`
  - `bin/rubocop`
- The test suite expects SQLite3 to be available.

## Test Conventions

- Use `mocha/minitest` for stubs and mocks instead of `minitest/mock`.
- Use `WebMock` for external HTTP stubs.
- Use `ActiveJob::TestCase` for job tests.
- If a test mutates Arnold configuration, reset it in teardown with `ArnoldPipeline.reset_configuration!`.
- Stub stateless agents at their boundaries rather than mocking internal implementation details.

## Change Guardrails

- Preserve spec-driven development conventions, including spec item references when the surrounding workflow requires them.
- Keep commit messages conventional if the user asks you to prepare one.
- Do not overwrite or revert unrelated user changes.

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

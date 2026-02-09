# Ruby CLI Developer Experience & Spec-to-Code Review Framework

## Part 1: Critical Developer Experience Features

### Configuration Hierarchy (Most → Least Specific)
The gold standard is a layered config system where every setting can be overridden at each level:

1. **Inline flags/arguments** — highest priority, immediate intent
2. **Environment variables** — session/CI-level overrides (`MYTOOL_LOG_LEVEL=debug`)
3. **Project-local config** — `.mytool.yml` or `mytool.config.rb` in the repo root
4. **User-level config** — `~/.config/mytool/config.yml` (XDG Base Directory compliant)
5. **System/global defaults** — sensible built-in defaults that make the tool work with zero config

Every option should be settable at *every* layer. No "flag-only" or "file-only" settings.

### Output & Interaction Ergonomics

- **Structured output by default**: Support `--format json`, `--format yaml`, `--format table`, and `--format plain`. Default to human-readable; switch to machine-readable when stdout is piped (`$stdout.tty?`).
- **Verbosity levels**: `--quiet` (errors only), default (key results), `--verbose` (details), `--debug` (trace-level). Use `$stderr` for diagnostic output, `$stdout` for data.
- **Color**: Auto-detect terminal support. Respect `NO_COLOR` env var (https://no-color.org). Provide `--color=always|auto|never`.
- **Progress indicators**: Show progress on `$stderr` for long operations, suppress automatically when not a TTY.
- **Exit codes**: `0` success, `1` general error, `2` usage/argument error, custom codes for domain-specific failures. Document them.
- **Dry-run mode**: `--dry-run` / `--noop` for any destructive or side-effecting command.

### Ruby CLI Architecture Best Practices

- **Use Thor or GLI** for subcommand-based CLIs; **OptionParser** for simpler single-purpose tools.
- **Separate concerns**: CLI layer (parsing, I/O) → Service layer (business logic) → Data layer. The service layer should be usable as a Ruby library, not just via CLI.
- **Gemfile-free execution**: Support both `gem install` and `bundle exec` workflows. Provide a standalone executable in `exe/` or `bin/`.
- **Shell completions**: Ship bash/zsh/fish completions or generate them (`mytool completions --shell zsh`).
- **Init/scaffold command**: `mytool init` to generate config files with commented defaults.
- **Idempotency**: Commands should be safe to re-run. State changes should be convergent, not additive.
- **Fail fast, fail clearly**: Validate all inputs before doing work. Error messages should state what went wrong, why, and what to do about it.

### Flexibility Maximizers

- **Plugin/extension architecture**: Allow users to add commands or transforms via a plugin directory or gem convention (`mytool-plugin-*`).
- **Hooks**: `before_*` / `after_*` hooks for key lifecycle events, configurable in the project config.
- **Stdin/Stdout piping**: Every command that reads a file should also accept `-` for stdin. Every command that outputs data should be pipeable.
- **Template/override system**: Allow users to override built-in templates by placing files in a local `.mytool/templates/` directory.

---

## Part 2: Spec Lifecycle — Analyze, Enhance, Organize, Reconcile

### Analysis Phase
- **Decompose** the spec into atomic, independently testable units (features, behaviors, constraints).
- **Identify ambiguities** — anything that requires interpretation is a spec gap. Flag it explicitly.
- **Map dependencies** — which spec items depend on others? Build a directed graph.
- **Classify** each item: functional requirement, non-functional requirement, constraint, assumption, open question.

### Enhancement Phase
- **Add acceptance criteria** to every functional requirement (Given/When/Then or input→output pairs).
- **Define edge cases and error states** explicitly — specs that only describe the happy path are incomplete.
- **Add priority/effort estimates** to enable tradeoff conversations.
- **Cross-reference** with existing codebase patterns — if the project already does X a certain way, the spec should acknowledge or explicitly diverge.

### Organization
- **Hierarchical structure**: Domain → Feature → Behavior → Acceptance Criteria.
- **Traceability matrix**: Every spec item gets an ID. Every implementation artifact (class, method, test) maps back to a spec ID.
- **Living document**: The spec is versioned alongside the code. Spec changes require the same review rigor as code changes.

### Reconciliation (Post-Implementation)
- **Spec-to-code diff**: Walk each spec item and verify it has corresponding implementation AND tests.
- **Code-to-spec diff**: Walk the implementation and flag any behavior not covered by the spec (accidental features, scope creep, emergent complexity).
- **Drift detection**: Automate checks that spec and implementation remain in sync — this can be as simple as a checklist in CI or as rich as spec-linked test annotations.
- **Retrospective update**: After implementation, update the spec to reflect what was *actually* built, including deliberate deviations and their rationale.

---

## Part 3: Claude Code Team Review Prompt

Copy the prompt below and use it with your Claude Code team to evaluate your workflow.

---

```markdown
# PROMPT: Evaluate and Review Spec-to-Code Ruby CLI Workflow

You are a senior Ruby CLI architect and developer experience specialist. Your job is to perform a thorough review of my spec-to-code workflow for a Ruby CLI tool. Evaluate each dimension below independently, provide specific findings, and score each area.

## Context to Provide
<!-- Fill these in before running the review -->
- **Repository root**: [path or URL]
- **Spec location**: [path to spec files/docs]
- **CLI entry point**: [e.g., exe/mytool or bin/mytool]
- **Config files**: [list any .yml, .rb, or other config files]
- **Test suite location**: [spec/ or test/]

## Review Dimensions

### 1. Spec Quality & Completeness
- Read the spec documents thoroughly.
- For each feature/behavior described, assess:
  - Is it unambiguous? Could two developers implement it differently from the same spec?
  - Does it have explicit acceptance criteria?
  - Are edge cases and error states defined?
  - Are non-functional requirements (performance, security, concurrency) addressed?
- List every ambiguity, gap, or implicit assumption you find.
- Rate: **Completeness (1-5)**, **Clarity (1-5)**, **Testability (1-5)**

### 2. Spec-to-Code Traceability
- For each spec item, locate the corresponding implementation code and test(s).
- Flag any spec items with NO corresponding implementation.
- Flag any spec items with implementation but NO test coverage.
- Flag any significant code behavior NOT described in the spec.
- Produce a traceability summary table:
  | Spec Item | Implementation File(s) | Test File(s) | Status |
  |-----------|----------------------|--------------|--------|
- Rate: **Coverage (1-5)**, **Alignment (1-5)**

### 3. CLI Ergonomics & Developer Experience
Evaluate the CLI against these criteria:
- **Configuration layering**: Does it support flags → env vars → project config → user config → defaults? Can every option be set at every layer?
- **Output modes**: Does it support structured output (JSON/YAML/table)? Does it auto-detect TTY?
- **Verbosity**: Are there quiet/verbose/debug levels? Is diagnostic output on stderr?
- **Color**: Does it respect NO_COLOR? Is there a --color flag?
- **Exit codes**: Are they meaningful, documented, and consistent?
- **Dry-run**: Is there a --dry-run/--noop for destructive operations?
- **Error messages**: Do they explain what, why, and how to fix?
- **Help text**: Is `--help` comprehensive? Do subcommands have their own help?
- **Shell completions**: Are they provided or generatable?
- **Piping**: Can commands read from stdin and write clean output to stdout?
- **Idempotency**: Are commands safe to re-run?
- Rate: **Discoverability (1-5)**, **Flexibility (1-5)**, **Robustness (1-5)**

### 4. Code Architecture & Separation of Concerns
- Is the CLI layer (argument parsing, I/O) cleanly separated from business logic?
- Could the core logic be used as a Ruby library without the CLI?
- Is there a plugin or extension mechanism?
- Are there lifecycle hooks?
- Is the code organized by domain rather than by technical layer?
- Rate: **Modularity (1-5)**, **Extensibility (1-5)**

### 5. Test Suite Quality
- Do tests cover happy paths, edge cases, and error states?
- Are there integration tests that exercise the CLI end-to-end (invoke the binary, check stdout/stderr/exit code)?
- Are tests deterministic and isolated?
- Is there a clear mapping from tests back to spec items?
- Rate: **Coverage (1-5)**, **Spec Alignment (1-5)**

### 6. Spec Drift & Reconciliation
- Identify any areas where the implementation has diverged from the spec.
- For each divergence, classify: intentional improvement, accidental drift, or spec was updated but code wasn't (or vice versa).
- Recommend a reconciliation action for each.
- Rate: **Sync (1-5)**

## Deliverables

1. **Executive Summary** — 3-5 sentences on the overall health of the workflow.
2. **Findings Table** — Every issue found, categorized by dimension, with severity (Critical / Major / Minor / Suggestion).
3. **Scorecard** — All ratings from above in a summary table.
4. **Top 5 Recommendations** — Prioritized, actionable improvements with the highest impact on developer experience and spec-code alignment.
5. **Reconciliation Punch List** — Specific spec items to update, tests to add, or code to refactor to bring everything into alignment.

Be direct. Cite specific files and line numbers. Prioritize findings that would cause real developer friction or spec-code divergence over stylistic preferences.
```

---

*Use this prompt by pasting it into your Claude Code session, filling in the Context section, and pointing it at your repository. Re-run it after major feature work to catch drift early.*

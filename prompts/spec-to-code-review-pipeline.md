Create an agent team to complete the following:

# Spec-to-Code Review: Orchestrated Agent Pipeline

You are the **Orchestrator** for a 5-agent review pipeline that evaluates a Ruby CLI tool's spec-to-code workflow. You will execute each agent role sequentially, carrying forward outputs as context for downstream agents. Do not skip agents or phases. Do not summarize prematurely — complete each agent's full analysis before moving to the next.

## Context
- **Repository root**: /home/kyle/Documents/Projects/artifact/arnold_pipeline
- **Spec location**: The initial spec for the workflow is in the project root. The code that used by this workflow to generate specs is here: /home/kyle/Documents/Projects/artifact/arnold_pipeline/lib/arnold_pipeline/prompts
- **CLI entry point**: bundle exec exe/arnold 
- **Config files**: Either in the root of the project or standard Rails locations
- **Test suite location**: test/

## Execution Plan

```
Phase 1:  Agent 1 (Spec Analyst)           → produces SPEC-ITEMS section
               │
Phase 2:  Agent 2 (Traceability Mapper)    → produces TRACEABILITY-MAP section
          Agent 3 (CLI Ergonomics Auditor)  → produces CLI-ERGONOMICS section
          Agent 4 (Architecture Reviewer)   → produces ARCHITECTURE-REVIEW section
               │
Phase 3:  Agent 5 (Reconciliation Lead)    → produces FINAL-REVIEW section
```

Execute each agent in order. After completing each agent, write its output under the corresponding `## Agent N` heading. Phase 2 agents (2, 3, 4) depend only on Agent 1's output — not on each other — so execute them in numeric order. Agent 5 depends on ALL prior agents.

---

## Phase 1

## Agent 1: Spec Analyst

**Role:** Senior requirements engineer. You are the foundation — every downstream agent depends on your output.

### Instructions

1. **Discover all spec documents.** List every file that functions as a spec, requirements doc, README with behavioral descriptions, or ADR. Read each one completely.

2. **Decompose into atomic spec items.** For each distinct requirement, behavior, constraint, or rule, create an entry with a unique ID:
   ```
   SPEC-{DOMAIN}-{NNN}   (e.g., SPEC-CONFIG-001, SPEC-OUTPUT-012)
   ```

3. **Classify each item** using this schema:

   | Field | Value |
   |-------|-------|
   | **ID** | Unique identifier |
   | **Source** | File path and line number(s) |
   | **Type** | `functional` / `non-functional` / `constraint` / `assumption` / `open-question` |
   | **Summary** | One-sentence description |
   | **Acceptance Criteria** | Copy from spec if present, otherwise write `MISSING` |
   | **Edge Cases Defined?** | Yes / No / Partial — list gaps |
   | **Error States Defined?** | Yes / No / Partial — list gaps |
   | **Dependencies** | IDs of other spec items this depends on |
   | **Ambiguity Flag** | `Clear` / `Ambiguous` — if ambiguous, state two conflicting interpretations |

4. **Build the dependency graph.** List relationships (`SPEC-X → SPEC-Y (reason)`). Flag circular dependencies.

5. **Identify gaps.** Produce dedicated lists for:
   - **Ambiguities** — quote the ambiguous text, give two interpretations, recommend resolution
   - **Missing requirements** — areas the spec should cover but doesn't (invalid input handling, config conflicts, signal handling, partial failure, concurrency, backward compatibility, logging)
   - **Implicit assumptions** — unstated things the spec assumes; assess whether each is safe

6. **Score spec quality:**

   | Dimension | Score (1-5) | Justification |
   |-----------|-------------|---------------|
   | Completeness | | |
   | Clarity | | |
   | Testability | | |
   | Internal Consistency | | |
   | Organization | | |

### Output
Write the complete spec items table, dependency graph, gaps report, and scorecard under this agent's section. Title it `## SPEC-ITEMS`. All subsequent agents will reference these IDs.

---

## Phase 2

## Agent 2: Traceability Mapper

**Role:** Senior Ruby engineer specializing in requirements traceability. You map every spec item to code and tests.

**Prerequisite:** Read the SPEC-ITEMS section from Agent 1 in full before starting.

### Instructions

1. **Forward trace: Spec → Code.** For each spec item ID, locate implementing code. Record file path(s) and line ranges. Assess:
   - `Full` — completely implemented
   - `Partial` — describe what's missing
   - `None` — no implementation found

2. **Forward trace: Spec → Tests.** For each spec item ID, locate covering tests. Record file/test name. Assess:
   - `Full` — happy path + edge cases + error states tested
   - `Happy Path Only` — only success case
   - `Partial` — list untested scenarios
   - `None` — no tests

3. **Reverse trace: Code → Spec.** Walk the codebase for significant behaviors not backed by any spec item. For each, record:
   - File and line
   - Behavior description
   - Classification: `undocumented feature` / `implementation detail` / `scope creep` / `defensive code` / `dead code`
   - Recommendation: add to spec / remove / leave as-is

4. **Reverse trace: Tests → Spec.** Identify tests that don't map to any spec item. Classify: implementation detail test, undocumented behavior test, or regression test.

5. **Build the traceability matrix:**

   | Spec ID | Summary | Impl File(s) | Impl Status | Test File(s) | Test Coverage | Notes |
   |---------|---------|--------------|-------------|--------------|---------------|-------|

6. **Compute coverage stats:**
   ```
   Total Spec Items:        NN
   Fully Implemented:       NN (NN%)
   Partially Implemented:   NN (NN%)
   Not Implemented:         NN (NN%)
   Fully Tested:            NN (NN%)
   Not Tested:              NN (NN%)
   Orphan Behaviors:        NN
   Orphan Tests:            NN
   ```

7. **Score:**

   | Dimension | Score (1-5) | Justification |
   |-----------|-------------|---------------|
   | Spec-to-Code Coverage | | |
   | Spec-to-Test Coverage | | |
   | Code-to-Spec Alignment | | |

### Output
Write everything under `## TRACEABILITY-MAP`. Highlight a **Critical Gaps** list: spec items with neither implementation nor tests.

---

## Agent 3: CLI Ergonomics Auditor

**Role:** Developer experience specialist. You test the CLI hands-on and evaluate every interaction surface.

**Prerequisite:** Read the SPEC-ITEMS section from Agent 1 for context. Your evaluation is independent.

### Instructions

Systematically test each area below. **Run every command.** Record exact commands and observed output. Do not infer from code alone.

1. **First Contact** — Run with no args, `--help`, `--version`, misspelled subcommand, subcommand `--help`. Is there an `init` command?

2. **Configuration Layering** — Test all 5 layers and their override behavior:
   - Defaults (zero-config behavior)
   - User config (`~/.config/`, XDG compliance)
   - Project config (local `.mytool.yml` or equivalent, search strategy)
   - Environment variables (`MYTOOL_*`, documented?)
   - CLI flags (override all?)
   - Set conflicting values across layers. Does priority resolve correctly? Is it documented?

3. **Output & Formatting:**
   - `--format json` / `--format yaml` / `--format table` support?
   - TTY auto-detection (`cmd` vs `cmd | cat`)?
   - `--quiet`, `--verbose`, `--debug` levels?
   - Diagnostic on stderr, data on stdout?
   - `NO_COLOR=1` respected? `--color=always|auto|never`?
   - Progress indicators on stderr?

4. **Error Handling:**
   - Exit codes: `0` success, non-zero failure, different codes for different failures? Documented?
   - Error messages: what / why / how-to-fix? On stderr? No raw stack traces?
   - Input validation: fail-fast or partial-work-then-fail?

5. **Safety:**
   - `--dry-run` / `--noop` for destructive ops?
   - Idempotency: run a state-changing command twice — safe?
   - Confirmation prompts for destructive ops? `--force` / `--yes` to skip?

6. **Composability:**
   - Stdin reading (`echo "x" | mytool process` or `mytool process -`)?
   - Clean stdout for piping?
   - File args and stdin interchangeable?

7. **Discoverability:**
   - Shell completions (bash/zsh/fish)?
   - Inline examples in `--help`?
   - Config reference with types and defaults?

8. **Score:**

   | Dimension | Score (1-5) | Justification |
   |-----------|-------------|---------------|
   | First Contact | | |
   | Discoverability | | |
   | Configuration Flexibility | | |
   | Output Control | | |
   | Error Experience | | |
   | Safety | | |
   | Composability | | |
   | Documentation | | |

### Output
Write everything under `## CLI-ERGONOMICS`. Include an **Issues List** (severity: Critical/Major/Minor/Suggestion) and a **Quick Wins** section (easy fixes, high DX impact).

---

## Agent 4: Architecture & Code Quality Reviewer

**Role:** Senior Ruby architect evaluating internal structure, maintainability, and test design.

**Prerequisite:** Read the SPEC-ITEMS section from Agent 1 for context.

### Instructions

1. **Map the architecture.** Produce a text or mermaid diagram showing: entry point → command routing → service/business logic → data/IO layer → configuration system → plugin/extension points. Identify the CLI framework (Thor, GLI, OptionParser, custom).

2. **Separation of concerns:**
   - CLI parsing separated from business logic?
   - Core logic usable as a Ruby library without the CLI?
   - Methods that parse args AND do domain work? (violations)
   - Business logic containing `puts` or other I/O? (violations)
   - Dependency direction: CLI → Service → Data? Circular deps?

3. **Extensibility:**
   - Plugin architecture? (gem-based, directory-based, hook-based)
   - Custom commands, output formats, validators addable without modifying core?
   - Before/after hooks for key operations?
   - Template/override system?
   - Config schema extensible by plugins?

4. **Code quality:**
   - Idiomatic Ruby? Anti-patterns? (monkey-patching, excess metaprogramming, stringly-typed logic)
   - Custom exception hierarchy?
   - Bare `rescue` or `rescue Exception`?
   - Thread safety if parallel work exists?
   - Gemfile/gemspec reasonable? Versions constrained?
   - Classes >200 lines, methods >30 lines? (extraction candidates)

5. **Test suite design:**
   - Framework (RSpec/Minitest)?
   - Unit tests (isolated business logic)?
   - Integration tests (invoke binary, check stdout/stderr/exit code)?
   - Deterministic and isolated? Proper temp file cleanup?
   - Test descriptions readable as specs?

6. **Maintainability:**
   - CONTRIBUTING.md or setup guide?
   - `bundle install && bundle exec rake` works?
   - How many files to touch to add a new command?
   - Clear pattern for adding features?

7. **Score:**

   | Dimension | Score (1-5) | Justification |
   |-----------|-------------|---------------|
   | Separation of Concerns | | |
   | Extensibility | | |
   | Code Quality | | |
   | Test Design | | |
   | Maintainability | | |
   | Modularity | | |

### Output
Write everything under `## ARCHITECTURE-REVIEW`. Include an **Issues List** and a **Refactoring Candidates** section (specific classes/methods, rationale, suggested approach).

---

## Phase 3

## Agent 5: Reconciliation Lead

**Role:** Senior engineering lead who synthesizes all findings into the final deliverables. You are the decision-maker.

**Prerequisite:** Read ALL four prior agent sections (SPEC-ITEMS, TRACEABILITY-MAP, CLI-ERGONOMICS, ARCHITECTURE-REVIEW) completely before writing anything.

### Instructions

1. **Deduplicate and reconcile.** Build a master issues list. Assign canonical IDs (`ISSUE-NNN`). If agents conflict on severity, make a judgment call and explain. Merge findings with the same root cause.

2. **Classify every spec-code divergence:**

   | Type | Description | Action |
   |------|-------------|--------|
   | Intentional Improvement | Code is better than spec | Update spec to match code |
   | Accidental Drift | Unintentional divergence | Fix code or update spec |
   | Stale Spec | Spec updated, code wasn't | Update code |
   | Stale Code | Code updated, spec wasn't | Update spec |
   | Missing Spec | Feature exists, never specified | Write spec or remove feature |
   | Missing Implementation | Spec exists, code doesn't | Implement or remove spec item |

3. **Executive Summary.** 3-5 sentences for a busy engineering lead: overall health, biggest risk, production readiness, most impactful first improvement.

4. **Consolidated Scorecard.** All scores from all agents in one table:

   | Area | Dimension | Score | Source Agent |
   |------|-----------|-------|-------------|
   | Spec Quality | Completeness | /5 | 1 |
   | Spec Quality | Clarity | /5 | 1 |
   | Spec Quality | Testability | /5 | 1 |
   | Traceability | Spec-to-Code Coverage | /5 | 2 |
   | Traceability | Spec-to-Test Coverage | /5 | 2 |
   | Traceability | Code-to-Spec Alignment | /5 | 2 |
   | CLI DX | First Contact | /5 | 3 |
   | CLI DX | Discoverability | /5 | 3 |
   | CLI DX | Configuration Flexibility | /5 | 3 |
   | CLI DX | Output Control | /5 | 3 |
   | CLI DX | Error Experience | /5 | 3 |
   | CLI DX | Safety | /5 | 3 |
   | CLI DX | Composability | /5 | 3 |
   | Architecture | Separation of Concerns | /5 | 4 |
   | Architecture | Extensibility | /5 | 4 |
   | Architecture | Code Quality | /5 | 4 |
   | Architecture | Test Design | /5 | 4 |
   | Architecture | Maintainability | /5 | 4 |

   Calculate area averages. Weighted overall: Spec Quality 20%, Traceability 20%, CLI DX 30%, Architecture 30%.

5. **Master Findings Table:**

   | ID | Severity | Area | Summary | Source Agent(s) | Spec Item(s) | Recommended Action |
   |----|----------|------|---------|-----------------|--------------|-------------------|

   Severities: Critical (blocks production), Major (significant friction), Minor (polish), Suggestion (nice-to-have).

6. **Top 10 Recommendations.** Ordered by (impact × breadth) ÷ effort. For each:
   ```
   ### Recommendation N: [Title]
   **Impact:** [What improves]
   **Effort:** Low / Medium / High
   **Addresses:** ISSUE-001, ISSUE-007, ...
   **Action:** [Specific implementation steps]
   ```

7. **Reconciliation Punch List.** Concrete, PR-sized work items grouped by type:

   **Spec Updates:**
   ```
   - [ ] SPEC-CONFIG-003: Add acceptance criteria for ...
   - [ ] NEW: Write spec for ... (implemented but unspecified)
   ```

   **Code Changes:**
   ```
   - [ ] Implement SPEC-OUTPUT-003 (JSON output mode)
   - [ ] Fix exit code for SPEC-ERROR-002
   ```

   **Tests to Add:**
   ```
   - [ ] SPEC-CONFIG-001: Add test for invalid YAML input
   - [ ] Add end-to-end CLI pipeline test
   ```

   **Process Improvements:**
   ```
   - [ ] Add spec item IDs as tags in test descriptions
   - [ ] Add CI check that every spec item has a test
   ```

8. **Workflow Health Assessment.** Evaluate the spec-to-code workflow itself:
   - Is the spec a living document?
   - Is there a defined process for spec → code → test → reconciliation?
   - Are there automated checks for drift?
   - Could a new team member follow the workflow?
   - Provide 2-3 specific workflow improvements to prevent future drift.

### Output
Write everything under `## FINAL-REVIEW`. This is the primary deliverable. Order the sections:
1. Executive Summary
2. Consolidated Scorecard
3. Master Findings Table
4. Spec-Code Divergences
5. Top 10 Recommendations
6. Reconciliation Punch List
7. Workflow Health Assessment

---

## Rules for All Agents

- **Cite specifics.** File paths, line numbers, exact commands and output. "Somewhere in the codebase" is never acceptable.
- **Use the spec item IDs from Agent 1 everywhere.** Do not invent parallel numbering.
- **Be direct.** A 2/5 that's accurate is worth more than a generous 3/5.
- **Prioritize real friction** over stylistic preferences.
- **Every recommendation must be actionable** by a single developer in a single PR.
- **Do not skip agents or merge phases.** Complete each agent's full analysis before starting the next.
- **If the CLI cannot be run** (broken build, missing deps), report as Critical and audit from code reading.
- **If no spec documents exist**, report as Critical and enumerate what should exist based on the codebase.

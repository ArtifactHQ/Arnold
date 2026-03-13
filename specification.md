# Agentic Workflow Specification

## Purpose
This specification defines an agentic workflow for transforming natural language (NL) descriptions of applications into executable code using AI agents, with pluggable execution providers for task orchestration (e.g., GitHub API, Claude Code, or custom backends). The workflow includes spec generation from NL inputs using a library of agent personas and application recipes, task breakdown, execution via the configured provider, and a feedback loop for ensuring alignment through iterative analysis. The system SHALL prioritize automation, modularity, and alignment between specifications and implementations, enabling iterative refinement without human intervention where possible.

## Requirements

### Requirement: NL Input Processing
The system SHALL accept a natural language description of an application as input and transform it into a structured specification document.  
The system MUST retrieve and apply relevant agent personas and application recipes from a predefined library to guide the transformation.

#### Scenario: Basic Web App Description
- GIVEN an NL input: "Build a todo list app with user authentication, real-time updates, and mobile responsiveness."  
- AND a library containing personas (e.g., Software Architect) and recipes (e.g., Web App Recipe with sections for frontend, backend, database, auth).  
- WHEN the Spec Generation Agent processes the input.  
- THEN a structured specification document is produced in Markdown format using OpenSpec conventions: `### Requirement:` headers with `[REQ-{DOMAIN}-{NNN}]` IDs, `#### Scenario:` blocks using GIVEN/WHEN/THEN format, and an embedded JSON metadata block. The document includes sections for features, tech stack, data models, user flows, and edge cases, customized by the selected persona and recipe.

#### Scenario: Library Retrieval Failure
- GIVEN an NL input that does not match any library items (e.g., highly niche domain).
- WHEN retrieval is attempted.
- THEN the system SHOULD default to a generic persona (e.g., General Analyst) and recipe, logging the mismatch for human review.

### Requirement: Technology Stack Defaults [SPEC-SPECGEN-001]
The Spec Generation Agent SHALL default to zero-dependency infrastructure choices unless the user explicitly requests otherwise.

#### Scenario: No Database Preference Specified
- GIVEN an NL input that does not explicitly request a specific database (e.g., "build a task manager app").
- WHEN the Spec Generation Agent generates the technology stack.
- THEN it SHALL default to SQLite for the development and test database.
- AND it SHALL default to Solid Cache, Solid Queue, and Solid Cable for cache, job queue, and real-time respectively.
- AND it SHALL document external service dependencies as "none required" in the External Connections section.

#### Scenario: Explicit Database Preference
- GIVEN an NL input that explicitly requests a specific database (e.g., "use PostgreSQL", "MySQL database").
- WHEN the Spec Generation Agent generates the technology stack.
- THEN it SHALL honor the requested database choice.
- AND it SHALL note any required setup steps (e.g., "PostgreSQL must be installed and running") in the specification.

### Requirement: Task Breakdown
The system SHALL break the generated specification into granular, actionable tasks suitable for AI coding agents.
The system MUST prioritize tasks based on dependencies and label them (e.g., "frontend", "backend").
The first task (position 0) SHOULD be a bootstrap task that sets up the project foundation (project skeleton, dependencies, database configuration). This is an LLM-enforced convention via prompt instructions rather than a hard code constraint.

#### Scenario: Spec to Tasks Conversion
- GIVEN a structured spec from the previous requirement.  
- WHEN the Task Breakdown Agent processes it.  
- THEN a list of 5-20 tasks is outputted, each with title, description, priority, and labels, in a format ready for ingestion (e.g., JSON array).

#### Scenario: Dependency Handling
- GIVEN a spec with interdependent features (e.g., database setup before API endpoints).
- WHEN tasks are generated.
- THEN tasks SHALL be ordered or flagged with dependencies to prevent execution conflicts.

### Requirement: Task Execution
The system SHALL publish generated tasks to the configured execution provider and collect code results.
Execution providers implement a common interface: `create_tasks`, `fetch_results`, `merge_results`, and `async?`. Results from `fetch_results` may optionally include an `execution_metadata` hash (string-keyed, JSON-serializable) for provider-specific observability data; the Executor stores it on the task record when present.
Async providers (e.g., GitHub) use polling to await results; sync providers (e.g., Claude Code) return results immediately.

#### Built-in Providers
- **GitHub** (`:github`) — Creates GitHub Issues, uses Actions/Copilot for execution, collects results from PRs. Supports `github_issue_mention` for @mention-based agent routing.
- **Claude Code** (`:claude_code`) — Executes tasks locally via the `claude` CLI in git worktrees. Sync provider (no polling).
- **Null** (`:null`) — Test-only provider that returns empty results.

Custom providers can be registered via `ArnoldPipeline::Providers::Execution.register(:name, ProviderClass)`.

#### Scenario: Claude Code Execution Metadata [SPEC-EXEC-002]
- GIVEN a task executed by the Claude Code provider.
- WHEN the task completes (success or failure).
- THEN the provider parses the JSON output from `claude --print --output-format json` and extracts execution metadata: `cost_usd`, `duration_ms`, `num_turns`, `model`, and `session_id`.
- AND the metadata is stored on the task record's `execution_metadata` JSON column using string keys.
- AND execution_metadata is an optional field in the provider contract — providers that omit it continue working unchanged.

#### Scenario: Claude Code Failure Diagnostics [SPEC-EXEC-003]
- GIVEN a task executed by the Claude Code provider that fails.
- WHEN `fetch_results` assembles the result for the executor.
- THEN Claude's final message is captured as a comment (`source: "claude_code"`, `author: "claude"`, body prefixed with "Task failed:").
- AND the comment body is truncated to 3000 characters if it exceeds that limit.
- AND the comment is visible to the analysis agent for failure diagnosis.

#### Scenario: Claude Code Error Detection [SPEC-EXEC-004]
- GIVEN a task executed by the Claude Code provider.
- AND the Claude CLI exits with code 0 but the JSON output contains `is_error: true`.
- WHEN the provider processes the result.
- THEN the task is marked as failed with error "Claude reported error: {subtype}".
- AND this prevents silent failures when Claude hits max turns or encounters internal errors.

#### Scenario: Claude Code Prompt Layering [SPEC-EXEC-005]
- GIVEN a task to be executed by the Claude Code provider.
- WHEN the CLI command is constructed.
- THEN behavioral instructions (test running, commit rules, working directory constraints) are sent via `--append-system-prompt`.
- AND project context is provided via a generated CLAUDE.md file in the worktree (auto-loaded by Claude Code).
- AND the main prompt contains only task-specific content (title, description, labels, prior context).

#### Scenario: Task Ingestion (GitHub)
- GIVEN a list of tasks from the Task Breakdown Agent.
- WHEN pushed via the GitHub API (e.g., creating Issues).
- THEN tasks appear as GitHub Issues, linked to the project repository, ready for agent assignment and execution.

#### Scenario: Multi-Agent Routing (GitHub)
- GIVEN tasks with labels.
- WHEN executed via GitHub.
- THEN the system SHOULD route tasks to appropriate agents. Current implementation uses @mention (via `github_issue_mention` config) and labels on GitHub Issues. Active routing by agent strength (e.g., assigning frontend tasks to specialized agents) is a future enhancement. [PLANNED]

### Requirement: Feedback Loop for Alignment
The system SHALL implement a post-execution feedback loop using an Analysis Agent to evaluate code outputs against the original specification.
The system MUST decide whether to iterate on tasks (for implementation fixes) or the specification (for clarifications), with a configurable maximum iterations (default 3, range 1-10) to prevent infinite loops.
The system SHOULD use confidence scores (0-100%) as a reporting guideline to flag low-confidence decisions (below 70%) for human review. Confidence does not gate execution -- all decisions are acted on regardless of score.
The loop SHALL use the execution provider's polling mechanism (async providers) or immediate result collection (sync providers) for the feedback cycle.

#### Scenario: Task Iteration Due to Misalignment
- GIVEN code diffs from GitHub PRs that deviate from the spec (e.g., missing edge case handling).
- AND an Analysis Agent prompted with diffs, spec, and a Quality Assurance Analyst persona.
- WHEN analysis is performed.
- THEN if "iterate_tasks" is decided (with reasoning and confidence score), new corrective tasks are generated and pushed via the GitHub API for re-execution. Decisions with confidence below 70% are flagged for human review.

#### Scenario: Spec Iteration for Ambiguity
- GIVEN analysis revealing spec vagueness (e.g., unclear user flow).
- WHEN "iterate_spec" is decided.
- THEN the Analysis Agent produces structured deltas (added/modified/removed operations targeting specific requirements), the spec is refined via the delta merge chain, a SpecRevision snapshot is created, and the updated spec is re-run through Task Breakdown with tasks regenerated from the refined specification, replacing all existing tasks.

#### Scenario: Loop Termination
- GIVEN alignment achieved after iterations or max iterations reached.
- WHEN final validation occurs.
- THEN changes are merged via GitHub API (e.g., PR merge), and the loop ends.

#### Scenario: Iteration Context with Convergence Pressure [SPEC-ANALYSIS-009]
- GIVEN the Analysis Agent is evaluating iteration N of max_iterations.
- WHEN the analysis prompt is constructed.
- THEN an "Iteration Context" section is appended containing:
  - The current iteration number and total max_iterations.
  - A "Previous Decisions" list showing each prior iteration's decision, confidence, and reasoning excerpt.
  - Escalating convergence pressure based on remaining budget:
    - More than half budget remaining: no extra pressure.
    - Half budget spent (remaining >= 2): "Bias toward `done` unless there are significant functional gaps."
    - Penultimate iteration (remaining == 1): "Strongly prefer `done` unless there are critical, unambiguous failures."
    - Final iteration (remaining == 0): "You MUST choose `done`."
- AND if all previous iterations chose `iterate_tasks` and there are 2+ prior decisions, a "STUCK DETECTION" warning is included advising the agent that the same approach is not converging.

#### Scenario: Analysis Done Threshold Promotion [SPEC-ANALYSIS-010]
- GIVEN the Analysis Agent returns `iterate_tasks` with a confidence score.
- AND `analysis_done_threshold` is configured (integer 50-100, default nil/disabled).
- WHEN the confidence score is greater than or equal to the threshold.
- THEN the decision is promoted from `iterate_tasks` to `done`.
- AND the promotion is logged and recorded as a pipeline event with `promoted_from: "iterate_tasks"`.
- AND when the threshold is nil (default), no promotion occurs and the agent's decision is used as-is.

### Analysis Evaluation Methodology

The Analysis Agent applies three completeness tests and checks for seven anti-patterns when evaluating implementation against the specification.

#### Completeness Tests

Each test is scored 0-100 and included in the analysis output as `completeness_scores`:

1. **New Reader Test** (`new_reader_test`) -- Could someone who has never spoken to the user read the spec and fully understand what exists, why it exists, how it behaves in normal and edge conditions, and how to know if it is working correctly?

2. **Coding Agent Test** (`coding_agent_test`) -- Could a coding agent implement the spec without making assumptions about undefined behavior, guessing at data types, inventing UI elements not specified, or creating logic not documented?

3. **Change Request Test** (`change_request_test`) -- If someone wanted to change something, could they find where it is defined, understand what else would be affected, and trace the change through all connected sections?

#### Anti-Pattern Detection

The Analysis Agent checks the specification for these anti-patterns and reports any found:

- **Orphaned Reference** -- A concept referenced but never defined elsewhere.
- **Contradictory Specification** -- Conflicting numbers, rules, or behaviors in different sections.
- **Vague Quantity** -- Imprecise amounts like "more points" or "appears higher" without formulas.
- **Missing Negative** -- Features that describe what CAN happen but not limits, restrictions, or error states.
- **Lazy Idea Drop** -- Ideas mentioned casually without full treatment or explicit deferral.
- **Assumed Understanding** -- Phrases like "works as expected" or "standard flow".
- **Technical Leak** -- Implementation details (SQL types, API formats) instead of behavioral descriptions.

#### Human Review Flag

Confidence scores from the analysis drive the `needs_human_review` boolean on the Iteration model. When the overall confidence score is below 70%, the Iteration's `needs_human_review` field is automatically set to `true` via a `before_save` callback. This flag is queryable via `arnold_pipeline status ID --json`. Confidence does not gate execution -- all decisions are acted on regardless of score.

#### Spec Versioning and Delta Tracking [SPEC-DELTA-001]

When a specification changes (via initial generation or `iterate_spec` decisions), the Specification model's `version` field is incremented. Each version change is tracked through two models:

**SpecRevision** — Immutable snapshots of the full specification content at each version. [SPEC-DELTA-002]
- `version`: Integer, matches the Specification's version at time of snapshot (unique per specification).
- `content`: Full spec Markdown text at this version.
- `structured_data`: JSON metadata block at this version.
- `change_source`: One of `"spec_generation"` (initial spec or re-generation), `"iterate_spec"` (analysis-driven refinement), or `"user_iterate"` (user-initiated CLI iteration).
- `delta_summary`: JSON array of human-readable strings summarizing what changed (e.g., `"ADDED: Authentication > Password Reset"`).
- The Orchestrator creates a SpecRevision after every `generate_spec!` call (change_source: `"spec_generation"`).
- The AnalysisLoop creates a SpecRevision after every successful delta merge (change_source: `"iterate_spec"`).
- The Orchestrator creates a SpecRevision after every `iterate_spec!` or `fork!` call (change_source: `"user_iterate"`).

**SpecDelta** — Granular, per-requirement change records for `iterate_spec` decisions. [SPEC-DELTA-003]
- `operation`: One of `"added"`, `"modified"`, or `"removed"`.
- `section`: The functional area being changed (e.g., "Authentication").
- `requirement`: The specific requirement name (required for `modified` and `removed` operations).
- `before_content`: Previous requirement text (required for `modified`).
- `after_content`: New requirement text (required for `added` and `modified`).
- `rationale`: Explanation of why the change is needed.
- Belongs to both a Specification and an Iteration.
- Scopes: `additions`, `modifications`, `removals`, `by_section(name)`.

The Analysis Agent prompt requests structured deltas in the `corrective_data.deltas` array when making `iterate_spec` decisions. Each delta targets one requirement in one section using the `### Requirement:` / `#### Scenario:` / GIVEN-WHEN-THEN format. If no structured deltas are returned, the system falls back to legacy free-text `spec_changes` appending.

#### Spec Delta Merge Chain [SPEC-DELTA-004]

When structured deltas are available, the system applies them through a three-tier fallback chain:

1. **OpenSpec CLI merge** — If `openspec_enabled` is true and the OpenSpec CLI is available, the OpenspecBridge writes the base spec and delta files into an OpenSpec workspace, runs `openspec validate` and `openspec archive`, and reads back the merged result. This produces the highest-quality merge.
2. **Structured append** (`append_deltas!`) — If OpenSpec merge fails or is disabled, deltas are formatted into `## ADDED Requirements`, `## MODIFIED Requirements`, and `## REMOVED Requirements` sections and appended to the spec.
3. **Legacy append** (`legacy_append!`) — If no structured deltas exist (only free-text `spec_changes`), the text is appended under a `## Clarifications (Iteration)` header. This preserves backward compatibility.

Each path increments the spec version and persists SpecDelta records (when structured deltas are available).

### Requirement: Library Management
The system SHALL maintain a library of agent personas and application recipes, stored as YAML files with keyword-based retrieval.
The system SHOULD support dynamic selection based on NL input keyword matching. Vector database semantic retrieval is a future consideration. [PLANNED]

#### Scenario: Persona and Recipe Selection
- GIVEN an NL input.
- WHEN keyword matching is performed against the library's persona and recipe keywords.
- THEN the most relevant persona (e.g., Domain Expert for fintech) and recipe (e.g., API Service) are retrieved and injected into prompts.

#### Scenario: Library Selections Persistence [SPEC-LIBRARY-003]
- GIVEN the Spec Generation Agent has matched a persona, recipe, and domain type from the Library.
- WHEN the orchestrator completes spec generation.
- THEN the selected library items are persisted in `pipeline_run.metadata["library_selections"]` as a hash with keys: `persona` (name string), `recipe` (name string), `supporting_recipes` (array of name strings), `domain_type` (code string).
- AND these selections are available to downstream stages (e.g., execution provider) without re-running library matching.

#### Scenario: Library-Driven CLAUDE.md Generation [SPEC-LIBRARY-004]
- GIVEN library selections are available in `pipeline_run.metadata["library_selections"]`.
- WHEN the Claude Code provider sets up a worktree for task execution.
- THEN the `ClaudeMdGenerator` service assembles a CLAUDE.md file from the resolved persona, recipe, and domain type YAML data.
- AND the generated file includes sections derived from library data: Tech Stack (from recipe framework), Conventions (from recipe sections guidance), Testing (from recipe verification), Domain Context (from domain type), Terminology (from domain type), Watch For (from domain type).
- AND sections with no data are omitted (nil-safe).
- AND if the target repo already has a root `CLAUDE.md`, the generated file is written to `.claude/CLAUDE.md` instead (additive loading).
- AND if no library selections are available, no CLAUDE.md is generated (no-op).

### Requirement: Recipe Structural Metadata [SPEC-LIBRARY-002]
Recipes MAY include structural metadata on their sections to guide task breakdown and execution ordering.

#### Scenario: Phase Filtering Excludes Post-Pipeline Sections
- GIVEN a recipe with a section tagged `phase: post_pipeline` (e.g., Deployment & Infrastructure).
- WHEN the task breakdown prompt is constructed.
- THEN sections with `phase: post_pipeline` are excluded from the prompt, so the agent does not generate deployment tasks that cannot be executed in the pipeline.

#### Scenario: Tier Placement Hints Guide Task Ordering
- GIVEN a recipe section with `tier_placement: final` (e.g., Testing & Quality).
- WHEN the task breakdown prompt includes that section.
- THEN the prompt instructs the agent to place tasks from that section in the final execution tier, after all other implementation tiers.

#### Scenario: Verification Criteria Inform Bootstrap Tasks
- GIVEN a recipe with a `verification` block containing `setup_command`, `run_command`, and/or `health_check`.
- WHEN the task breakdown prompt is constructed.
- THEN the verification steps are included in the prompt so the agent ensures the bootstrap task produces a project that passes those checks.

### Requirement: OpenSpec Integration [SPEC-OPENSPEC-001]
The system SHALL support integration with the OpenSpec CLI (`@fission-ai/openspec`) for structured spec merging during `iterate_spec` decisions.
The system MUST gracefully degrade when the OpenSpec CLI is not installed, falling back to the structured append or legacy append merge strategies.

#### Scenario: Successful OpenSpec Merge
- GIVEN a specification and structured deltas from an `iterate_spec` decision.
- AND `openspec_enabled` is true and the OpenSpec CLI is installed at `openspec_cli_path`.
- WHEN the OpenspecBridge processes the deltas.
- THEN it creates a temporary workspace, writes the base spec and delta files, runs `openspec validate` followed by `openspec archive --yes`, and returns the merged spec content.

#### Scenario: OpenSpec CLI Not Installed
- GIVEN `openspec_enabled` is true but the CLI binary is not found.
- WHEN the OpenspecBridge attempts to run the CLI.
- THEN it logs a warning and returns nil, causing the system to fall back to the structured append strategy.

#### Scenario: OpenSpec Validation Failure
- GIVEN a delta that fails `openspec validate`.
- WHEN validation returns a non-zero exit code.
- THEN the merge is skipped with a warning, and the system falls back to structured append.

#### OpenspecBridge Service

The `OpenspecBridge` manages the lifecycle of a temporary OpenSpec workspace:
- `with_workspace` class method creates a temp directory, scaffolds the OpenSpec structure (`specs/`, `changes/`, `config.yaml`), yields the bridge instance, and cleans up on completion.
- `write_spec!` writes the current specification content into the workspace.
- `write_delta_and_merge!` formats deltas into OpenSpec-compatible Markdown (with `## ADDED Requirements`, `## MODIFIED Requirements`, `## REMOVED Requirements` sections), creates a `proposal.md` (with `## Why` and `## What Changes` sections), validates, and archives.
- Delta Markdown uses the `### Requirement:` / `#### Scenario:` / GIVEN-WHEN-THEN format matching the spec generation output.

### Requirement: Extensibility and Automation
The system is implemented as a Ruby gem (Rails engine) for orchestration, using the GitHub API for task management and execution.
The system MAY integrate with external tools like GitHub webhooks for triggering feedback loops. [PLANNED]

#### Scenario: Full End-to-End Run
- GIVEN an NL input through all stages including feedback.
- WHEN the workflow executes autonomously.
- THEN a complete application is built in the repository, aligned to the refined spec, with logs tracking iterations.

### Requirement: Domain Types
The system SHALL classify NL inputs into one of 13 domain types to provide domain-specific context to spec generation.
The system MUST support the following domain types: GAME, SOCIAL, PRODUCTIVITY, MARKETPLACE, CONTENT, SERVICE, ANALYTICS, HEALTH, EDUCATION, FINTECH, IOT, CREATIVE, GENERIC.
Domain types are stored as YAML files and selected via keyword-based matching against the NL input.

#### Scenario: Domain Type Selection
- GIVEN an NL input such as "Build a multiplayer game with leaderboards."
- WHEN the Library Manager performs keyword matching against domain type definitions.
- THEN the GAME domain type is selected and its emphasis, document_focus, watch_for, and terminology are injected as a domain lens into the Spec Generation Agent prompt.

#### Scenario: Domain Type Fallback
- GIVEN an NL input that does not match any domain type keywords.
- WHEN domain type selection is performed.
- THEN the system SHALL fall back to the GENERIC domain type and log a warning.

### Requirement: Tier Execution
The system SHALL compute execution tiers from task dependency graphs and execute tasks tier-by-tier.
Tasks within the same tier have no mutual dependencies and MAY be executed concurrently.
After each tier completes, results are merged before the next tier begins.

#### Scenario: Tier Computation from Dependencies
- GIVEN a set of tasks with `depends_on` fields forming a directed acyclic graph (DAG).
- WHEN TierCalculator processes the tasks.
- THEN each task is assigned a tier number: tier 0 for tasks with no dependencies, tier N+1 for tasks whose deepest dependency is in tier N.

#### Scenario: Cycle Detection
- GIVEN tasks whose dependencies form a cycle (e.g., task A depends on B, B depends on A).
- WHEN TierCalculator processes the tasks.
- THEN a CycleError is raised, halting the pipeline.

#### Scenario: Tier Gate Check
- GIVEN a tier that has completed execution and merge.
- AND tier_gate_enabled is true.
- WHEN the TierGateCheck agent evaluates the merged diffs, task summaries, and verification_results.
- THEN it returns a pass/fail verdict, a context_summary, and optionally corrective_tasks.

#### Scenario: Tier Gate Failure with Retry [SPEC-TIER-004]
- GIVEN a tier that failed the gate check.
- AND retry_count is less than max_tier_retries (default 2, range 0-5).
- WHEN the system retries.
- THEN corrective tasks from the gate result are created at the same tier, executed sequentially (one at a time with merge between each), and re-evaluated.
- AND each corrective task branches from the updated master branch (including changes from the previous corrective task's merge).
- AND task summaries sent to the tier gate reviewer are annotated with `[FAILED - EMPTY DIFF]` for tasks that completed with exit code 0 but no code changes, or `[FAILED]` for other failures.

#### Scenario: Corrective Task Description Enrichment [SPEC-TIER-007]
- GIVEN a tier gate failure produces corrective tasks.
- WHEN corrective tasks are created.
- THEN each corrective task description is enriched with contextual sections beyond the gate's base description:
  - `## Gate Issues` — Numbered list of issues from the gate result that triggered the correction.
  - `## Original Tier Tasks` — List of the original tier's tasks with title, description, and diff status annotation: `[produced diffs]` for tasks with non-empty result_diff, `[NO DIFFS]` for tasks with empty or missing diffs.
  - `## Acceptance Criteria Status` — The formatted acceptance criteria summary (verified/failed/unverified) when available.
- AND if no additional context is available (no gate issues, no original tasks, no criteria), the base description is used as-is.
- AND the current tier's `context_summary` from the gate result is included in the `prior_context` passed to corrective task execution, so the executor knows what the original tier already built.

#### Scenario: Test-Driven Corrective Task Generation [SPEC-TIER-008]
- GIVEN a tier gate evaluation where verification checks have failed with specific test output.
- WHEN the CorrectiveTaskGenerator service processes the test results.
- THEN it parses failures using TestResultParser to extract structured failure data.
- AND it groups failures by category: view_markup, integration_expectation, unit_expectation, missing_reference, routing, and general.
- AND it generates one corrective task per failure category, with file:line references from the test output included in the task description.
- AND if the LLM-based task generation fails, it falls back to direct task construction from the parsed test results.
- AND if no individual failures can be parsed from the test output (e.g., error blocks that the parser cannot extract), it generates a single generic corrective task containing the raw test summary so the executor can diagnose and fix failures.
- AND TestResultParser extracts both minitest Failure blocks (bracket location format) and Error blocks (stack trace format) as structured failure data.

#### Scenario: Tier Gate Evaluation Path Selection [SPEC-TIER-009]
- GIVEN a tier has completed execution and merge.
- WHEN the TierExecutionEngine prepares for gate evaluation.
- THEN it selects the `evaluate_with_verification` path when a test_suite verification check is present in the results.
- AND it selects the `evaluate_with_llm` path when no verification checks ran (fallback to LLM judgment).
- AND the selected evaluation path is recorded as `decision_source` in the pipeline event metadata, with values: `verification_tests_passed`, `verification_tests_failed`, `verification_required_failed`, or `llm_judgment`.

#### Scenario: Duplicate create_table Migration Resolution [SPEC-TIER-010]
- GIVEN parallel worktree tasks that each create migrations containing `create_table` for the same table name.
- WHEN the tier's task branches are merged sequentially into the main branch.
- THEN the system SHALL scan all migrations in `db/migrate/` for duplicate `create_table` calls targeting the same table.
- AND for each duplicate (second or later occurrence), it SHALL patch the migration file to add `if_not_exists: true` to the `create_table` call.
- AND it SHALL commit the patched files with a descriptive commit message.
- AND the original (first) migration creating each table SHALL remain unchanged.
- AND this operation SHALL be non-fatal — errors are logged but do not crash the pipeline.

#### Scenario: Recipe-Driven Verification Checks [SPEC-TIER-011]
- GIVEN a recipe with `verification.checks` (e.g., `solid_stack`) and `finalization.checks` (e.g., boot check).
- WHEN the pipeline executes tier gates and finalization.
- THEN recipe checks are automatically included without manual config.yml setup.
- AND recipe checks are defaults; user `config.verification_checks` overrides by name.
- AND the check type registry maps each type to a default tier (e.g., solid_stack → tier 0).
- AND `scheduled_for_tier?` filters checks so solid_stack only runs at tier 0.
- AND `eligible_for_finalization?` excludes test_suite from finalization.
- AND `library_manager` is injected into TierExecutionEngine for recipe resolution.

#### Scenario: Tier Gate Retry Exhaustion
- GIVEN a tier that has failed the gate check max_tier_retries times.
- WHEN the retry limit is reached.
- THEN the pipeline is paused with status "paused", metadata records the tier_gate_failure details, and a TierGateError is raised.
- AND if a retry produces no corrective tasks (empty array from generator), it still consumes a retry attempt and loops back rather than silently proceeding to the next tier.

#### Scenario: Empty Diff Detection (Claude Code Provider) [SPEC-TIER-005]
- GIVEN a task executed by the Claude Code provider.
- AND the Claude CLI exits with code 0 (success).
- WHEN the captured diff from the worktree branch is empty.
- THEN the task result is marked as `success: false` with error "Task completed with exit code 0 but produced no code changes".
- AND the task is eligible for tier gate corrective task generation.

#### Scenario: Baseline-Aware Tier Gate [SPEC-TIER-006]
- GIVEN a pipeline runs on a repository with existing files from a prior pipeline run.
- AND `claude_code_repo_path` is configured with a valid git repository path.
- WHEN the Orchestrator's `execute!` method begins.
- THEN the baseline commit SHA is recorded in pipeline metadata via `record_baseline_sha!` using `git rev-parse HEAD`.
- AND when a tier gate check evaluates diffs, the TierExecutionEngine invokes `RepoContextScanner.call(repo_path:)` to scan existing tracked files.
- AND the scanner uses `git ls-tree` to list files matching `repo_context_scan_patterns` (default: db/migrate/, config/, app/models/, app/controllers/, lib/) and `repo_context_scan_files` (default: Gemfile, config/routes.rb, config/database.yml, db/schema.rb, db/structure.sql).
- AND the scanned file list is formatted with grouped directories (max 20 files shown per directory) and passed to `TierGateCheck` via the `repo_context:` parameter.
- AND the tier gate prompt includes a "Repository Baseline" section instructing the gate reviewer to NOT flag existing files as missing.
- AND a `repo_context_scanned` event is recorded in the pipeline audit trail with file_count and directory summary.

#### Scenario: Baseline Recording is Idempotent
- GIVEN a pipeline run already has `baseline_commit_sha` in its metadata (e.g., from a prior execution before pause).
- WHEN `execute!` is called again during resume.
- THEN `record_baseline_sha!` detects the existing SHA and does NOT overwrite it.
- AND the same baseline SHA is preserved across resume cycles.

#### Scenario: Graceful Degradation Without Repo Context
- GIVEN `claude_code_repo_path` is nil or points to a non-existent directory.
- OR `RepoContextScanner.call` fails (e.g., git command error).
- WHEN tier gate check runs.
- THEN the `repo_context:` parameter is nil.
- AND the tier gate operates normally without a "Repository Baseline" section.
- AND the pipeline continues execution without interruption.

#### Scenario: Merge Conflict Resolution (Claude Code Provider)
- GIVEN two tasks in the same tier that modify the same file (e.g., both adding routes to `config/routes.rb`).
- AND the execution provider is Claude Code with `merge_conflict_resolution_enabled` set to true (default).
- WHEN the first task's branch merges successfully but the second task's branch produces a merge conflict.
- THEN the system detects the conflict, invokes the Claude CLI with a resolution prompt containing the conflicted file contents and task context, verifies all conflict markers are removed, and completes the merge with both tasks' changes preserved.

#### Scenario: Merge Conflict Resolution Disabled
- GIVEN a merge conflict occurs during tier merging.
- AND `merge_conflict_resolution_enabled` is set to false.
- WHEN the merge fails.
- THEN the system aborts the merge and raises a recoverable MergeError without attempting resolution.

#### Scenario: Merge Conflict Resolution Failure
- GIVEN a merge conflict occurs during tier merging.
- AND `merge_conflict_resolution_enabled` is true.
- WHEN the Claude CLI fails to resolve the conflict (exits non-zero, leaves conflict markers, or the number of conflicted files exceeds `merge_conflict_max_files` (default: 10)).
- THEN the system aborts the merge and raises a recoverable MergeError. The TierExecutionEngine logs this as a non-fatal warning and continues the pipeline.

### Requirement: Context Propagation
The system SHALL accumulate context summaries from tier gate checks and inject them into subsequent tier issue bodies.
This enables later tiers to be aware of decisions and patterns established in earlier tiers.

#### Scenario: Context Accumulation
- GIVEN a tier that passes the gate check with context_propagation_enabled set to true.
- WHEN the gate result includes a context_summary.
- THEN the summary is stored in the pipeline_run metadata under the "tier_contexts" array.

#### Scenario: Context Injection into Issue Bodies
- GIVEN accumulated tier contexts from previous tiers.
- WHEN a new tier's tasks are published as GitHub Issues.
- THEN a "Prior Implementation Context" section is prepended to the issue body, containing summaries from all previously completed tiers.

### Requirement: Workflow Status Checking
The system SHALL verify that GitHub CI workflows have completed before resolving task results.
This prevents premature task resolution when code changes are still being validated.

#### Scenario: Active Workflow Detection
- GIVEN a task with a published PR on GitHub.
- AND workflow_status_enabled is true.
- WHEN the system checks for active workflows.
- THEN it inspects PR check runs on the head commit AND repository workflow runs on branches matching workflow_branch_pattern (default: `/issue[-_]?\d+/i`).
- AND if any workflows are in_progress, the task's workflow_active flag remains true.

#### Scenario: Workflow Completion
- GIVEN a task whose associated workflows have all completed.
- WHEN the system polls for results.
- THEN workflow_active is set to false and the task is eligible for result resolution.

### Comment Classification Heuristics

During GitHub polling, the system classifies issue comments using pattern-based heuristics to determine task progress and resolution status.

**WIP Patterns** -- Comments matching any of these patterns indicate work is still in progress:
- "is working", "get back to you", "working on", "in progress", "starting work", "I'll analyze", "picking up", "looking into"

**Resolution Patterns** -- Comments matching any of these patterns indicate a task has reached a resolution (success or failure):
- Completion signals: "finished", "completed", "created pr" / "create pr"
- Failure/blocker signals: "can't", "unable to", "failed", "error"

A comment is considered "substantive" if it matches at least one resolution pattern. The `has_substantive_comments?` method on the Task model uses these patterns to determine whether a task's comments indicate resolution. Tasks with only WIP-pattern comments are classified as `wip_comments_only` in the resolution summary.

### Requirement: Empirical Validation System [SPEC-VALIDATION-001]
The system SHALL provide a four-layer empirical validation system that evaluates task outputs using acceptance criteria, post-merge hooks, verification checks, and spec-scenario integration tests.
Validation results are passed to the tier gate check agent to inform pass/fail decisions and corrective task generation.
All validation layers are optional and configurable; when disabled, the tier gate operates without those signals.

**Layer 1: Acceptance Criteria** — Static and runtime checks defined per-task (file_exists, test_exists, model_has, route_exists, http, command_exits).
**Layer 2: Post-Merge Hooks** — User-configurable commands triggered by file path patterns after tier merge. Hooks may commit derived files (e.g., database schema, generated assets) when specified.
**Layer 3: Verification Checks** — User-configurable command sequences (boot/test_suite/custom) run after hooks to verify application health. Checks can be marked as required; failures short-circuit the sequence.
**Layer 4: Spec-Scenario Integration Tests** — Auto-generated tests from GIVEN/WHEN/THEN scenarios in the specification, executed after each tier to measure alignment progress.

#### Layer 1: Acceptance Criteria on Tasks [SPEC-CRITERIA-001]

Tasks MAY include an `acceptance_criteria` JSON array field defining verifiable conditions that must be met for the task to be considered complete.
Each criterion has a `type`, `description`, and `params` hash.
The system SHALL support six criterion types: four static types (evaluated offline against the repository) and two runtime types (evaluated by executing commands or HTTP requests).

**Static Criterion Types:**
- `file_exists` — Verifies a file matching a glob pattern exists (params: `pattern`)
- `test_exists` — Verifies a test file matching a glob pattern exists (params: `pattern`)
- `model_has` — Verifies a Rails model has specific attributes/associations (params: `model`, `attributes`, `associations`)
- `route_exists` — Verifies a Rails route exists (params: `method`, `path`, `controller`, `action`)

**Runtime Criterion Types:**
- `http` — Executes an HTTP request and verifies response (params: `method`, `url`, `expected_status`, `expected_body_pattern`)
- `command_exits` — Executes a shell command and verifies exit code (params: `command`, `expected_exit_code`)

#### Scenario: Acceptance Criteria Definition in Task Breakdown
- GIVEN a specification requiring user authentication.
- WHEN the Task Breakdown Agent generates tasks.
- THEN the authentication task includes acceptance criteria such as:
  - `{ "type": "file_exists", "description": "User model exists", "params": { "pattern": "app/models/user.rb" } }`
  - `{ "type": "route_exists", "description": "Login route exists", "params": { "method": "POST", "path": "/login" } }`

#### Scenario: Static Criteria Evaluation After Tier Merge [SPEC-CRITERIA-002]
- GIVEN tasks with acceptance criteria have been executed and merged.
- WHEN the CriteriaChecker evaluates static criteria against the repository.
- THEN each criterion is marked as `verified`, `unverified`, or `failed`.
- AND the formatted results summary is passed to the tier gate check via `acceptance_criteria_summary:` parameter.

#### Scenario: Criteria Re-evaluation on Tier Gate Retry
- GIVEN a tier that failed the gate check and triggered corrective tasks.
- WHEN corrective tasks are executed and merged.
- THEN acceptance criteria are re-evaluated against the updated repository state.

#### Scenario: Acceptance Criteria Persistence
- GIVEN the Task Breakdown Agent generates tasks with acceptance criteria.
- WHEN tasks are persisted to the database.
- THEN the `acceptance_criteria` JSON field is saved for each task.
- AND when corrective tasks are generated from tier gate failures, they also receive `acceptance_criteria` if provided by the tier gate agent.

#### Layer 2: Post-Merge Hooks [SPEC-HOOK-001]

The system SHALL support user-configurable post-merge hooks that execute commands after each tier merge.
Hooks are triggered when changed files match configured glob patterns (trigger_paths).
When a hook succeeds and commit_paths are specified, the runner commits derived files to preserve generated artifacts.

#### Scenario: Hook Definition and Triggering [SPEC-HOOK-002]
- GIVEN a post-merge hook configured with:
  - `name: "Update Database Schema"`
  - `trigger_paths: ["db/migrate/*.rb"]`
  - `command: "bundle exec rails db:migrate"`
  - `commit_paths: ["db/schema.rb"]`
  - `commit_message: "Update schema from migration"`
- AND a tier merge includes changes to `db/migrate/20250214_create_users.rb`.
- WHEN the PostMergeHookRunner evaluates hooks.
- THEN changed files are extracted from each task's `result_diff` by parsing the JSON array and collecting `filename` fields (with fallback to unified diff regex parsing if JSON parsing fails).
- AND the hook's `triggered_by?` method matches via File.fnmatch(pattern, file, File::FNM_PATHNAME).
- AND the command executes in the repository directory.
- AND if exit code is 0 and `db/schema.rb` has changed, a git commit is created with the specified message.

#### Scenario: Hook Result Recording [SPEC-HOOK-003]
- GIVEN a hook execution completes.
- WHEN the result is returned.
- THEN it includes: `{ name:, triggered:, success:, stdout:, stderr:, exit_code: }`.
- AND stdout/stderr are capped at 2000 characters.
- AND a `post_merge_hooks` pipeline event is recorded with:
  - **Summary:** `{ hook_count:, triggered_count:, success_count:, results: [{ name:, triggered:, success:, exit_code: (if triggered), error: (if raised) }] }`
  - **Payload:** `{ changed_files: [filenames], results: [full hook result hashes including stdout/stderr] }`

#### Scenario: Hooks Run Before Gate Check [SPEC-HOOK-004]
- GIVEN tier tasks have been merged.
- WHEN the tier execution flow proceeds.
- THEN post-merge hooks run first (after merge, before gate).
- AND verification checks run second (after hooks, before gate).
- AND tier gate check runs last with verification_results parameter.

#### Scenario: Non-Fatal Hook Failures [SPEC-HOOK-005]
- GIVEN a post-merge hook raises an exception.
- WHEN the PostMergeHookRunner catches the error.
- THEN it logs the error and returns `{ name:, triggered: true, success: false, error: message }`.
- AND the pipeline continues execution without interruption.

#### Layer 3: Verification Checks [SPEC-VCHECK-001]

The system SHALL support user-configurable verification checks that run command sequences after each tier merge.
Checks can be of type `:boot`, `:test_suite`, or `:custom`, and can be marked as `required` to short-circuit on failure.
Verification results (all_passed, summary, and per-check details) are passed to the tier gate check via `verification_results:`.

#### Scenario: Check Definition and Execution [SPEC-VCHECK-002]
- GIVEN a verification check configured with:
  - `name: "Boot Check"`
  - `command: "bin/rails runner 'ActiveRecord::Migration.check_all_pending!; SolidQueue::Job rescue nil; puts Rails.version'"`
  - `type: :boot`
  - `required: true`
- AND a tier has completed merge.
- WHEN the VerificationRunner processes checks.
- THEN the command executes in the repository directory.
- AND the result captures: `{ name:, type:, success:, exit_code:, stdout:, stderr:, duration_ms: }`.
- AND stdout is capped at 5000 characters, stderr at 2000 characters.

#### Scenario: Required Check Short-Circuits [SPEC-VCHECK-003]
- GIVEN three checks configured: Boot (required), Database Migration (not required), Test Suite (required).
- AND the Boot check fails (exit code 1).
- WHEN the VerificationRunner executes checks.
- THEN the Boot check runs and fails.
- AND Database Migration and Test Suite checks are NOT executed.
- AND the results include only the Boot check with `all_passed: false`.

#### Scenario: Verification Results Determine Gate Verdict [SPEC-VCHECK-004]
- GIVEN verification checks have executed.
- WHEN the tier gate check agent is invoked.
- THEN it receives `verification_results:` containing:
  - `{ checks: [...], all_passed: boolean, summary: "N passed, M failed: details" }`
- AND the gate prompt includes a unified "Empirical Verification Results" section with formatted check details.
- AND when verification results are available, they determine the tier gate verdict rather than serving as advisory input.

#### Scenario: Verification Re-execution on Tier Gate Retry [SPEC-VCHECK-005]
- GIVEN a tier that failed the gate check and triggered corrective tasks.
- WHEN corrective tasks are executed and merged.
- THEN the verification checks are re-run against the updated codebase.

#### Scenario: Graceful Degradation Without Checks [SPEC-VCHECK-006]
- GIVEN no verification checks are configured (`verification_checks` is empty).
- OR `claude_code_repo_path` is nil.
- WHEN the tier gate process runs.
- THEN verification is skipped and `verification_results:` is nil.

#### Scenario: Empirical Validation Decision Hierarchy [SPEC-VCHECK-007]
- GIVEN verification checks have run and produced test results.
- WHEN the tier gate evaluates the results.
- THEN verification results are the primary pass/fail signal for the gate verdict.
- AND required check failures cause immediate gate failure regardless of other signals.
- AND a test_suite check that passes causes the gate to pass (acceptance criteria are advisory only).
- AND a test_suite check that fails causes the gate to fail, with corrective tasks generated from the test failures.
- AND when no verification checks ran, LLM judgment is the fallback evaluation method.

#### Layer 4: Spec-Scenario Integration Tests [SPEC-SPECTEST-001]

The system SHALL generate integration tests from specification GIVEN/WHEN/THEN scenarios using the SpecTestGenerator agent.
Generated tests are executed after each tier to measure alignment progress: total tests, passing tests, newly passing tests, regressions, and pass rate.
Spec test results are passed to the Analysis Agent via `spec_test_progress_summary:` as a primary alignment signal.

#### Scenario: Spec Test Generation After Tier 0
- GIVEN tier 0 (bootstrap tier) has completed execution and merge.
- AND `spec_test_generation_enabled` is true.
- WHEN the orchestrator invokes `run_spec_test_generation!`.
- THEN the SpecTestGenerator agent uses a Testing Specialist persona to generate integration tests from the specification's GIVEN/WHEN/THEN scenarios.
- AND generated test files are written to `spec_test_directory` (default: `test/spec_integration`).
- AND the generation is tracked as a tier "0.5" event.

#### Scenario: Spec Test Progress Tracking After Each Tier
- GIVEN spec tests have been generated after tier 0.
- AND subsequent tiers have completed execution and merge.
- WHEN the orchestrator invokes `run_spec_test_progress!`.
- THEN the SpecTestProgressTracker runs the spec tests and compares results against previous runs.
- AND it calculates: `total_tests`, `total_passing`, `newly_passing`, `regressions`, `still_failing`, and `pass_rate`.
- AND progress summary is stored in `pipeline_run.metadata["spec_test_results"]`.
- AND the formatted summary is passed to the Analysis Agent via `spec_test_progress_summary:`.

#### Scenario: Spec Test Results Inform Iteration Decisions
- GIVEN the Analysis Agent evaluates code outputs against the specification.
- AND spec test progress shows `pass_rate: 0.60` (60% passing).
- WHEN the agent decides whether to iterate.
- THEN the spec test progression is used as a primary alignment signal alongside diff analysis.
- AND if pass rate is below acceptable thresholds, the agent may decide `iterate_tasks` to fix failing tests.

#### Scenario: Graceful Degradation Without Spec Test Generation
- GIVEN `spec_test_generation_enabled` is false.
- WHEN the pipeline executes.
- THEN spec test generation and progress tracking are skipped.
- AND the Analysis Agent operates without `spec_test_progress_summary:`.

#### DiffSummarizer Deduplication [SPEC-DIFF-001]

When multiple tasks within the same tier modify the same file, the DiffSummarizer SHALL keep only the latest entry per filename to prevent contradictory diffs.

#### Scenario: Deduplication of Same-File Modifications
- GIVEN an original task creates `app/controllers/users_controller.rb`.
- AND a corrective task modifies `app/controllers/users_controller.rb`.
- WHEN the DiffSummarizer processes both task results.
- THEN only the latest diff for `app/controllers/users_controller.rb` is included in the summary.
- AND the tier gate check receives a single, coherent diff per file.

#### Pipeline Event Types for Validation [SPEC-EVENT-006]

The system SHALL record event types for empirical validation:

| Event Type | Enum Value | Description |
|---|---|---|
| criteria_check | 15 | Records acceptance criteria evaluation results |
| verification_execution | 16 | DEPRECATED (replaced by verification_checks) |
| test_execution | 17 | DEPRECATED (replaced by verification_checks) |
| spec_test_execution | 18 | Records spec-scenario test execution results |
| post_merge_hooks | 19 | Records post-merge hook execution results |
| verification_checks | 20 | Records verification check execution results |
| stack_detection | 21 | Records stack detection results during brownfield analysis |
| codebase_profiling | 22 | Records LLM-driven codebase profiling results |
| feature_extraction | 23 | Records feature extraction from existing concerns |
| as_built_spec_generated | 24 | Records as-built specification generation |
| health_baseline | 25 | Records health baseline check execution results |
| test_name_collection | 26 | Records test name collection results during brownfield analysis |
| concern_diff_analysis | 27 | Records concern diff analysis results |
| file_manifest_built | 28 | Records file manifest build results during brownfield analysis |
| route_table_parsed | 29 | Records route table parsing results during brownfield analysis |
| git_activity_analyzed | 30 | Records git activity analysis results during brownfield analysis |
| parallel_agents_completed | 31 | Records parallel agent execution results during brownfield analysis |

#### Scenario: Validation Event Recording [SPEC-EVENT-007]
- GIVEN a tier completes execution and validation.
- AND `event_logging_enabled` is true.
- WHEN criteria are checked, hooks execute, verification checks run, or spec tests progress.
- THEN corresponding PipelineEvent records are created with summaries and optional payloads.

#### Scenario: Tier Gate Decision Source Metadata [SPEC-EVENT-008]
- GIVEN a tier gate evaluation completes.
- WHEN the `tier_gate_evaluated` pipeline event is recorded.
- THEN the event metadata includes a `decision_source` field indicating how the verdict was determined.
- AND `decision_source` is one of:
  - `verification_tests_passed` — Test suite verification passed, gate passes.
  - `verification_tests_failed` — Test suite verification failed, corrective tasks generated from failures.
  - `verification_required_failed` — A required verification check failed, gate fails immediately.
  - `llm_judgment` — No verification checks ran, LLM evaluated diffs directly.

### Requirement: Pause and Resume
The system SHALL support pausing execution at configurable stage checkpoints and resuming from the last completed stage.
Resume SHALL be idempotent: re-publishing already-published tasks is safely skipped.

#### Scenario: Stop After Checkpoint
- GIVEN a pipeline run with stop_after set to one of: :spec, :tasks, :executed.
- WHEN the corresponding stage completes.
- THEN the pipeline is paused with status "paused" and metadata records the paused_at checkpoint name.

#### Scenario: Resume from Paused State
- GIVEN a pipeline run in paused or failed status.
- WHEN resume is called.
- THEN the ResumeInferrer determines the next stage from DB state:
  - No specification present: resume from generate_spec.
  - No tasks present: resume from break_tasks.
  - Tasks without tiers or external_ids: resume from execute.
  - All tasks resolved: resume from analyze.

#### Scenario: Idempotent Task Publication
- GIVEN a pipeline run that was paused during execution with some tasks already published (having external_ids).
- WHEN execution resumes.
- THEN already-published tasks are skipped, and only unpublished tasks are sent to GitHub.

#### Scenario: Resolved Tier Skipping
- GIVEN a pipeline run resuming execution with some tiers fully resolved.
- WHEN TierExecutionEngine iterates through tiers.
- THEN tiers where all tasks are resolved (have results or are failed) are skipped entirely.

### Requirement: Pipeline Event Audit Trail
The system SHALL record structured pipeline execution events to provide observability into decision points and execution flow.
The system MUST support configurable event recording modes: disabled, summary-only (default), and verbose (full payloads).
Event recording SHALL be non-fatal: database errors during event creation do not interrupt pipeline execution.

#### Scenario: Pipeline Event Audit Trail [SPEC-EVENT-001]
- GIVEN the pipeline event system is enabled.
- WHEN a pipeline run executes through its stages.
- THEN structured PipelineEvent records are created capturing decisions at each stage.
- AND each event has an event_type, stage, summary, optional payload, and optional duration_ms.

#### Scenario: Default Event Recording [SPEC-EVENT-002]
- GIVEN event_logging_enabled is true (default).
- AND verbose_event_logging is false (default).
- WHEN a pipeline run completes.
- THEN events are recorded with summary data for each stage.
- AND payload fields are NULL (not stored).

#### Scenario: Verbose Event Recording [SPEC-EVENT-003]
- GIVEN event_logging_enabled is true.
- AND verbose_event_logging is true (set via --verbose CLI flag).
- WHEN a pipeline run completes.
- THEN events are recorded with both summary and full LLM payload data.

#### Scenario: Event Recording Disabled [SPEC-EVENT-004]
- GIVEN event_logging_enabled is false.
- WHEN a pipeline run completes.
- THEN no PipelineEvent records are created.

#### Scenario: Event Recording Failure is Non-Fatal [SPEC-EVENT-005]
- GIVEN a database error occurs during event recording.
- WHEN the PipelineEventRecorder attempts to create an event.
- THEN the error is silently rescued.
- AND the pipeline continues execution without interruption.

#### Scenario: Verbose Debug Logging [SPEC-OUTPUT-001]
- GIVEN the `--verbose` CLI flag is passed (or logger level is DEBUG).
- WHEN agents process LLM requests.
- THEN the BaseAgent logs prompt contents at DEBUG level: system prompt, each message role and content (truncated to 2000 characters).
- AND the BaseAgent logs LLM response size and content at DEBUG level (truncated to 2000 characters).
- AND the TierExecutionEngine logs at DEBUG level: gate issues triggering correction (numbered list), corrective task details (title, description, labels), and per-criterion acceptance criteria results (type and description).
- AND all DEBUG-level output is suppressed at the default INFO log level.

### Requirement: CLI Commands
The system SHALL provide a command-line interface via the `arnold_pipeline` executable.

#### Global Options [SPEC-CLI-GLOBAL-001]
All commands accept the following global options:
- `--quiet` — Suppress informational output.
- `--backtrace` — Show full error backtrace on failure. For LlmParseError, also shows the raw LLM response excerpt (first 500 chars).

#### Command: run
- GIVEN a natural language description as argument.
- WHEN `arnold_pipeline run DESCRIPTION` is executed.
- THEN the full pipeline runs with options: --config (YAML path), --provider (anthropic|openai|openrouter), --model (name), --repo (owner/repo), --issue-mention (@handle), --polling-interval (seconds), --polling-timeout (seconds), --stop-after (spec|tasks|executed), --preview/--dry-run (boolean, generate spec and tasks without publishing to GitHub), --verbose (boolean).
- Exit code 0 on success, 1 on error.

#### Command: resume
- GIVEN a pipeline run ID.
- WHEN `arnold_pipeline resume ID` is executed.
- THEN the paused or failed pipeline run resumes from its inferred stage with options: --config (YAML path), --stop-after (spec|tasks|executed), --verbose (boolean).
- Exit code 0 on success, 1 on error (including "not found" and "not resumable").

#### Command: status
- GIVEN a pipeline run ID.
- WHEN `arnold_pipeline status ID` is executed.
- THEN the run's status, input, task count, iteration count, and iteration details are displayed with options: --json (boolean).
- Exit code 0 on success, 1 if not found.

#### Command: list
- GIVEN no arguments.
- WHEN `arnold_pipeline list` is executed.
- THEN recent pipeline runs are listed with options: --limit (number, default 20), --json (boolean).
- Exit code 0 on success.

#### Command: spec
- GIVEN a pipeline run ID.
- WHEN `arnold_pipeline spec ID` is executed.
- THEN the specification content is output with options: --output/-o (file path), --json (boolean for structured data), --history (boolean, shows revision timeline with delta summaries), --version (number, shows spec content at a specific version).
- WHEN `--history` is passed, the revision timeline is displayed showing each version's change_source, timestamp, and delta_summary entries.
- WHEN `--version N` is passed, the spec content from SpecRevision version N is displayed (exit code 1 if version not found).
- Exit code 0 on success, 1 if not found or no specification exists.

#### Command: version
- WHEN `arnold_pipeline version` or `arnold_pipeline --version` is executed.
- THEN the gem version is printed.

#### Command: tree
- WHEN `arnold_pipeline tree` is executed.
- THEN a tree of all available commands is printed.

#### Command: log [SPEC-CLI-008]
- GIVEN a pipeline run with ID exists.
- WHEN `arnold_pipeline log ID` is executed.
- THEN the event timeline is displayed as a block-structured, color-coded report (see SPEC-CLI-009).
- WHEN the --stage flag is provided (e.g., `arnold_pipeline log ID --stage analysis`).
- THEN only events matching the specified stage are shown.
- WHEN the --json flag is provided.
- THEN events are output as a JSON array (color is suppressed; --no_color and --verbose are ignored for JSON mode).
- WHEN the --verbose flag is provided.
- THEN full payload data is included inline beneath each event line.
- WHEN the --no_color flag is provided, OR `$stdout` is not a TTY, OR the `NO_COLOR` environment variable is set.
- THEN ANSI color codes are omitted from the output.
- Options: --json (boolean), --stage (string), --verbose (boolean), --no_color (boolean, disables ANSI color).
- Exit code 0 on success, 1 if not found.

#### Scenario: Block-Structured Log Display [SPEC-CLI-009]
- GIVEN `arnold_pipeline log ID` is executed without --json.
- WHEN the LogFormatter renders events.
- THEN events are grouped into structural blocks rather than a flat chronological list:
  - **Preamble block** — Events before the first tier (e.g., library_selection, spec_generated, tasks_broken) rendered as plain indented lines.
  - **Tier blocks** — One block per tier, introduced by a `▶ TIER N  (M tasks)` header followed by bullet-listed task titles; tier stage is conveyed by the block header rather than per-event stage labels.
  - **Analysis blocks** — One block per analysis iteration, introduced by a `◆ ANALYSIS (iteration N)` header with optional duration.
  - **Terminal banner** — A styled final line for pipeline_completed (`✓ PIPELINE COMPLETED`), pipeline_failed (`✗ PIPELINE FAILED`), or pipeline_paused (`⏸ PIPELINE PAUSED`) with aggregate summary data (total iterations, task counts, duration, final confidence).
- AND tier and analysis blocks are visually separated from each other by a horizontal rule (`─` × 70).
- AND when --no_color is in effect, block headers and status badges are rendered as plain text without ANSI escape codes.

#### Command: iterate [SPEC-CLI-ITERATE-001]
- GIVEN a pipeline run ID and a natural language change request.
- WHEN `arnold_pipeline iterate ID "change request"` is executed.
- THEN the SpecIterationAgent generates structured deltas from the change request against the existing specification.
- AND the deltas are merged via the 3-tier merge chain (OpenSpec → structured append → legacy).
- AND a SpecRevision is created with change_source: "user_iterate".
- AND existing tasks (if any) are marked as `superseded`.
- Options: --config (YAML path), --provider (anthropic|openai|openrouter), --model (name), --dry-run (boolean), --json (boolean), --verbose (boolean), --yes/-y (boolean, skip confirmation).
- Exit code 0 on success, 1 on error (including "not found", invalid state, empty change request).

#### Scenario: Dry Run Preview [SPEC-CLI-ITERATE-002]
- GIVEN a pipeline run with an existing specification.
- WHEN `arnold_pipeline iterate ID "change request" --dry-run` is executed.
- THEN proposed deltas are displayed without applying them.
- AND the user is shown added/modified/removed requirements with rationale.
- AND no changes are persisted to the database.
- AND when --json is also passed, deltas are output as a JSON array.

#### Scenario: Iteration on Completed Run (Fork) [SPEC-CLI-ITERATE-003]
- GIVEN a pipeline run in `completed` state.
- WHEN `arnold_pipeline iterate ID "change request"` is executed.
- THEN a new pipeline run is created with `forked_from_run_id` in metadata.
- AND the new run's specification is seeded from the completed run's spec with applied deltas.
- AND the new run starts in `paused` state at the `spec` checkpoint.
- AND the user is shown the new run ID and instructed to use `arnold resume` to continue.

#### Scenario: Multiple Iterations Before Resume [SPEC-CLI-ITERATE-004]
- GIVEN a paused pipeline run that has been iterated multiple times (e.g., spec at v3).
- WHEN `arnold_pipeline resume ID` is executed.
- THEN task breakdown uses the latest spec version (v3).
- AND previously generated tasks with `superseded` status are ignored by the ResumeInferrer.
- AND the ResumeInferrer infers `:break_tasks` when all tasks are superseded.

#### Scenario: Stale Analysis After User Iteration [SPEC-CLI-ITERATE-005]
- GIVEN tasks were generated from spec version N.
- AND the user has iterated the spec to version N+1 (or higher) via the iterate command.
- WHEN the analysis loop evaluates results from the version-N tasks.
- THEN the analyzer is restricted to `done` or `iterate_tasks` decisions only.
- AND `iterate_spec` decisions are suppressed because the spec has already advanced past the task generation version.
- AND a pipeline event is recorded noting the version skew with `suppressed_from: "iterate_spec"` and `reason: "spec_version_skew"`.

#### Scenario: Delta-Scoped Task Generation for Forked Runs [SPEC-CLI-ITERATE-006]
- GIVEN a pipeline run was forked from a completed parent run via `iterate` on a completed run.
- AND the fork stored raw spec deltas in `pipeline_run.metadata["fork_deltas"]`.
- WHEN `break_tasks!` is called during resume of the forked run.
- THEN the TaskBreaker agent receives the deltas and generates tasks scoped ONLY to the changed requirements.
- AND the system prompt uses delta-scoped rules (no bootstrap task, no minimum task count).
- AND the user prompt instructs the LLM that the application is already built.
- AND the full spec is still provided as context so the LLM understands the broader application.
- AND when `fork_deltas` is absent from metadata (non-forked runs), task generation uses the standard full-spec behavior.

#### Command: mcp [SPEC-CLI-MCP-001]
- WHEN `arnold mcp` is executed.
- THEN the MCP (Model Context Protocol) server starts over stdio using JSON-RPC 2.0.
- AND the server listens for requests on stdin and writes responses to stdout.
- AND the server runs until stdin closes or a SIGINT/SIGTERM signal is received.
- Options: --config (YAML path).

#### Command: analyze [SPEC-CLI-ANALYZE-001]
- GIVEN a file path argument pointing to an existing directory.
- WHEN `arnold analyze PATH` is executed.
- THEN the system performs brownfield codebase analysis and produces a CodebaseProfile, HealthBaseline, and As-Built Specification.
- AND the profile summary is displayed (project name, detected stack, confidence score, concern status counts, health baseline pass/fail).
- WHEN the --json flag is provided.
- THEN the full profile data is output as JSON (project_name, stack, confidence, recipe_alignment, conventions, health_baseline, feature_inventories, documentation_fidelity, change_surface, token_budget_used, analyzed_at).
- WHEN the --output/-o flag is provided.
- THEN the as-built specification markdown is written to the specified file.
- Options: --config (YAML path), --provider (anthropic|openai|openrouter), --model (name), --reference-materials (array of file paths), --json (boolean), --verbose (boolean), --output/-o (file path).
- Exit code 0 on success, 1 on error (including directory not found).

### Requirement: Brownfield Codebase Analysis [SPEC-BROWNFIELD-001]
The system SHALL provide a brownfield analysis pipeline that produces a CodebaseProfile, HealthBaseline, and As-Built Specification from an existing codebase.
The analysis pipeline SHALL execute as a sequence of deterministic and LLM-driven steps, recorded via pipeline events under the "brownfield" stage.

#### Scenario: Stack Detection [SPEC-BROWNFIELD-002]
- GIVEN a path to an existing codebase directory.
- WHEN the StackDetector service is called.
- THEN the service scans the directory for language, framework, and tooling indicators using YAML-defined detection rules.
- AND returns a stack fingerprint hash containing language, framework, confidence score, and detected tooling.
- AND supports user-provided overrides via `stack_detection_overrides` configuration.
- AND supports additional detection rules via `additional_detection_rules_path` configuration.

#### Scenario: Artifact Discovery [SPEC-BROWNFIELD-003]
- GIVEN a repo path and a stack fingerprint.
- WHEN the ArtifactDiscoverer service is called.
- THEN the service scans for framework-specific artifacts (schema, routes, components, dependency manifests, entry points, ORM config, CI config) using YAML-defined artifact maps.
- AND the `components` role discovers UI files (views, templates, React components, layouts, hooks) per stack.
- AND returns an array of discovered artifacts with path, type, and metadata.
- AND supports additional artifact maps via `additional_artifact_maps_path` configuration.

#### Scenario: Overlay Resolution [SPEC-BROWNFIELD-004]
- GIVEN a stack fingerprint.
- WHEN the OverlayResolver service is called.
- THEN the service loads the appropriate framework overlay from YAML data files.
- AND returns framework-specific concern mappings, conventions, health check definitions, and `behavioral_files` glob patterns per concern.
- AND `behavioral_files` patterns are resolved by agents to identify which files contain behavioral implementation for each concern.

#### Scenario: Enhanced Deterministic Layer [SPEC-BROWNFIELD-010]
- GIVEN a repo path and a stack fingerprint.
- WHEN the brownfield analysis pipeline executes its deterministic pre-processing steps.
- THEN a FileManifestBuilder walks the repo tree, skips vendor directories, and parses files by language to produce an AST-like manifest of classes, methods, and modules.
- AND a RouteTableParser extracts HTTP endpoints from framework-specific route files (Rails, Django, Next.js).
- AND a GitActivityAnalyzer mines commit history (past 6 months) to produce file churn and authorship data.
- AND a TestNameCollector runs the test framework in dry-run mode, parses test names, and groups them by concern using keyword matching. Supports minitest, rspec, jest, pytest, and cargo.
- AND all deterministic results are packaged into an AnalysisContext (Data.define) alongside stack fingerprint, artifacts, overlay, concerns, reference materials, and change request.

#### Scenario: Parallel Specialized Agents [SPEC-BROWNFIELD-011]
- GIVEN an AnalysisContext and a FileContentCache (thread-safe, 50KB per-file limit).
- WHEN the ParallelAgentRunner executes the 5 specialized agents concurrently via threads.
- THEN each agent receives the shared context and file cache, uses `chat_json` with a strict JSON schema, and returns `{data:, tokens_used:}`.
- AND the 5 specialized agents are:
  - **DataModelAgent**: Analyzes models, associations, validations, callbacks, scopes, and business methods. Output schema: `data_model_analysis`.
  - **BusinessLogicAgent**: Extracts service objects, domain logic, state machines, and side effects. Output schema: `business_logic_analysis`.
  - **ControllerRouteAgent**: Documents HTTP endpoints, access control, input/output contracts. Output schema: `controller_route_analysis`.
  - **InfrastructureAgent**: Identifies conventions, framework concerns (auth, data_layer, API, etc.), and configuration patterns. Output schema: `infrastructure_analysis`.
  - **ViewUxAgent**: Maps views, pages, layouts, role-based adaptations, and JavaScript controllers. Output schema: `view_ux_analysis`.
- AND each agent result is wrapped in an AgentResult (agent_name, output, error, duration_ms, tokens_used).
- AND agent failures are isolated — one agent crashing does not prevent other agents from completing.
- AND per-agent model overrides are supported via `brownfield_agent_models` configuration.

#### Scenario: Synthesis Agent (As-Built Spec Generation) [SPEC-BROWNFIELD-012]
- GIVEN all 5 agent results, the concerns mapping, stack fingerprint, project name, and optional reference materials.
- WHEN the SynthesisAgent is called after all parallel agents complete.
- THEN it produces an OpenSpec-format specification document in Markdown reflecting the codebase's actual behavior.
- AND when reference materials are provided, they are included to produce a richer specification informed by product documentation.
- AND the specification is persisted as a Specification record with `spec_type: "as_built"`.

#### Scenario: Concern Diff Analysis [SPEC-BROWNFIELD-013]
- GIVEN an as-built specification, a change request, and a list of concern IDs.
- WHEN the ConcernDiffAnalyzer agent is called.
- THEN it uses `chat_json` with a strict schema to identify which concerns are affected by the change.
- AND each affected concern is classified as `modify`, `extend`, or `new` with a rationale.
- AND the output includes a `delta_concerns` array and a summary string.

#### Scenario: JSON Parse Repair [SPEC-BROWNFIELD-014]
- GIVEN an LLM response containing truncated JSON (unclosed brackets or braces).
- WHEN `BaseAgent#parse_json` fails to parse the response.
- THEN the repair mechanism counts unmatched openers (respecting string literals), appends the missing closers in reverse order, and reattempts parsing.
- AND trailing commas before closing brackets are stripped before repair.
- AND structural mismatches (e.g., `}` without a matching `{`) return nil instead of attempting repair.

#### Scenario: Health Baseline [SPEC-BROWNFIELD-008]
- GIVEN a repo path, convention inventory, and artifact map.
- WHEN the HealthBaselineRunner service is called.
- THEN the service executes health checks (boot, test suite, linter) with a configurable timeout (`health_baseline_timeout`).
- AND returns pass/fail results per check plus a summary.
- AND the health baseline is persisted as part of the CodebaseProfile.

#### Scenario: CodebaseProfile Persistence [SPEC-BROWNFIELD-009]
- GIVEN a completed brownfield analysis.
- WHEN all analysis steps succeed.
- THEN a CodebaseProfile record is created with: project_name, stack_fingerprint, recipe_alignment, conventions, health_baseline, change_surface, scan_data (including agent_results, file_manifest, route_table, git_activity, test_names), as_built_spec content, confidence, token_budget_used, and analyzed_at.
- AND the CodebaseProfile belongs to the PipelineRun.
- AND the PipelineRun transitions to `completed` status.

### Requirement: Drift Detection [SPEC-DRIFT-001]
The system SHALL provide a DriftDetector agent that analyzes completed pipeline work against the specification to identify divergence.
Drift findings SHALL be persisted as DriftFinding records and support resolution workflows.

#### Scenario: Structural Drift Detection [SPEC-DRIFT-002]
- GIVEN a pipeline run with completed tasks.
- WHEN drift detection runs at `structural` depth.
- THEN completed tasks with empty diffs are flagged as warnings ("completed task has no code changes").
- AND spec sections with no corresponding tasks are flagged as info ("spec section has no corresponding tasks").
- AND no LLM is required for structural checks (deterministic only).

#### Scenario: Behavioral Drift Detection [SPEC-DRIFT-003]
- GIVEN a pipeline run with completed tasks that have non-empty diffs.
- WHEN drift detection runs at `behavioral` or `full` depth.
- THEN an LLM compares task diff excerpts against the specification to identify behavioral divergence.
- AND only genuine issues are reported (not minor style differences).
- AND findings include domain, severity (critical/warning/info), description, spec_expectation, actual_state, and recommendation.

#### Scenario: Intent Drift Detection [SPEC-DRIFT-004]
- GIVEN a pipeline run with completed tasks.
- WHEN drift detection runs at `full` depth.
- THEN an LLM checks for completed work that does not map to any section of the specification (unrequested work).
- AND findings are typed as `intent` drift.

#### Scenario: Drift Scoping [SPEC-DRIFT-005]
- GIVEN a drift detection request with scope parameter.
- WHEN scope is `full`, all completed tasks are analyzed.
- WHEN scope is `domain` with a target label, only tasks matching that label are analyzed.
- WHEN scope is `task` with a target task ID, only that task is analyzed.

#### Scenario: Drift Resolution [SPEC-DRIFT-006]
- GIVEN a drift finding that is unresolved.
- WHEN resolution is `update_spec`, the SpecIterator generates deltas and the DeltaMerger applies them, creating a new SpecRevision.
- WHEN resolution is `update_code`, a corrective task is created with the finding details as description.
- WHEN resolution is `accept`, the finding is marked as accepted and excluded from future drift checks for the same spec revision.
- WHEN resolution is `ignore`, the finding is dismissed but may reappear on future drift checks.

### Requirement: MCP Server [SPEC-MCP-001]
The system SHALL expose a Model Context Protocol (MCP) server that enables external AI agents (e.g., Claude Code) to interact with pipeline data and operations through a standardized tool interface.
The server communicates via JSON-RPC 2.0 over stdio and implements the MCP protocol version `2025-03-26`.

#### Scenario: Server Initialization [SPEC-MCP-002]
- GIVEN the MCP server is started via `arnold mcp`.
- WHEN a client sends an `initialize` request.
- THEN the server responds with protocol version `2025-03-26`, capabilities `{ tools: {} }`, and server info (name: "arnold", version from gem).
- AND the server accepts a `notifications/initialized` notification without response.
- AND the server responds to `ping` with an empty result.

#### Scenario: Tool Registration and Discovery [SPEC-MCP-003]
- GIVEN the MCP server is running.
- WHEN a client sends `tools/list`.
- THEN the server returns all 20 registered tools with name, description, and JSON Schema input definitions.
- AND each tool implements the Base interface: `.tool_name`, `.description`, `.input_schema`, `.call(params, context)`.

#### Scenario: Tool Invocation [SPEC-MCP-004]
- GIVEN a registered tool name and valid arguments.
- WHEN a client sends `tools/call` with the tool name and arguments.
- THEN the tool is executed with the arguments and a shared Context object.
- AND the result is returned as `{ content: [{ type: "text", text: <JSON> }] }`.
- AND ArgumentError maps to error code -32602 (invalid params).
- AND all other errors map to error code -32603 (internal) with class, message, and source location.

#### Scenario: Pipeline Run Resolution [SPEC-MCP-005]
- GIVEN a tool call with an optional `run_id` parameter.
- WHEN `run_id` is provided, the Context resolves the specific PipelineRun by ID.
- WHEN `run_id` is omitted, the Context resolves the most recent PipelineRun.
- AND if no pipeline run is found, the tool returns `{ error: "No pipeline run found" }`.

### Requirement: MCP Tool Categories [SPEC-MCP-006]
The MCP server SHALL provide 20 tools organized into five categories: Discovery, Query, Task Lifecycle, Change Management, and Drift.

#### Discovery Tools
Read-only tools for exploring the product being built:
- `create_product` — Runs the orchestrator with `stop_after: :spec` and returns a product-level overview (name, summary, personas, domains, recipes, open questions). Requires description (minimum 10 characters).
- `describe_product` — Extracts a narrative product description from the spec's structured data, organized by persona and domain.
- `explore_domain` — Fuzzy-matches a domain name and returns its capabilities, relationships, and associated tasks.
- `explore_persona` — Returns a persona's journey, capabilities, pain points, and which domains they touch.
- `explore_capability` — Returns a detailed capability description, user flow, dependencies, and open questions.
- `explore_architecture` — Returns a structural view of the system by domain, including stack info, recipes, and components.
- `what_if` — Evaluates a hypothetical change against the spec without making any state changes.
- `get_history` — Returns a chronological list of spec revisions with product-level summaries of what changed.

#### Query Tools
Read-only tools for retrieving pipeline data:
- `get_spec` — Returns the specification content. Supports `format: "full"` (default) or `"summary"`.
- `get_tasks` — Returns the task list ordered by tier. Supports `status` and `tier` filters.
- `ask_engineer` — Answers a technical question grounded in the spec, recipes, and architectural constraints.
- `explain_recipe` — Returns a deep dive into a recipe: purpose, what it provides, framework configuration, trade-offs, and selection rationale.

#### Task Lifecycle Tools
Mutating tools for executing pipeline work:
- `start_task` — Transitions a task to `in_progress` and returns contextual guidance.
- `complete_task` — Stores a summary and list of files changed, returns tier progress.
- `report_issue` — Records an issue preventing task completion, returns a suggested resolution.
- `validate_tier` — Validates a completed tier against the spec (checks task completion, dependencies, and result data).

#### Change Management Tools
Mutating tools for evolving the specification:
- `propose_change` — Evaluates a change request against the spec via the SpecIterator agent (dry run). Returns an impact analysis with affected domains, personas, new/modified/removed capabilities, open questions, and a confidence level (high/medium/low). Returns a `change_id` for later confirmation.
- `confirm_change` — Applies a previously proposed change by its `change_id`. Creates a new spec revision and optionally invalidates affected tasks. Supports optional `answers` to questions raised during the proposal.

#### Drift Tools
Tools for detecting and resolving spec-vs-code divergence:
- `detect_drift` — Runs the DriftDetector agent with specified scope and depth, persists findings as DriftFinding records, and returns findings with coverage statistics. Accepted findings from the current spec revision are automatically excluded.
- `resolve_drift` — Resolves a drift finding by ID using one of four strategies: `update_spec`, `update_code`, `accept`, or `ignore` (see SPEC-DRIFT-006).

### Requirement: LLM Providers [SPEC-PROVIDER-001]
The system SHALL support pluggable LLM providers for spec generation, task breakdown, analysis, and brownfield agents. Each provider implements a common interface with two methods: `chat(messages:, system:)` for free-text responses and `chat_json(messages:, system:, schema:)` for structured JSON output. Providers are selected via the `llm_provider` configuration key and auto-detected from environment variables when not explicitly set.

#### Scenario: Provider Auto-Detection
- GIVEN no explicit `llm_provider` configuration is set.
- WHEN the system resolves the LLM provider.
- THEN it checks environment variables in priority order: `ANTHROPIC_API_KEY` (highest), `OPENAI_API_KEY`, `OPENROUTER_API_KEY` (lowest).
- AND the first non-empty key determines the provider.
- AND if no key is found, the provider defaults to `:anthropic`.

#### Scenario: Anthropic Provider [SPEC-PROVIDER-002]
- GIVEN `llm_provider` is `:anthropic`.
- WHEN the LLM client is built.
- THEN the system uses the `anthropic` gem with the Anthropic Messages API.
- AND API key is read from `ANTHROPIC_API_KEY` environment variable (or explicit configuration).
- AND the default model is `claude-sonnet-4-6`.
- AND `chat_json` uses Anthropic's tool_use mechanism with `tool_choice: { type: "tool" }` for structured output.
- AND truncation is detected via `stop_reason == "max_tokens"` and raises an error.

#### Scenario: OpenAI Provider [SPEC-PROVIDER-002a]
- GIVEN `llm_provider` is `:openai`.
- WHEN the LLM client is built.
- THEN the system uses the `ruby-openai` gem with the OpenAI Chat Completions API.
- AND API key is read from `OPENAI_API_KEY` environment variable (or explicit configuration).
- AND the default model is `gpt-5-mini-2025-08-07`.
- AND `chat_json` uses OpenAI's `response_format: { type: "json_schema" }` for structured output.
- AND truncation is detected via `finish_reason == "length"` and raises an error.

#### Scenario: OpenRouter Provider [SPEC-PROVIDER-003]
- GIVEN `llm_provider` is `:openrouter`.
- WHEN the LLM client is built.
- THEN the system uses the `ruby-openai` gem with `uri_base` set to `https://openrouter.ai/api/v1`.
- AND the request includes OpenRouter-specific headers: `HTTP-Referer: https://github.com/ArtifactHQ/Arnold` and `X-Title: Arnold Pipeline`.
- AND API key is read from `OPENROUTER_API_KEY` environment variable (or explicit configuration).
- AND the default model is `anthropic/claude-sonnet-4`.
- AND `chat_json` uses the same `response_format: { type: "json_schema" }` mechanism as the OpenAI provider.
- AND truncation is detected via `finish_reason == "length"` and raises an error.
- AND no additional gem dependency is required beyond the existing `ruby-openai` gem.

### Requirement: Configuration
The system SHALL be configurable via a Ruby block (`ArnoldPipeline.configure`) or YAML config file.
When multiple sources provide the same key, CLI flags take precedence over YAML config, which takes precedence over defaults (CLI > YAML > defaults).
The CLI's YAML config loader (`apply_config!`) MUST map all configuration keys listed in the table below. Omitting a key from the YAML loader silently drops user configuration, which is a bug.
All configuration keys SHALL be validated before pipeline execution via `validate!`.

| Key | Type | Default | Validation |
|---|---|---|---|
| llm_provider | Symbol | :anthropic | Must be :anthropic, :openai, or :openrouter |
| llm_api_key | String | ENV lookup | Required (non-empty) |
| llm_model | String | Provider default | None |
| execution_provider | Symbol | :github | Must be :github, :claude_code, :null, or a registered provider |
| github_token | String | ENV["GITHUB_TOKEN"] | Required when execution_provider is :github |
| github_repo | String | nil | Required when execution_provider is :github (format: "owner/repo") |
| github_issue_mention | String | nil | None |
| claude_code_repo_path | String | nil | Required when execution_provider is :claude_code (must be valid directory) |
| claude_code_model | String | "sonnet" | None |
| claude_code_max_turns | Integer | 25 | nil or positive integer |
| claude_code_permission_mode | String | "bypassPermissions" | Must be one of: acceptEdits, bypassPermissions, default, delegate, dontAsk, plan |
| claude_code_max_concurrency | Integer | 4 | 1-16 |
| claude_code_max_budget_usd | Numeric | nil | nil or positive number |
| claude_code_tools | Array of Strings | nil | nil or Array of Strings |
| claude_code_allowed_tools | Array of Strings | nil | nil or Array of Strings |
| claude_code_disallowed_tools | Array of Strings | nil | nil or Array of Strings |
| claude_code_task_timeout | Numeric | 30 | nil or positive number (minutes) |
| max_iterations | Integer | 3 | 1-10 |
| analysis_done_threshold | Integer | nil (disabled) | nil or 50-100 |
| library_path | String | nil (built-in library) | None |
| polling_interval | Numeric | 30 | Positive |
| polling_timeout | Numeric | 1800 | Positive |
| polling_max_interval | Numeric | 300 | Positive |
| tier_gate_enabled | Boolean | true | None |
| context_propagation_enabled | Boolean | true | None |
| max_tier_retries | Integer | 2 | 0-5 |
| workflow_status_enabled | Boolean | true | None |
| workflow_branch_pattern | Regexp | /issue[-_]?\d+/i | None |
| openspec_enabled | Boolean | true | None |
| openspec_cli_path | String | "openspec" | None |
| event_logging_enabled | Boolean | true | None |
| verbose_event_logging | Boolean | false | None |
| repo_context_scan_patterns | Array of Strings | nil (uses defaults) | None |
| repo_context_scan_files | Array of Strings | nil (uses defaults) | None |
| post_merge_hooks | Array of Hashes | [] | Each hash: name, trigger_paths, command, commit_paths (optional), commit_message (optional) |
| verification_checks | Array of Hashes | [] | Each hash: name, command, type (:boot/:test_suite/:custom), required (boolean) |
| criteria_check_mode | Symbol | :advisory | Must be :advisory, :gating, or :disabled. Controls whether acceptance criteria auto-fail gates. |
| test_timeout | Integer | 120 | Positive integer (used by SpecTestProgressTracker) |
| spec_test_generation_enabled | Boolean | false | None |
| spec_test_directory | String | "test/spec_integration" | None |
| spec_test_persona | String | "testing_specialist" | None |
| brownfield_mode | Symbol | nil | Must be :assess, :extend, or :strangle when set |
| reference_materials | Array | [] | Must be an Array |
| brownfield_scan_budget | Integer | 50000 | Positive integer (token budget for brownfield LLM analysis) |
| brownfield_deep_dive_domains | Array | nil | nil or Array of domain names for targeted deep analysis |
| convention_compliance_enabled | Boolean | false | None |
| regression_baseline_enabled | Boolean | true | None |
| stack_detection_overrides | Hash | {} | Must be a Hash |
| additional_detection_rules_path | String | nil | Path to additional YAML detection rules |
| additional_artifact_maps_path | String | nil | Path to additional YAML artifact maps |
| health_baseline_timeout | Integer | 120 | Positive integer (seconds for health check execution) |

### PipelineRun State Machine

The PipelineRun model uses a status enum with the following values and valid transitions:

| Status | Enum Value | Description |
|---|---|---|
| pending | 0 | Initial state, pipeline not yet started |
| generating_spec | 1 | Spec Generation Agent is running |
| breaking_tasks | 2 | Task Breakdown Agent is running |
| executing | 3 | Tasks are being executed (via GitHub API or local provider) |
| awaiting_results | 8 | Polling GitHub for task results |
| analyzing | 4 | Analysis Agent is evaluating results |
| completed | 5 | Pipeline finished successfully (terminal) |
| max_iterations_reached | 6 | Iteration limit hit (terminal) |
| failed | 7 | Pipeline encountered an error |
| paused | 9 | Pipeline paused at a checkpoint |

#### Valid State Transitions

```
pending -> generating_spec | executing | analyzing (brownfield) | failed
generating_spec -> breaking_tasks | failed | paused
breaking_tasks -> executing | failed | paused
executing -> awaiting_results | analyzing (sync providers) | failed | paused
awaiting_results -> analyzing | executing | failed | paused | max_iterations_reached
analyzing -> completed | max_iterations_reached | executing (iterate_tasks) | breaking_tasks (iterate_spec) | failed
paused -> generating_spec | breaking_tasks | executing | analyzing | failed
failed -> generating_spec | breaking_tasks | executing | analyzing
completed -> (terminal, no transitions)
max_iterations_reached -> (terminal, no transitions)
```

The `analyzing` state has branching transitions: `completed` and `max_iterations_reached` are terminal states; `executing` is reached via an `iterate_tasks` decision (new corrective tasks); `breaking_tasks` is reached via an `iterate_spec` decision (the spec is updated inline, then tasks are re-broken without a separate `generating_spec` pass). The `executing` → `analyzing` transition supports sync providers (e.g., Claude Code) that skip the `awaiting_results` polling stage. `pending` can transition directly to `executing` or `failed` for resume/restart paths. The `pending` -> `analyzing` transition supports the brownfield analysis path, which skips spec generation and task breakdown to directly analyze an existing codebase. `paused` and `failed` have explicit transition targets matching the stages they can resume into. Active stages may transition to `failed` on error; stages with a `stop_after` checkpoint may transition to `paused`.

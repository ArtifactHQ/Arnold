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
Execution providers implement a common interface: `create_tasks`, `fetch_results`, `merge_results`, and `async?`.
Async providers (e.g., GitHub) use polling to await results; sync providers (e.g., Claude Code) return results immediately.

#### Built-in Providers
- **GitHub** (`:github`) — Creates GitHub Issues, uses Actions/Copilot for execution, collects results from PRs. Supports `github_issue_mention` for @mention-based agent routing.
- **Claude Code** (`:claude_code`) — Executes tasks locally via the `claude` CLI in git worktrees. Sync provider (no polling).
- **Null** (`:null`) — Test-only provider that returns empty results.

Custom providers can be registered via `ArnoldPipeline::Providers::Execution.register(:name, ProviderClass)`.

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
- `change_source`: One of `"spec_generation"` (initial spec or re-generation) or `"iterate_spec"` (analysis-driven refinement).
- `delta_summary`: JSON array of human-readable strings summarizing what changed (e.g., `"ADDED: Authentication > Password Reset"`).
- The Orchestrator creates a SpecRevision after every `generate_spec!` call (change_source: `"spec_generation"`).
- The AnalysisLoop creates a SpecRevision after every successful delta merge (change_source: `"iterate_spec"`).

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
- WHEN the TierGateCheck agent evaluates the merged diffs and task summaries.
- THEN it returns a pass/fail verdict, a context_summary, and optionally corrective_tasks.

#### Scenario: Tier Gate Failure with Retry
- GIVEN a tier that failed the gate check.
- AND retry_count is less than max_tier_retries (default 2, range 0-5).
- WHEN the system retries.
- THEN corrective tasks from the gate result are created at the same tier, executed, merged, and re-evaluated.

#### Scenario: Tier Gate Retry Exhaustion
- GIVEN a tier that has failed the gate check max_tier_retries times.
- WHEN the retry limit is reached.
- THEN the pipeline is paused with status "paused", metadata records the tier_gate_failure details, and a TierGateError is raised.

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

### Requirement: CLI Commands
The system SHALL provide a command-line interface via the `arnold_pipeline` executable.

#### Command: run
- GIVEN a natural language description as argument.
- WHEN `arnold_pipeline run DESCRIPTION` is executed.
- THEN the full pipeline runs with options: --config (YAML path), --provider (anthropic|openai), --model (name), --repo (owner/repo), --issue-mention (@handle), --polling-interval (seconds), --polling-timeout (seconds), --stop-after (spec|tasks|executed), --preview/--dry-run (boolean, generate spec and tasks without publishing to GitHub), --verbose (boolean).
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

### Requirement: Configuration
The system SHALL be configurable via a Ruby block (`ArnoldPipeline.configure`) or YAML config file.
When multiple sources provide the same key, CLI flags take precedence over YAML config, which takes precedence over defaults (CLI > YAML > defaults).
All configuration keys SHALL be validated before pipeline execution via `validate!`.

| Key | Type | Default | Validation |
|---|---|---|---|
| llm_provider | Symbol | :anthropic | Must be :anthropic or :openai |
| llm_api_key | String | ENV lookup | Required (non-empty) |
| llm_model | String | Provider default | None |
| execution_provider | Symbol | :github | Must be :github, :claude_code, :null, or a registered provider |
| github_token | String | ENV["GITHUB_TOKEN"] | Required when execution_provider is :github |
| github_repo | String | nil | Required when execution_provider is :github (format: "owner/repo") |
| github_issue_mention | String | nil | None |
| claude_code_repo_path | String | nil | Required when execution_provider is :claude_code (must be valid directory) |
| claude_code_model | String | "sonnet" | None |
| claude_code_max_turns | Integer | nil | None |
| claude_code_permission_mode | String | "bypassPermissions" | Must be one of: acceptEdits, bypassPermissions, default, delegate, dontAsk, plan |
| max_iterations | Integer | 3 | 1-10 |
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
pending -> generating_spec | executing | failed
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

The `analyzing` state has branching transitions: `completed` and `max_iterations_reached` are terminal states; `executing` is reached via an `iterate_tasks` decision (new corrective tasks); `breaking_tasks` is reached via an `iterate_spec` decision (the spec is updated inline, then tasks are re-broken without a separate `generating_spec` pass). The `executing` → `analyzing` transition supports sync providers (e.g., Claude Code) that skip the `awaiting_results` polling stage. `pending` can transition directly to `executing` or `failed` for resume/restart paths. `paused` and `failed` have explicit transition targets matching the stages they can resume into. Active stages may transition to `failed` on error; stages with a `stop_after` checkpoint may transition to `paused`.

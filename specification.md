# Agentic Workflow Specification

## Purpose
This specification defines an agentic workflow for transforming natural language (NL) descriptions of applications into executable code using AI agents, integrated with GitHub for task orchestration and execution. The workflow includes spec generation from NL inputs using a library of agent personas and application recipes, task breakdown, execution via GitHub Issues/Actions/PRs, and a feedback loop for ensuring alignment through iterative analysis. The system SHALL prioritize automation, modularity, and alignment between specifications and implementations, enabling iterative refinement without human intervention where possible.

## Requirements

### Requirement: NL Input Processing
The system SHALL accept a natural language description of an application as input and transform it into a structured specification document.  
The system MUST retrieve and apply relevant agent personas and application recipes from a predefined library to guide the transformation.

#### Scenario: Basic Web App Description
- GIVEN an NL input: "Build a todo list app with user authentication, real-time updates, and mobile responsiveness."  
- AND a library containing personas (e.g., Software Architect) and recipes (e.g., Web App Recipe with sections for frontend, backend, database, auth).  
- WHEN the Spec Generation Agent processes the input.  
- THEN a structured specification document is produced in Markdown format with an embedded JSON metadata block, including sections for features, tech stack, data models, user flows, and edge cases, customized by the selected persona and recipe.

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

### Requirement: GitHub Integration
The system SHALL push generated tasks to GitHub as Issues using the GitHub API.
The system MUST support assignment to multiple AI coding agents (e.g., Claude Code, OpenAI Codex) within GitHub branches.
GitHub Issues serve as tasks, GitHub Actions or Copilot handle execution, and PRs manage results.

#### Scenario: Task Ingestion
- GIVEN a list of tasks from the Task Breakdown Agent.
- WHEN pushed via the GitHub API (e.g., creating Issues).
- THEN tasks appear as GitHub Issues, linked to the project repository, ready for agent assignment and execution.

#### Scenario: Multi-Agent Routing
- GIVEN tasks with labels.
- WHEN executed via GitHub.
- THEN the system SHOULD route tasks to appropriate agents based on strengths (e.g., frontend to a GitHub Actions job), monitoring progress via logs and status updates.

### Requirement: Feedback Loop for Alignment
The system SHALL implement a post-execution feedback loop using an Analysis Agent to evaluate code outputs against the original specification.
The system MUST decide whether to iterate on tasks (for implementation fixes) or the specification (for clarifications), with a configurable maximum iterations (default 3, range 1-10) to prevent infinite loops.
The system SHOULD use confidence scores (0-100%) as a reporting guideline to flag low-confidence decisions (below 70%) for human review. Confidence does not gate execution -- all decisions are acted on regardless of score.
The loop SHALL use GitHub API polling for PR/issue events.

#### Scenario: Task Iteration Due to Misalignment
- GIVEN code diffs from GitHub PRs that deviate from the spec (e.g., missing edge case handling).
- AND an Analysis Agent prompted with diffs, spec, and a Quality Assurance Analyst persona.
- WHEN analysis is performed.
- THEN if "iterate_tasks" is decided (with reasoning and confidence score), new corrective tasks are generated and pushed via the GitHub API for re-execution. Decisions with confidence below 70% are flagged for human review.

#### Scenario: Spec Iteration for Ambiguity
- GIVEN analysis revealing spec vagueness (e.g., unclear user flow).
- WHEN "iterate_spec" is decided.
- THEN the spec is refined (e.g., adding clarified sections), re-run through Task Breakdown, and tasks are regenerated from the refined specification, replacing all existing tasks.

#### Scenario: Loop Termination
- GIVEN alignment achieved after iterations or max iterations reached.
- WHEN final validation occurs.
- THEN changes are merged via GitHub API (e.g., PR merge), and the loop ends.

### Requirement: Library Management
The system SHALL maintain a library of agent personas and application recipes, stored as YAML files with keyword-based retrieval.
The system SHOULD support dynamic selection based on NL input keyword matching. Vector database semantic retrieval is a future consideration. [PLANNED]

#### Scenario: Persona and Recipe Selection
- GIVEN an NL input.
- WHEN keyword matching is performed against the library's persona and recipe keywords.
- THEN the most relevant persona (e.g., Domain Expert for fintech) and recipe (e.g., API Service) are retrieved and injected into prompts.

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
- THEN the full pipeline runs with options: --config (YAML path), --provider (anthropic|openai), --model (name), --repo (owner/repo), --issue-mention (@handle), --polling-interval (seconds), --polling-timeout (seconds), --stop-after (spec|tasks|executed), --dry-run (boolean), --verbose (boolean).
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
- THEN the specification content is output with options: --output/-o (file path), --json (boolean for structured data).
- Exit code 0 on success, 1 if not found or no specification exists.

#### Command: version
- WHEN `arnold_pipeline version` or `arnold_pipeline --version` is executed.
- THEN the gem version is printed.

### Requirement: Configuration
The system SHALL be configurable via a Ruby block (`ArnoldPipeline.configure`) or YAML config file.
All configuration keys SHALL be validated before pipeline execution via `validate!`.

| Key | Type | Default | Validation |
|---|---|---|---|
| llm_provider | Symbol | :anthropic | Must be :anthropic or :openai |
| llm_api_key | String | ENV lookup | Required (non-empty) |
| llm_model | String | Provider default | None |
| execution_provider | Symbol | :github | Must be :github |
| github_token | String | ENV["GITHUB_TOKEN"] | Required when execution_provider is :github |
| github_repo | String | nil | Required when execution_provider is :github (format: "owner/repo") |
| github_issue_mention | String | nil | None |
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

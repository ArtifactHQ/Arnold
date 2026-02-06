# Agentic Workflow Specification

## Purpose
This specification defines an agentic workflow for transforming natural language (NL) descriptions of applications into executable code using AI agents, integrated with VibeKanban for task orchestration or alternatively bypassing VibeKanban to use GitHub's native capabilities directly. The workflow includes spec generation from NL inputs using a library of agent personas and application recipes, task breakdown, execution in VibeKanban via Model Context Protocol (MCP) or via GitHub Issues/Actions/PRs, and a feedback loop for ensuring alignment through iterative analysis. The system SHALL prioritize automation, modularity, and alignment between specifications and implementations, enabling iterative refinement without human intervention where possible. The system SHOULD support a bypass mode to operate without VibeKanban, leveraging GitHub API for task management and execution.

## Requirements

### Requirement: NL Input Processing
The system SHALL accept a natural language description of an application as input and transform it into a structured specification document.  
The system MUST retrieve and apply relevant agent personas and application recipes from a predefined library to guide the transformation.

#### Scenario: Basic Web App Description
- GIVEN an NL input: "Build a todo list app with user authentication, real-time updates, and mobile responsiveness."  
- AND a library containing personas (e.g., Software Architect) and recipes (e.g., Web App Recipe with sections for frontend, backend, database, auth).  
- WHEN the Spec Generation Agent processes the input.  
- THEN a structured spec is produced in Markdown or JSON format, including sections for features, tech stack, data models, user flows, and edge cases, customized by the selected persona and recipe.

#### Scenario: Library Retrieval Failure
- GIVEN an NL input that does not match any library items (e.g., highly niche domain).  
- WHEN retrieval is attempted.  
- THEN the system SHOULD default to a generic persona (e.g., General Analyst) and recipe, logging the mismatch for human review.

### Requirement: Task Breakdown
The system SHALL break the generated specification into granular, actionable tasks suitable for AI coding agents.  
The system MUST prioritize tasks based on dependencies and label them (e.g., "frontend", "backend").

#### Scenario: Spec to Tasks Conversion
- GIVEN a structured spec from the previous requirement.  
- WHEN the Task Breakdown Agent processes it.  
- THEN a list of 5-20 tasks is outputted, each with title, description, priority, and labels, in a format ready for ingestion (e.g., JSON array).

#### Scenario: Dependency Handling
- GIVEN a spec with interdependent features (e.g., database setup before API endpoints).  
- WHEN tasks are generated.  
- THEN tasks SHALL be ordered or flagged with dependencies to prevent execution conflicts in VibeKanban or GitHub.

### Requirement: Integration with VibeKanban or GitHub Bypass
The system SHALL push generated tasks to VibeKanban using the Model Context Protocol (MCP) for orchestration and execution, or alternatively to GitHub using its API for bypass mode.  
The system MUST support assignment to multiple AI coding agents (e.g., Claude Code, OpenAI Codex) within isolated git worktrees or GitHub branches.  
The system SHOULD allow toggling bypass mode via configuration (e.g., CLI flag), where GitHub Issues serve as tasks, GitHub Actions or Copilot handle execution, and PRs manage results.

#### Scenario: Task Ingestion
- GIVEN a list of tasks from the Task Breakdown Agent.  
- WHEN pushed via MCP (e.g., using Claude Desktop or custom client) or GitHub API (e.g., creating Issues).  
- THEN tasks appear in VibeKanban's board (e.g., "To Do" column) or as GitHub Issues, linked to the project repository, ready for agent assignment and execution.

#### Scenario: Multi-Agent Routing
- GIVEN tasks with labels.  
- WHEN executed in VibeKanban or GitHub.  
- THEN the system SHOULD route tasks to appropriate agents based on strengths (e.g., frontend to Cursor Agent CLI via MCP executor or GitHub Actions job), monitoring progress via logs and status updates.

### Requirement: Feedback Loop for Alignment
The system SHALL implement a post-execution feedback loop using an Analysis Agent to evaluate code outputs against the original specification.  
The system MUST decide whether to iterate on tasks (for implementation fixes) or the specification (for clarifications), with a maximum of 3 iterations to prevent infinite loops.  
The system SHOULD use confidence scores (0-100%) to flag low-confidence decisions for human review.  
In bypass mode, the loop SHALL use GitHub webhooks or API polling for PR/issue events.

#### Scenario: Task Iteration Due to Misalignment
- GIVEN code diffs from VibeKanban execution or GitHub PRs that deviate from the spec (e.g., missing edge case handling).  
- AND an Analysis Agent prompted with diffs, spec, and a Quality Assurance Analyst persona.  
- WHEN analysis is performed.  
- THEN if "iterate_tasks" is decided (with reasoning and confidence > 70%), new corrective tasks are generated and pushed via MCP or GitHub API for re-execution.

#### Scenario: Spec Iteration for Ambiguity
- GIVEN analysis revealing spec vagueness (e.g., unclear user flow).  
- WHEN "iterate_spec" is decided.  
- THEN the spec is refined (e.g., adding clarified sections), re-run through Task Breakdown, and delta tasks pushed to VibeKanban or GitHub.

#### Scenario: Loop Termination
- GIVEN alignment achieved after iterations or max iterations reached.  
- WHEN final validation occurs.  
- THEN changes are merged via VibeKanban's Git tools (e.g., PR creation) or GitHub API (e.g., PR merge), and the loop ends.

### Requirement: Library Management
The system SHALL maintain a library of agent personas and application recipes, stored as JSON/YAML files or in a vector database for semantic retrieval.  
The system SHOULD support dynamic selection based on NL input similarity.

#### Scenario: Persona and Recipe Selection
- GIVEN an NL input.  
- WHEN semantic search is performed on the library.  
- THEN the most relevant persona (e.g., Domain Expert for fintech) and recipe (e.g., API Service) are retrieved and injected into prompts.

### Requirement: Extensibility and Automation
The system SHOULD be implemented as a Python script or chain (e.g., using LangChain) for orchestration, with MCP as the bridge to VibeKanban or GitHub API as the alternative.  
The system MAY integrate with external tools like GitHub webhooks for triggering feedback loops in both modes.

#### Scenario: Full End-to-End Run
- GIVEN an NL input through all stages including feedback.  
- WHEN the workflow executes autonomously, with optional bypass mode.  
- THEN a complete application is built in the repository, aligned to the refined spec, with logs tracking iterations.

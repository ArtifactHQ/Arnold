# Arnold Pipeline

## Project Overview
`arnold_pipeline` is a Ruby gem and Rails engine designed to orchestrate AI coding agents through a structured, multi-stage workflow. It transforms natural language descriptions into executable code by:
1.  **Generating Specifications:** Creating structured specs (OpenSpec format) from NL input.
2.  **Task Breakdown:** Decomposing specs into dependency-ordered tasks.
3.  **Execution:** Dispatching tasks to execution providers (GitHub Issues/PRs, Claude Code CLI).
4.  **Validation & Iteration:** Validating results via tier gate checks and iteratively refining the implementation through an analysis feedback loop.

The system is built on **Ruby (>= 4.0)** and **Rails (>= 8.0)**, utilizing `thor` for the CLI and various AI SDKs (`ruby-anthropic`, `ruby-openai`).

## Architecture
*   **Orchestrator:** The core state machine that manages the pipeline lifecycle (spec -> tasks -> execution -> analysis).
*   **Agents:** Stateless service objects (e.g., `SpecGenerator`, `TaskBreaker`, `Analyzer`) that encapsulate specific AI tasks.
*   **Providers:** Pluggable backends for LLM interaction (Anthropic, OpenAI) and Task Execution (GitHub, Claude Code).
*   **Library:** A system for loading Personas, Recipes, and Domain Types from YAML configuration.
*   **Data Models:** Rails models (`PipelineRun`, `Task`, `PipelineEvent`) for persisting state.

## Building and Running

### Prerequisites
*   Ruby >= 4.0
*   Bundler
*   SQLite3

### Setup
```bash
git clone https://github.com/ArtifactHQ/Arnold.git
cd arnold_pipeline
bundle install
```

### Testing
Run the full test suite:
```bash
bundle exec rails test
```
*   **Framework:** Minitest
*   **Mocking:** Mocha (`stubs` / `expects`)
*   **HTTP Mocking:** WebMock
*   **Job Testing:** `ActiveJob::TestCase`

### Linting
The project uses `rubocop-rails-omakase` for style enforcement.
```bash
bin/rubocop
```

### Mutation Testing
Mutation testing is configured via `.mutant.yml`.
```bash
bundle exec mutant run
```

### CLI Usage (Local Development)
To run the `arnold` CLI from the source:
```bash
bundle exec exe/arnold run "Build a todo app" --preview
```

## Development Conventions

### Code Style
*   Follow the **Omakase** Rails style.
*   Run `bin/rubocop` before committing.

### Testing Guidelines
*   **All changes require tests.**
*   **Stub External APIs:** Use WebMock for all external HTTP calls (Anthropic, GitHub, OpenAI).
*   **Stateless Agents:** Test agents as stateless services; stub them at the boundary, not internally.
*   **Configuration:** Call `ArnoldPipeline.reset_configuration!` in test teardown to prevent config leakage.

### Commit Messages
Use [Conventional Commits](https://www.conventionalcommits.org/):
*   `fix(scope): description`
*   `feat(scope): description`
*   `docs(scope): description`
*   `test(scope): description`
*   `chore(scope): description`
*   `refactor(scope): description`

**Common Scopes:** `cli`, `orchestrator`, `agents`, `config`, `provider`, `models`, `ci`.

### Directory Structure
*   `lib/arnold_pipeline/`: Core logic (Agents, Providers, Orchestrator).
*   `app/models/`: ActiveRecord models.
*   `library/`: YAML definitions for Personas, Recipes, etc.
*   `test/`: Test suite (unit and integration).
*   `exe/`: CLI executable.

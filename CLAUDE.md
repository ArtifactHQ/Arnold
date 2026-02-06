# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

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

**Analysis Agent** — Post-execution feedback loop. Compares code diffs against the spec using a QA Analyst persona. Decides `iterate_tasks` (implementation fixes) or `iterate_spec` (clarify ambiguities). Uses confidence scores (0–100%); flags low-confidence decisions (<70%) for human review. Hard cap of 3 iterations.

**Library Manager** — Maintains agent personas (Software Architect, Domain Expert, General Analyst, QA Analyst) and application recipes (Web App, API Service, etc.) as JSON/YAML files or in a vector database. Supports semantic retrieval based on NL input similarity. Falls back to a generic persona on mismatch.

## Key Design Constraints

- Tasks MUST be ordered by dependencies (e.g., database setup before API endpoints)
- The feedback loop MUST terminate after max 3 iterations
- The system should default to a generic persona when library retrieval fails
- Bypass mode uses GitHub webhooks or API polling for PR/issue events in the feedback loop
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

This project is in the **specification phase** — see `specification.md` for the full requirements document using Given-When-Then scenarios. No implementation code exists yet.

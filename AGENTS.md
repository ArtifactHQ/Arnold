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

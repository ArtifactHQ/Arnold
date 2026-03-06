# Contributing to Arnold Pipeline

Thank you for considering contributing to Arnold Pipeline.

## Prerequisites

- Ruby >= 4.0
- Bundler
- SQLite3 (for the test database)

## Setup

```bash
git clone https://github.com/ArtifactHQ/Arnold.git
cd arnold_pipeline
bundle install
```

## Running Tests

```bash
bundle exec rails test
```

All changes require tests. Run the full test suite before submitting a pull request and ensure there are no failures or errors.

## Test Conventions

- Use `mocha/minitest` for stubs and mocks (not `minitest/mock`)
- Use `WebMock` for HTTP stubs (Anthropic, GitHub, OpenAI APIs)
- Use `ActiveJob::TestCase` for job tests
- Call `ArnoldPipeline.reset_configuration!` in test teardown when modifying configuration
- Agents are stateless -- stub them at the boundary, not internally

## Code Style

This project uses [rubocop-rails-omakase](https://github.com/rails/rubocop-rails-omakase) for linting:

```bash
bin/rubocop
```

Follow existing patterns in the codebase. If you're unsure about a convention, look at how similar code is written elsewhere in the project.

## Commit Messages

Use conventional commit format:

```
fix(scope): description    # Bug fixes
feat(scope): description   # New features
docs(scope): description   # Documentation changes
test(scope): description   # Test additions or fixes
chore(scope): description  # Maintenance, CI, dependencies
refactor(scope): description  # Code changes that don't fix bugs or add features
```

Common scopes: `cli`, `orchestrator`, `agents`, `config`, `provider`, `models`, `ci`.

Examples:
- `fix(cli): handle missing config file with friendly error`
- `feat(orchestrator): add tier gate retry logic`
- `test(cli): add coverage for --config flag`

## Pull Request Process

1. One logical change per PR. Don't bundle unrelated fixes.
2. Reference the issue number in your PR description (e.g., "Fixes #42").
3. Add tests for any new functionality or bug fix.
4. Run `bundle exec rails test` and `bin/rubocop` before submitting.
5. Keep commits focused. Squash work-in-progress commits before requesting review.

## Adding Dependencies

Do not add new gem dependencies without opening an issue for discussion first. This is a library gem -- every dependency becomes a transitive dependency for consumers.

## Reporting Issues

Open an issue on GitHub with:
- What you expected to happen
- What actually happened
- Steps to reproduce
- Ruby and Rails versions

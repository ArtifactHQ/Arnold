---
name: Bug Report
about: Report a bug to help us improve Arnold Pipeline
title: '[BUG] '
labels: bug
assignees: ''
---

## Describe the Bug

A clear and concise description of what the bug is.

## To Reproduce

Steps to reproduce the behavior:

1. Configure Arnold with `...`
2. Run `arnold run "..." --execution-provider ...`
3. See error

## Expected Behavior

A clear and concise description of what you expected to happen.

## Actual Behavior

What actually happened. Include the full error message and stack trace if available.

## Environment

- Ruby version: (e.g., 4.0.0)
- Arnold Pipeline version: (e.g., 0.1.0 — run `arnold version`)
- Execution provider: github / claude_code / null
- LLM provider: anthropic / openai
- OS: (e.g., macOS 14, Ubuntu 22.04)

## Configuration

Share your Arnold configuration (omit API keys):

```ruby
ArnoldPipeline.configure do |config|
  config.llm_provider        = :anthropic
  config.execution_provider  = :github
  # ...
end
```

Or your `config.yml` (omit API keys).

## Additional Context

Any other context about the problem: logs from `arnold log ID --verbose`, pipeline run ID, whether it's intermittent, etc.

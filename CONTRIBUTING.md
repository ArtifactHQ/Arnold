# Contributing to Arnold

Arnold is a documentation-first development toolkit for Claude Code. It ships as
slash commands (markdown files in `commands/`), a `CLAUDE.md` template, and an
install script. There is no runtime and no server -- the value lives in prompt
engineering, not traditional code.

## Getting Started

1. Fork and clone the repo.
2. Read through `commands/` and `CLAUDE.md` to understand how the prompts work.
3. Make your changes.
4. Test by running the slash commands inside Claude Code against a real project.

## What to Contribute

- **Improve existing commands** -- sharpen wording, fix edge cases, reduce
  token usage.
- **Add new commands** -- drop a new `.md` file in `commands/arnold/` and reference it
  from `CLAUDE.md` if needed. Commands in the `arnold/` subdirectory are registered
  under the `/arnold:` namespace in Claude Code.
- **Improve the CLAUDE.md template** -- better defaults, clearer structure.
- **Fix the install script** -- compatibility, error handling, docs.

## Bug Reports and Feature Requests

Open a GitHub Issue. Include:

- What you expected vs. what happened.
- The command or workflow that triggered the problem.
- Any relevant Claude Code output.

## Pull Request Guidelines

- Keep PRs focused. One change per PR.
- Test your changes in Claude Code before submitting.
- Describe what you changed and why in the PR description.
- Prompt engineering changes should explain the reasoning behind wording choices.

## Style Notes

- Write clear, direct English. Avoid jargon.
- Keep markdown files concise -- shorter prompts cost fewer tokens.
- Do not add runtime dependencies. Arnold is markdown and shell only.

## License

By contributing, you agree that your contributions will be licensed under the
MIT License.

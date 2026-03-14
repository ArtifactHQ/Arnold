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
- **Add new commands** -- Arnold has a dual distribution structure. When adding a new
  command, you must add it to BOTH `commands/arnold/<name>.md` (for the install.sh
  path) AND `skills/<name>/SKILL.md` (for the Claude Code plugin path). Both files
  should contain the same prompt content. Commands in the `arnold/` subdirectory are
  registered under the `/arnold:` namespace in Claude Code.
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

## Repository Notes

- The `docs/` folder in this repo contains internal project documentation (build
  specs, migration plans). It is NOT example Arnold output. The worked example lives
  in `examples/fitness-studio-booking/`.

## Style Notes

- Write clear, direct English. Avoid jargon.
- Keep markdown files concise -- shorter prompts cost fewer tokens.
- Do not add runtime dependencies. Arnold is markdown and shell only.

## License

By contributing, you agree that your contributions will be licensed under the
MIT License.

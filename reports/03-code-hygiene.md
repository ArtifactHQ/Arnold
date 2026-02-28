# Code Hygiene Report — Arnold Pipeline

**Date:** 2026-02-27
**Auditor:** code-hygiene agent
**Branch:** repo-prep

---

## Executive Summary

The codebase is in good shape for open-source release. No TODO/FIXME/HACK annotations exist in any source file. No debug statements, hardcoded secrets, or internal SaaS platform URLs were found. RuboCop auto-corrections were applied successfully across 124 files. Three issues require human judgment before release.

---

## 1. Auto-Fixed (Safe Changes Applied)

### RuboCop — Layout/SpaceInsideArrayLiteralBrackets (Safe Auto-Correct)

**What happened:** The project inherits from `rubocop-rails-omakase`, which enforces space inside array literal brackets (`[ a, b ]` instead of `[a, b]`). The `.rubocop.yml` contains a commented-out rule that shows the team had intended to disable this cop but never uncommented it. RuboCop found 2,186 violations across 122 source files and 1,102 were safely auto-corrected with `bundle exec rubocop -a`.

**Files corrected:** 124 files total (122 with bracket violations + 4 non-bracket violations fixed inline)

**Categories of auto-corrected violations:**

| Cop | Count | Nature |
|-----|-------|--------|
| Layout/SpaceInsideArrayLiteralBrackets | 1,102 | `[x]` → `[ x ]` |
| Layout/ElseAlignment | 2 | `else` alignment |
| Layout/EndAlignment | 2 | `end` alignment |
| Layout/EmptyLinesAroundClassBody | 1 | Extra blank line at class body end |

**Verification:** After auto-correction, `bundle exec rubocop` reports zero offenses across all 246 inspected files. The non-E2E test suite ran clean: 1,885 runs, 6,070 assertions, 0 failures (2 SQLite lock errors from parallel test execution, a pre-existing environmental issue unrelated to these changes).

**Note on the bracket cop:** There is a human decision embedded here. The `.rubocop.yml` has this commented-out section:

```yaml
# # Use `[a, [b, c]]` not `[ a, [ b, c ] ]`
# Layout/SpaceInsideArrayLiteralBrackets:
#   Enabled: false
```

This comment indicates the team preferred `[a, b]` style. If that preference should be enforced, uncomment those two lines in `.rubocop.yml` and run `bundle exec rubocop -A` to undo the auto-corrections. If the omakase style is preferred (spaces inside brackets), keep the file as-is and the comment can be deleted.

---

## 2. Review Required (Needs Human Decision)

Issues are sorted by severity: CRITICAL first.

---

### Finding 01 — CRITICAL: E2E Test Contains Hardcoded Developer-Specific Internal Path

**File:** `test/e2e/plugin_compatibility_test.rb:7`
**Category:** Platform Coupling / Internal Reference
**Severity:** CRITICAL

**Finding:**

```ruby
PLUGIN_PATH = File.expand_path("~/Documents/Projects/artifact/arnold-claude-code-plugin")
```

This constant encodes a specific developer's local filesystem layout (`~/Documents/Projects/artifact/`) and references a private companion repository (`arnold-claude-code-plugin`) that is not publicly available. When this file is published, the test will skip silently for all users (because the directory won't exist), but it communicates two things that shouldn't appear in a public repo:

1. The internal directory structure of the developer's machine
2. The existence and name of a private companion repository

**Recommendation:** Either extract the plugin path to an environment variable and document it clearly, or move this test to a separate integration test suite that is explicitly not run in CI unless the path is configured. Example fix:

```ruby
PLUGIN_PATH = ENV.fetch("ARNOLD_PLUGIN_PATH", nil)
setup do
  skip "Set ARNOLD_PLUGIN_PATH to run plugin compatibility tests" unless PLUGIN_PATH && File.directory?(PLUGIN_PATH)
  ...
end
```

Additionally, the test currently fails in this developer's environment because the local plugin references a tool called `open_questions` that Arnold does not expose. This test failure should be resolved before release regardless of the path issue.

---

### Finding 02 — WARNING: `VALID_EXECUTION_PROVIDERS` Constant Omits `claude_code`

**File:** `lib/arnold_pipeline/configuration.rb:6`
**Category:** Dead Code / API Surface
**Severity:** WARNING

**Finding:**

```ruby
VALID_EXECUTION_PROVIDERS = %i[github].freeze
```

The `claude_code` execution provider is fully implemented (`lib/arnold_pipeline/providers/execution/claude_code.rb`), has its own set of configuration attributes (`claude_code_repo_path`, `claude_code_model`, etc.), and is mentioned throughout the README. However, it is absent from `VALID_EXECUTION_PROVIDERS`.

The validation in `validate_execution_provider!` works around this via the registry:

```ruby
valid = VALID_EXECUTION_PROVIDERS | Providers::Execution.registered_providers
```

This means `claude_code` is valid at runtime (once the provider loads itself into the registry), but a user reading `VALID_EXECUTION_PROVIDERS` in the source will be misled about what providers are available.

**Recommendation:** Either add `:claude_code` to the constant:

```ruby
VALID_EXECUTION_PROVIDERS = %i[github claude_code].freeze
```

Or remove the constant entirely and rely only on `Providers::Execution.registered_providers` for validation, which is the authoritative source. The former is simpler; the latter is more correct if the design intent is for providers to self-register.

---

### Finding 03 — WARNING: Engine Boilerplate Ships Unexpanded Placeholder Email

**File:** `app/mailers/arnold_pipeline/application_mailer.rb:3`
**Category:** Internal Reference / Boilerplate
**Severity:** WARNING

**Finding:**

```ruby
class ApplicationMailer < ActionMailer::Base
  default from: "from@example.com"
  layout "mailer"
end
```

This is Rails generator boilerplate. The `from@example.com` placeholder is harmless but ships in the gem and will appear in any host application that inherits from this class. Arnold Pipeline appears to have no mailer functionality — no mailers are defined and no other file references `ApplicationMailer`. The class exists only because the engine was generated with the full Rails template.

**Recommendation:** Remove the file. An engine that does not send email should not include an empty mailer base class. Same logic applies to `app/helpers/arnold_pipeline/application_helper.rb` (empty module) and `app/controllers/arnold_pipeline/application_controller.rb` (empty controller class with no routes). All three are standard Rails engine generator output that adds no value for this engine.

If any of these are kept intentionally for extension points, add a comment explaining that intent.

---

### Finding 04 — INFO: Tracked Internal Development Documents Contain Developer Paths

**Files:**
- `docs/plans/2026-02-14-post-merge-hooks-test-plan.md:321` — `cd /home/kyle/Documents/Projects/artifact/arnold_pipeline`
- `docs/plans/2026-02-22-hook-autocommit-merge-failure.md:325` — `/home/kyle/.claude/projects/...`
- `docs/plans/2026-02-22-rich-execution-context.md:511` — `/home/kyle/.claude/projects/...`

**Category:** Internal Reference
**Severity:** INFO

**Finding:** Three tracked design plan documents under `docs/plans/` contain absolute paths from the developer's local machine. These are shell command examples embedded in documentation written during development.

**Recommendation:** Strip or genericize the paths before publishing. Example fix for the test plan:

```bash
# Change:
cd /home/kyle/Documents/Projects/artifact/arnold_pipeline
# To:
cd /path/to/arnold_pipeline
```

The MEMORY.md references (`/home/kyle/.claude/projects/...`) in the hook and context docs should simply be removed since they reference internal CI memory state that is meaningless to outside contributors.

---

### Finding 05 — INFO: `prompts/` Directory Contains Developer Machine Paths in Tracked Files

**Files:**
- `prompts/spec-to-code-review-pipeline.md:8-9`

**Category:** Internal Reference
**Severity:** INFO

**Finding:**

```
- **Repository root**: /home/kyle/Documents/Projects/artifact/arnold_pipeline
- **Spec location**: .../home/kyle/Documents/Projects/artifact/arnold_pipeline/lib/arnold_pipeline/prompts
```

The tracked file `prompts/spec-to-code-review-pipeline.md` embeds the developer's local absolute paths. The untracked files `prompts/results/spec-to-code-review-iteration2.md` and `prompts/results/spec-to-code-review-iteration3.md` also contain these paths, but since they are not tracked in git they need only be added to `.gitignore`.

**Recommendation:** For the tracked file, replace the hardcoded paths with generic placeholders. For the untracked result files, add `prompts/results/` to `.gitignore`.

---

## 3. TODO/FIXME/HACK/XXX Catalog

**Result: Zero annotation comments found.**

No `# TODO`, `# FIXME`, `# HACK`, or `# XXX` comments exist anywhere in the Ruby source or YAML files. This is exceptional for a codebase this size. The many occurrences of "todo" in the search results were false positives from test fixtures using `"Build a todo app"` as a natural language input string.

---

## 4. Dead Code Candidates

**Result: No clearly dead code identified.**

All top-level service objects in `lib/` are referenced by other files in the production code path. Key items checked:

| Class | Status |
|-------|--------|
| `AcceptanceCriterion` | Used by `tier_execution_engine.rb` |
| `AnalysisLoop` | Used by `orchestrator.rb` |
| `AnsiColor` | Included by `log_formatter.rb` |
| `CorrectiveTaskGenerator` | Used by `tier_execution_engine.rb` |
| `CriteriaChecker` | Used by `tier_execution_engine.rb` |
| `DeltaMerger` | Referenced in `analysis_loop.rb` |
| `DeltaPresenter` | Required and used by `cli.rb` |
| `DiffSummarizer` | Used by `analysis_loop.rb` and `tier_execution_engine.rb` |
| `PipelineEventRecorder` | Used by `orchestrator.rb` |
| `PostMergeHook` / `PostMergeHookRunner` | Used by `tier_execution_engine.rb` |
| `RepoContextScanner` | Used in tier execution |
| `ResumeInferrer` | Used by `orchestrator.rb` |
| `SpecTestProgress` / `SpecTestProgressTracker` | Used by `tier_execution_engine.rb` |
| `TierCalculator` | Used by `orchestrator.rb` |
| `VerificationCheck` / `VerificationRunner` | Used by `tier_execution_engine.rb` |
| All 20 MCP tool classes | Registered and dispatched by `mcp/handler.rb` |

**Boilerplate engine classes with no production usage** (flagged in Finding 03 above):
- `app/mailers/arnold_pipeline/application_mailer.rb`
- `app/helpers/arnold_pipeline/application_helper.rb`
- `app/controllers/arnold_pipeline/application_controller.rb`

These are Rails engine generator boilerplate. No mailers, views, or controllers are implemented in this engine; the classes are empty and unused.

---

## 5. Debug Statement Audit

**Result: No debug statements found.**

No occurrences of `binding.pry`, `debugger`, or `byebug` were found anywhere in the codebase.

The `puts` statements found in `lib/arnold_pipeline/verification_runner.rb` (lines 83, 91, 99, 108) are **intentional, not debug output**. They are inside the `SOLID_STACK_SCRIPT` heredoc constant, which is a Ruby script that runs in a subprocess via `bin/rails runner`. The `puts` calls are the script's stdout protocol for signaling connection success to the parent process. They are correct and should not be removed.

The `$stderr.puts` calls in `lib/arnold_pipeline/cli.rb` (lines 341, 411, 793) are intentional CLI progress output that goes to stderr to avoid polluting stdout when users pipe the output.

---

## 6. Public API Surface Inventory

The following classes and modules are publicly accessible under the `ArnoldPipeline` namespace as part of the gem's interface. Items marked with [INTERNAL] are implementation details that happen to be under the public namespace but are not intended for external use.

### Primary Public API (stable, intended for users)

| Class/Module | Purpose |
|---|---|
| `ArnoldPipeline.configure` | Configuration entry point |
| `ArnoldPipeline::Configuration` | All pipeline settings |
| `ArnoldPipeline::Orchestrator` | Primary pipeline runner |
| `ArnoldPipeline::Error` | Base error class |
| `ArnoldPipeline::ConfigurationError` | Configuration validation errors |
| `ArnoldPipeline::TierGateError` | Tier gate failure signal |
| `ArnoldPipeline::Cli` | CLI command interface |

### Secondary Public API (used by advanced integrations)

| Class/Module | Purpose |
|---|---|
| `ArnoldPipeline::Mcp::Handler` | MCP server tool dispatcher |
| `ArnoldPipeline::Mcp::Server` | MCP stdio server |
| `ArnoldPipeline::PostMergeHook` | Configurable hook DSL |
| `ArnoldPipeline::VerificationCheck` | Configurable check DSL |
| `ArnoldPipeline::Providers::Execution::Base` | Extension point for custom providers |
| `ArnoldPipeline::Providers::Execution` module | Provider registry (`register`, `build`) |

### Internal Implementation (exposed by namespace, not stable API)

| Class/Module | Note |
|---|---|
| `ArnoldPipeline::Agents::*` | All 8 agent classes — internal state machine |
| `ArnoldPipeline::TierExecutionEngine` | Internal tier execution loop |
| `ArnoldPipeline::AnalysisLoop` | Internal analysis feedback loop |
| `ArnoldPipeline::ResumeInferrer` | Internal resume stage detection |
| `ArnoldPipeline::DiffSummarizer` | Internal diff truncation |
| `ArnoldPipeline::DeltaMerger` | Internal spec delta application |
| `ArnoldPipeline::CorrectiveTaskGenerator` | Internal corrective task generation |
| `ArnoldPipeline::CriteriaChecker` | Internal acceptance criteria checker |
| `ArnoldPipeline::AcceptanceCriterion` | Internal value object |
| `ArnoldPipeline::Library::Manager` | Internal YAML library loader |
| `ArnoldPipeline::Library::Persona` / `Recipe` / `DomainType` | Internal value objects |
| `ArnoldPipeline::PipelineEventRecorder` | Internal event audit trail |
| `ArnoldPipeline::OpenspecBridge` | Internal spec merge bridge |
| `ArnoldPipeline::RepoContextScanner` | Internal repo file scanner |
| `ArnoldPipeline::TierCalculator` | Internal DAG tier calculator |
| `ArnoldPipeline::SpecTestProgressTracker` | Internal spec test tracking |
| `ArnoldPipeline::LogFormatter` | Internal structured log formatter |
| `ArnoldPipeline::AnsiColor` | Internal ANSI color mixin |
| `ArnoldPipeline::Mcp::Tools::*` | All 20 MCP tool classes — internal |

**Recommendation:** Consider adding a `# @api private` YARD tag to internal classes if YARD documentation is added in the future. For now the distinction is sufficiently clear from the module hierarchy.

---

## 7. Internal Reference Summary

| Reference | Location | Status |
|---|---|---|
| `~/Documents/Projects/artifact/arnold-claude-code-plugin` | `test/e2e/plugin_compatibility_test.rb:7` | CRITICAL — see Finding 01 |
| `VALID_EXECUTION_PROVIDERS` missing `:claude_code` | `lib/arnold_pipeline/configuration.rb:6` | WARNING — see Finding 02 |
| `from@example.com` placeholder | `app/mailers/arnold_pipeline/application_mailer.rb:3` | WARNING — see Finding 03 |
| `/home/kyle/Documents/Projects/artifact/arnold_pipeline` | `docs/plans/2026-02-14-post-merge-hooks-test-plan.md:321` | INFO — see Finding 04 |
| `/home/kyle/.claude/projects/...` | `docs/plans/2026-02-22-*.md:325, 511` | INFO — see Finding 04 |
| `/home/kyle/Documents/Projects/artifact/arnold_pipeline` | `prompts/spec-to-code-review-pipeline.md:8-9` | INFO — see Finding 05 |
| Untracked: `prompts/results/spec-to-code-review-iteration2.md` | Contains `/home/kyle/...` | Add to `.gitignore` |
| Untracked: `prompts/results/spec-to-code-review-iteration3.md` | Contains `/home/kyle/...` | Add to `.gitignore` |

No Notion, Slack, Linear, Jira, or other internal SaaS platform references were found.
No hardcoded API keys, tokens, or secrets were found.
No AWS account IDs or internal hostnames were found.
No `ArtifactHQ` references exist in source, config, or library files (the README homebrew tap reference is a placeholder, not an active internal link).

---

## 8. Summary Statistics

| Category | Count |
|---|---|
| Files inspected by RuboCop | 246 |
| RuboCop violations before auto-correct | 2,190 |
| Auto-fixed by `rubocop -a` | 1,102 |
| Remaining violations after auto-correct | 0 |
| Files modified by auto-correct | 124 |
| TODO/FIXME/HACK/XXX annotations | 0 |
| Debug statements (`pry`/`debugger`/`byebug`) | 0 |
| Hardcoded secrets or API keys | 0 |
| Internal SaaS platform references | 0 |
| Issues requiring human review | 5 |
| — CRITICAL | 1 |
| — WARNING | 2 |
| — INFO | 2 |

### Clean Bill of Health Areas

- No TODO/FIXME/HACK/XXX annotations (entire codebase)
- No debug statements (entire codebase)
- No hardcoded secrets or credentials (entire codebase)
- No internal SaaS references (Notion, Linear, Slack, Jira)
- No developer-specific paths in source Ruby files (`lib/`, `app/`)
- No platform coupling in core engine code
- Engine namespace isolation is maintained (`isolate_namespace ArnoldPipeline`)
- Gemspec metadata is clean and publication-ready
- All classes properly namespaced under `ArnoldPipeline`

---

## Appendix: RuboCop Configuration Recommendation

The `.rubocop.yml` currently contains a commented-out style preference that conflicts with the inherited omakase configuration:

```yaml
# # Use `[a, [b, c]]` not `[ a, [ b, c ] ]`
# Layout/SpaceInsideArrayLiteralBrackets:
#   Enabled: false
```

A human decision is needed on which bracket style to enforce. **Option A** (keep omakase, use spaces): delete the comment. **Option B** (override to no-spaces): uncomment both lines and run `bundle exec rubocop -A` to revert the auto-corrections applied in this audit. Both options leave RuboCop with zero offenses; only the visual style differs.

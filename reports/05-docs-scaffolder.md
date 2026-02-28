# Documentation Audit Report — Arnold Pipeline

**Audit Date:** 2026-02-27
**Auditor:** docs-scaffolder agent
**Branch:** repo-prep

---

## Summary

| Area | Status |
|------|--------|
| Community Health Files | 4/5 present (CODE_OF_CONDUCT.md missing) |
| YARD Coverage | ~1.8% (11/610 def methods have doc comments) |
| Gemspec Metadata | 7/11 fields complete (missing 4 recommended/security fields) |
| GitHub Issue Templates | Present and well-formed |
| README Quality | 6 issues found (1 critical: private Homebrew tap) |

---

## 1. File Presence Checklist

| File | Status | Notes |
|------|--------|-------|
| `README.md` | PRESENT | 1190 lines, comprehensive |
| `CONTRIBUTING.md` | PRESENT | Well-formed, project-specific |
| `CHANGELOG.md` | PRESENT | Keep a Changelog format, has [Unreleased] section |
| `CODE_OF_CONDUCT.md` | MISSING | See recommendation below |
| `.github/ISSUE_TEMPLATE/bug_report.md` | PRESENT | Project-specific, includes Arnold config section |
| `.github/ISSUE_TEMPLATE/feature_request.md` | PRESENT | Well-formed |
| `.github/pull_request_template.md` | PRESENT | Includes CHANGELOG and rubocop checklist items |

**Note on CODE_OF_CONDUCT.md:** This file is missing. The maintainer should add the
[Contributor Covenant v2.1](https://www.contributor-covenant.org/version/2/1/code_of_conduct/)
manually. A template is available at https://www.contributor-covenant.org/. It should be placed
at `/CODE_OF_CONDUCT.md` in the project root.

---

## 2. README Audit Findings

The README is substantive (1190 lines) and covers the pipeline architecture, all CLI commands,
configuration reference, provider setup, and Rails integration. The overall structure is solid.

### Critical Issue

**Line 107 — Private Homebrew tap in installation instructions:**
```bash
brew tap ArtifactHQ/arnold && brew install arnold
```
`ArtifactHQ` is the private organization used during development. This Homebrew tap does not
exist publicly. The `(or: gem install arnold_pipeline)` fallback comment buried inside that
code block is easily missed. This must be corrected before open-source publication. The
primary installation instruction for a gem should be `gem install arnold_pipeline`, not a
private tap.

**Recommended replacement for the MCP Plugin `### Installation` block:**
```bash
# 1. Install Arnold
gem install arnold_pipeline

# 2. Verify arnold is on your PATH
which arnold

# 3. Install the Claude Code plugin
claude plugin add arnold
```

### Standard Section Presence

| Section | Status |
|---------|--------|
| Project description / positioning | PRESENT — clear standalone positioning in first paragraph |
| How the pipeline works (architecture) | PRESENT — ASCII diagram at line 7 |
| Quick Start / CLI usage | PRESENT — `## Quick Start (Standalone CLI)` at line 43 |
| `gem install arnold_pipeline` instruction | PRESENT — line 48 in Quick Start |
| Gemfile / Rails integration install | PRESENT — `## Rails Integration` at line 477 |
| Configuration reference | PRESENT — `## Configuration Reference` at line 341 (and again at 651) |
| Execution providers | PRESENT |
| Contributing link | PRESENT |
| License | PRESENT — MIT, line 1188 |
| CI badge | MISSING |
| License badge | MISSING |

### Missing: CI and License Badges

The README has no status badges at the top. For an open-source gem, a CI badge and license
badge are expected. Recommended additions at the top of README.md, just below the title:

```markdown
[![CI](https://github.com/arnold-pipeline/arnold_pipeline/actions/workflows/ci.yml/badge.svg)](https://github.com/arnold-pipeline/arnold_pipeline/actions/workflows/ci.yml)
[![Gem Version](https://badge.fury.io/rb/arnold_pipeline.svg)](https://badge.fury.io/rb/arnold_pipeline)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
```

Note: the Gem Version badge will only be active once the gem is published on RubyGems.org.

### Minor Issues

| Line | Finding |
|------|---------|
| 49 | `sk-ant-...` and similar placeholder key values are appropriate context in docs — acceptable |
| 51, 61–65, 74, 82, 621, 627, 631 | "todo list app" examples are example prompts, not placeholder content — false positive in grep, acceptable |
| 482 | `gem "arnold_pipeline"` uses double quotes (Rails convention) — consistent with the rest of the file, acceptable |
| 1190 | License section only says "MIT" with no link to the LICENSE file or full license text. Consider adding `[MIT License](./MIT-LICENSE)` for navigability. |
| — | `## Configuration Reference` appears **twice** (lines 341 and 651). The second occurrence has overlapping but slightly different content. These should be consolidated into one canonical section to avoid consumer confusion. |

### Positioning Assessment

The README correctly positions Arnold as standalone infrastructure. The opening paragraph
explicitly states "Arnold is not another AI code editor. It doesn't write code itself." The
tool-agnostic execution provider system is clearly explained. No internal company jargon or
private infrastructure assumptions are present beyond the `ArtifactHQ` tap noted above.

---

## 3. CONTRIBUTING.md Assessment

The existing `CONTRIBUTING.md` is **well-formed and project-specific**. No scaffolding needed.

It covers:
- Prerequisites (Ruby >= 4.0, Bundler, SQLite3)
- Setup (`git clone`, `bundle install`)
- Running tests (`bundle exec rails test`)
- Test conventions (mocha, WebMock, `reset_configuration!`, agent boundary stubs)
- Code style (rubocop-rails-omakase, `bin/rubocop`)
- Commit message conventions (conventional commits with project-specific scopes)
- Pull request process
- Dependency addition policy
- Issue reporting guidance

**No scaffolding performed** — the file is substantive.

---

## 4. Files Scaffolded

No files were scaffolded during this audit. All required community health files that are
scaffoldable (`CONTRIBUTING.md`, issue templates, PR template) are already present with
project-specific content.

---

## 5. YARD Documentation Coverage

YARD coverage is critically low. Analysis of all 85 Ruby files in `lib/`:

| Metric | Value |
|--------|-------|
| Total `def` methods in `lib/` | 610 |
| Methods with a preceding `#` comment | 11 |
| Methods without any doc comment | 599 |
| Coverage | ~1.8% |

The 11 documented methods appear to be incidental single-line `#` comments above convenience
methods, not structured YARD annotations (`@param`, `@return`, `@example`).

### Public API — Undocumented Classes (Priority Order)

These are the highest-impact undocumented surfaces for a gem consumer:

**`lib/arnold_pipeline.rb`** — Module root (`configure`, `configuration`, `reset_configuration!`)
No class-level module doc. These three methods are the primary entry point for every consumer.

**`lib/arnold_pipeline/configuration.rb`** — All configuration keys
No class-level doc. The README has a configuration reference table, but the class itself has
no YARD docs — IDE autocompletion and `ri` lookups will show nothing.

**`lib/arnold_pipeline/orchestrator.rb`** — Core pipeline driver
Methods `call`, `resume`, `iterate_spec`, `iterate_spec_dry_run`, `fork` — all undocumented.
These are the primary programmatic API.

**`lib/arnold_pipeline/library/manager.rb`** — Library retrieval
Methods `find_persona`, `find_recipe`, `find_recipes`, `find_domain_type`, `all_personas`,
`all_recipes`, `all_domain_types` — all undocumented.

**`lib/arnold_pipeline/providers/execution/base.rb`** — Provider contract
Abstract interface methods `create_tasks`, `fetch_results`, `merge_results`, `async` —
all undocumented. Anyone building a custom execution provider has no inline contract to
reference.

**`lib/arnold_pipeline/providers/llm/base.rb`** — LLM provider contract
Methods `chat`, `chat_json` — undocumented.

**`lib/arnold_pipeline/agents/base_agent.rb`** — Agent base class
`call` method — undocumented.

### Sample of Undocumented Internal Services (non-exhaustive)

The following are also undocumented, though they matter less for external consumers:

- `lib/arnold_pipeline/tier_calculator.rb` — `call`, `compute_tier`
- `lib/arnold_pipeline/corrective_task_generator.rb` — all methods
- `lib/arnold_pipeline/verification_runner.rb` — all methods
- `lib/arnold_pipeline/tier_execution_engine.rb` — all methods
- `lib/arnold_pipeline/post_merge_hook_runner.rb` — all methods
- `lib/arnold_pipeline/mcp/tools/*.rb` — all MCP tool classes (20+ files)

**Recommendation:** Prioritize YARD documentation for the 5 public-facing surfaces above.
Internal service objects can be documented progressively. Even minimal `@param`/`@return`
annotations on `ArnoldPipeline.configure`, `Orchestrator#call`, and the provider base
contracts would meaningfully improve the developer experience.

---

## 6. Gemspec Metadata Completeness

File: `arnold_pipeline.gemspec`

| Field | Status | Value / Note |
|-------|--------|-------------|
| `spec.name` | PRESENT | `"arnold_pipeline"` |
| `spec.version` | PRESENT | Via `ArnoldPipeline::VERSION` |
| `spec.summary` | PRESENT | Meaningful one-liner |
| `spec.description` | PRESENT | Meaningful multi-sentence description |
| `spec.authors` | PRESENT | `["Arnold Pipeline Contributors"]` — generic but acceptable for a community gem |
| `spec.email` | WARNING | `["arnold@example.com"]` — this is a placeholder email address. Should be updated to a real maintainer email or a project mailing list before publishing. |
| `spec.homepage` | PRESENT | `"https://github.com/arnold-pipeline/arnold_pipeline"` — valid URL format |
| `spec.license` | PRESENT | `"MIT"` |
| `spec.metadata["homepage_uri"]` | PRESENT | Set to `spec.homepage` |
| `spec.metadata["source_code_uri"]` | PRESENT | Set to `spec.homepage` |
| `spec.metadata["changelog_uri"]` | PRESENT | `"#{spec.homepage}/blob/master/CHANGELOG.md"` |
| `spec.metadata["bug_tracker_uri"]` | MISSING | Should be `"#{spec.homepage}/issues"` |
| `spec.metadata["documentation_uri"]` | MISSING | Should point to RubyDoc or README — e.g., `"#{spec.homepage}#readme"` |
| `spec.metadata["rubygems_mfa_required"]` | MISSING | Should be `"true"` — RubyGems security best practice. Required for gems with trusted publisher setup. |

**Summary: 8/11 fields acceptable, 3 gaps to address before publishing.**

Recommended additions to `arnold_pipeline.gemspec`:

```ruby
spec.email       = [ "maintainers@arnold-pipeline.org" ]  # Replace placeholder

spec.metadata["bug_tracker_uri"]    = "#{spec.homepage}/issues"
spec.metadata["documentation_uri"]  = "#{spec.homepage}#readme"
spec.metadata["rubygems_mfa_required"] = "true"
```

---

## 7. Recommendations for README Improvements

### Required Before Open-Source Publication

1. **Remove the `ArtifactHQ` Homebrew tap** (line 107). Replace with `gem install arnold_pipeline`
   as the primary installation instruction for the MCP plugin section.

2. **Fix the placeholder email in gemspec** — `arnold@example.com` will appear on the RubyGems
   listing page and cause confusion. Use a real maintainer email.

### Strongly Recommended

3. **Add CI and license badges** at the top of README.md. These are the first thing open-source
   evaluators look for to assess project health.

4. **Add `spec.metadata["rubygems_mfa_required"] = "true"`** to the gemspec. This enables
   RubyGems trusted publisher protection.

5. **Consolidate the duplicate `## Configuration Reference` sections** (lines 341 and 651).
   The first is focused on the CLI/YAML config; the second on Rails integration config. Consider
   merging into one canonical reference or renaming the second to `### Rails Configuration`
   under `## Rails Integration`.

6. **Add a link from the `## License` section** to the actual `MIT-LICENSE` file, e.g.:
   ```markdown
   ## License
   [MIT](./MIT-LICENSE)
   ```

### Progressive Improvements (Post-Launch)

7. **Add YARD documentation** to at minimum: `ArnoldPipeline` module methods, `Configuration`
   attributes, `Orchestrator#call`, `Orchestrator#resume`, and the execution/LLM provider
   base class contracts. These are what IDE tooling and `ri` lookups surface.

8. **Add `CODE_OF_CONDUCT.md`** using Contributor Covenant v2.1. This is expected by GitHub's
   community health scoring and signals a welcoming project to contributors.

9. **Expand `CHANGELOG.md`** — the current [Unreleased] section lists major features but
   the `[0.1.0] - Unreleased` entry at the bottom is contradictory. Once the gem is published
   on RubyGems, move that content to a proper `[0.1.0] - YYYY-MM-DD` entry.

10. **Add `bug_tracker_uri` and `documentation_uri`** to gemspec metadata. These appear
    on the RubyGems.org gem page and improve discoverability.

---

## Actions Taken

No files were created or modified during this audit. All required scaffoldable files
(`CONTRIBUTING.md`, issue templates, PR template) are already present with project-specific
content of acceptable quality.

The items listed under "Recommendations" require human judgment to implement correctly,
particularly the email address, badge URLs (which depend on the public repo slug), and
YARD documentation content (which requires accurate understanding of each method's behavior).

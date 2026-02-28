# Arnold Pipeline — Open-Source Readiness Audit Summary

**Date:** 2026-02-27
**Repository:** arnold_pipeline
**Branch:** repo-prep
**Verdict:** CONDITIONAL

## Dashboard

| Agent | Status | Blocking Issues | Warnings |
|-------|--------|-----------------|----------|
| secrets-scanner | ✅ | 0 | 1 (gitignore gaps, now fixed) |
| license-auditor | ❌ | 2 | 2 |
| code-hygiene | ✅ | 0 | 3 |
| test-auditor | ⚠️ | 0 | 5 |
| docs-scaffolder | ⚠️ | 0 | 4 |
| release-readiness | ❌ | 3 | 3 |

## Blocking Issues (must fix before going public)

### License (2)

1. **MIT-LICENSE has placeholder copyright holder** — reads `Copyright TODO: Write your name`. A license without a named copyright holder is not legally valid. Replace with the actual copyright owner (e.g., `Copyright (c) 2024-2026 ArtifactHQ`).

2. **`mutant` / `mutant-minitest` use a proprietary EULA** — classified as "Nonstandard" on RubyGems. The actual license is a commercial EULA with a free tier for OSS. This is a material compliance concern for downstream users. **Action:** Confirm OSS free-tier eligibility and document this explicitly, OR move `mutant` to a development-only group that is not a runtime dependency.

### Release (3)

3. **Gemspec `email` is placeholder** — `arnold@example.com` must be replaced with a real contact email before publishing to RubyGems.

4. **Gemspec `homepage` points to non-existent org** — `https://github.com/arnold-pipeline/arnold_pipeline` returns 404. Should be `https://github.com/ArtifactHQ/arnold_pipeline` (or wherever the public repo will live). All metadata URIs inherit this wrong base URL.

5. **No git tag for v0.1.0** — Must tag the release commit before publishing.

## Warnings (should fix, not blocking)

### Secrets / Security
1. `.gitignore` was missing 8 patterns (`.env`, `*.pem`, `*.key`, `config/master.key`, etc.) — **auto-fixed** by secrets-scanner agent.

### License
2. `diff-lcs` is triple-licensed (MIT / Artistic / GPL) — project should document that it elects the MIT option in a NOTICE file.
3. **0% copyright header coverage** — none of 181 `.rb` files have `frozen_string_literal` pragmas or copyright notices.

### Code Hygiene
4. `test/e2e/plugin_compatibility_test.rb:7` hardcodes a private companion repo path (`~/Documents/Projects/artifact/arnold-claude-code-plugin`).
5. `lib/arnold_pipeline/configuration.rb:6` — `VALID_EXECUTION_PROVIDERS` omits `:claude_code` despite it being fully supported.
6. Three empty Rails boilerplate files (`application_mailer.rb`, `application_helper.rb`, `application_controller.rb`) can be removed.
7. Design docs in `docs/plans/` contain developer-specific absolute paths.

### Tests
8. **2 consistent test failures** in `plugin_compatibility_test.rb` — `open_questions` matched as a tool name by regex; needs allowlist fix.
9. **2 intermittent SQLite locking errors** under non-default seed — MCP smoke test thread not cleanly releasing AR connections.
10. **WebMock not globally enabled** — `disable_net_connect!` missing from `test_helper.rb`. Critical for portability.
11. **SimpleCov not configured** — no quantitative coverage data available.
12. **CI workflow uses `actions/checkout@v6`** which does not exist — will fail on first push. Should be `@v4`.

### Documentation
13. `CODE_OF_CONDUCT.md` is missing — should add Contributor Covenant v2.1.
14. **YARD coverage ~1.8%** — only 11 of 610 public methods have doc comments.
15. README line 107 references private Homebrew tap `ArtifactHQ/arnold` — must be removed or replaced.
16. README has duplicate `## Configuration Reference` sections.
17. Gemspec missing `bug_tracker_uri`, `documentation_uri`, and `rubygems_mfa_required`.

### Release
18. `config/mutant_bootstrap.rb` (dev-only) included in distributed gem via `config/**/*` glob.
19. CHANGELOG `[0.1.0]` section is sparse and still marked "Unreleased".
20. No branch protection rules on `master` — no required reviews or CI checks.

## Actions Taken (auto-fixed)

| Action | Agent |
|--------|-------|
| `.gitignore` updated with 8 missing patterns | secrets-scanner |
| RuboCop auto-corrected 1,102 style violations across 124 files | code-hygiene |
| 4 additional layout violations fixed inline | code-hygiene |
| Test suite verified green (1,916/1,918 pass) after auto-corrections | code-hygiene |

## Recommended Next Steps (ordered by priority)

### Must-do before release
1. Fix `MIT-LICENSE` — replace `TODO: Write your name` with actual copyright holder
2. Fix gemspec `email` and `homepage` to point to correct org/contact
3. Resolve `mutant` licensing — document OSS eligibility or move to dev-only
4. Fix CI workflow — change `actions/checkout@v6` to `@v4`
5. Create `v0.1.0` git tag on release commit
6. Remove private Homebrew tap reference from README line 107

### Should-do before release
7. Add `disable_net_connect!` to `test_helper.rb` for test portability
8. Fix 2 test failures in `plugin_compatibility_test.rb` (add `open_questions` to allowlist)
9. Add `CODE_OF_CONDUCT.md` (Contributor Covenant v2.1)
10. Remove hardcoded developer paths from `test/e2e/` and `docs/plans/`
11. Add `frozen_string_literal: true` pragma to all `.rb` files
12. Exclude `config/mutant_bootstrap.rb` from gem build
13. Enable branch protection on `master`

### Nice-to-have post-release
14. Configure SimpleCov for coverage tracking
15. Add YARD documentation to public API surface (prioritize Configuration, Orchestrator, Provider contracts)
16. Clean up duplicate README Configuration Reference section
17. Populate CHANGELOG with meaningful content and date the 0.1.0 release
18. Add `rubygems_mfa_required` to gemspec metadata
19. Fix intermittent SQLite locking in test suite
20. Remove unused Rails boilerplate files

---

*Individual agent reports: `reports/01-secrets-scanner.md` through `reports/06-release-readiness.md`*

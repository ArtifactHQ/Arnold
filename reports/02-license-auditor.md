# License Audit Report

**Project:** arnold_pipeline
**Date:** 2026-02-27
**Auditor:** license-auditor agent
**Scope:** Full open-source readiness license audit

---

## Summary

| Check | Status |
|-------|--------|
| Overall Status | FAIL |
| LICENSE File | Present — but INCOMPLETE (placeholder copyright holder) |
| Gemspec License Field | Declared (`"MIT"`) — matches LICENSE file |
| Dependencies | 85 total gems — 79 compatible, 3 flagged |
| Copyright Headers | 0 of 181 source files have any header (0%) |

---

## Critical Issues

1. **LICENSE file has placeholder copyright holder.** The `MIT-LICENSE` file reads `Copyright TODO: Write your name` — the copyright owner has never been filled in. This makes the license legally defective. A valid MIT license requires a named copyright holder.

2. **`mutant` and `mutant-minitest` use a proprietary EULA, not an open source license.** These gems are classified as `"Nonstandard"` on RubyGems.org. Their actual license is a commercial End User License Agreement (EULA) with a free tier for open source projects and a paid tier for commercial use. This is a material compliance concern: the terms prohibit redistribution and reverse engineering. For a developer tool gem shipped as a runtime testing dependency, downstream users may unknowingly inherit a commercial license obligation.

3. **`diff-lcs` is triple-licensed (MIT / Artistic-1.0-Perl / GPL-2.0-or-later).** The license is disjunctive — the user chooses which license to apply. Because this project can elect MIT, it is compatible. However, this must be made explicit: the project's LICENSE compliance documentation (or a `NOTICE` file) should state that `diff-lcs` is used under its MIT license option.

4. **Zero copyright headers across all 181 Ruby source files.** No file contains a `frozen_string_literal` pragma or a copyright notice. This is both a Ruby best-practices gap and a compliance gap: under the Berne Convention, code is automatically copyrighted but without visible attribution it is impossible to determine ownership, contributing to ambiguity about the project's provenance.

---

## 1. LICENSE File Audit

**File found:** `MIT-LICENSE` (at repository root)

**License type:** MIT — valid, recognizable license text.

**Issues:**

| Field | Status | Detail |
|-------|--------|--------|
| License text | PASS | Standard MIT license text, complete and unmodified |
| Copyright year | FAIL | Missing — no year present |
| Copyright holder | FAIL | `TODO: Write your name` — placeholder never replaced |
| Gemspec `spec.license` | PASS | Set to `"MIT"` — matches file |
| Gemspec/LICENSE agreement | PASS | Both declare MIT |

**Recommended fix (do not apply without owner decision):**

Replace the first line of `MIT-LICENSE` with:

```
Copyright (c) 2024-2026 ArtifactHQ
```

Or the actual legal entity name. The gemspec already uses `"Arnold Pipeline Contributors"` as the author — the copyright holder in the LICENSE file should resolve to the actual owning entity (individual or organization), not contributors.

**Note:** The gemspec `spec.files` correctly includes `"MIT-LICENSE"` in the distributed files, so the license file will be packaged with the gem. This is correct.

---

## 2. Dependency Compatibility Audit

### Flagged Dependencies

#### FLAG 1 — CRITICAL: `mutant` / `mutant-minitest` (Nonstandard / Proprietary EULA)

- **Version:** 0.14.2 (both)
- **Declared license:** `"Nonstandard"` on RubyGems.org
- **Actual license:** Proprietary commercial EULA (verified against GitHub repository)
- **Role:** Dev/test dependency (mutation testing tool)
- **Risk:** The EULA grants a free license to qualifying open source projects. However:
  - The license explicitly prohibits redistribution and reverse engineering
  - It is a per-developer commercial subscription model for non-open-source use
  - It is NOT an OSI-approved license
  - Downstream contributors who fork this project for commercial purposes may incur a licensing obligation
- **Remediation:**
  - Confirm that this project qualifies for the "Free Project License" tier under the mutant EULA (requires the project itself to be open source and free)
  - Move `mutant` and `mutant-minitest` to a clearly scoped development-only group in the `Gemfile` with a comment explaining the commercial license terms
  - Consider replacing with an OSI-licensed mutation testing alternative (e.g., `mutant` is the only mature option in Ruby; an alternative is to simply not use mutation testing)
  - Add a `NOTICE` file or `CONTRIBUTING.md` section noting this dependency's special license terms for contributors

#### FLAG 2 — INFORMATIONAL: `diff-lcs` (Disjunctive MIT / Artistic-1.0-Perl / GPL-2.0-or-later)

- **Version:** 1.6.2
- **Declared licenses:** `["MIT", "Artistic-1.0-Perl", "GPL-2.0-or-later"]`
- **Role:** Transitive dependency (pulled in by `mutant`)
- **Compatibility:** COMPATIBLE — the license is explicitly disjunctive; this project may elect to use it under MIT
- **Required action:** Document in project compliance notes that `diff-lcs` is used under the MIT license option. No code change required.

### Full Dependency License Matrix

The following table covers all 85 resolved gems from `Gemfile.lock`. Gems are sorted: flagged first, then unknown, then compatible.

| Gem Name | Version | License | Compatible | Notes |
|----------|---------|---------|:----------:|-------|
| mutant | 0.14.2 | Nonstandard (proprietary EULA) | ❌ | Commercial EULA; free tier for OSS projects only; prohibits redistribution |
| mutant-minitest | 0.14.2 | Nonstandard (proprietary EULA) | ❌ | Same EULA as mutant; dev dependency |
| diff-lcs | 1.6.2 | MIT / Artistic-1.0-Perl / GPL-2.0-or-later | ⚠️ | Disjunctive license — elect MIT; document this choice |
| action_text-trix | 2.1.16 | MIT | ✅ | Rails component |
| actioncable | 8.1.2 | MIT | ✅ | Rails component |
| actionmailbox | 8.1.2 | MIT | ✅ | Rails component |
| actionmailer | 8.1.2 | MIT | ✅ | Rails component |
| actionpack | 8.1.2 | MIT | ✅ | Rails component |
| actiontext | 8.1.2 | MIT | ✅ | Rails component |
| actionview | 8.1.2 | MIT | ✅ | Rails component |
| activejob | 8.1.2 | MIT | ✅ | Rails component |
| activemodel | 8.1.2 | MIT | ✅ | Rails component |
| activerecord | 8.1.2 | MIT | ✅ | Rails component |
| activestorage | 8.1.2 | MIT | ✅ | Rails component |
| activesupport | 8.1.2 | MIT | ✅ | Rails component |
| addressable | 2.8.8 | Apache-2.0 | ✅ | Apache-2.0 compatible with MIT projects |
| ast | 2.4.3 | MIT | ✅ | |
| base64 | 0.3.0 | Ruby / BSD-2-Clause | ✅ | Ruby stdlib gem; both licenses compatible |
| bigdecimal | 4.0.1 | Ruby / BSD-2-Clause | ✅ | Ruby stdlib gem |
| builder | 3.3.0 | MIT | ✅ | |
| concurrent-ruby | 1.3.6 | MIT | ✅ | |
| connection_pool | 3.0.2 | MIT | ✅ | |
| crack | 1.0.1 | MIT | ✅ | |
| crass | 1.0.6 | MIT | ✅ | |
| date | 3.5.1 | Ruby / BSD-2-Clause | ✅ | Ruby stdlib gem |
| drb | 2.2.3 | Ruby / BSD-2-Clause | ✅ | Ruby stdlib gem |
| erb | 6.0.1 | Ruby / BSD-2-Clause | ✅ | Ruby stdlib gem |
| erubi | 1.13.1 | MIT | ✅ | |
| event_stream_parser | 1.0.0 | MIT | ✅ | |
| faraday | 2.14.0 | MIT | ✅ | |
| faraday-multipart | 1.2.0 | MIT | ✅ | |
| faraday-net_http | 3.4.2 | MIT | ✅ | |
| faraday-retry | 2.4.0 | MIT | ✅ | Direct dependency |
| globalid | 1.3.0 | MIT | ✅ | |
| hana | 1.3.7 | MIT | ✅ | |
| hashdiff | 1.2.1 | MIT | ✅ | |
| i18n | 1.14.8 | MIT | ✅ | |
| io-console | 0.8.2 | Ruby / BSD-2-Clause | ✅ | Ruby stdlib gem |
| irb | 1.16.0 | Ruby / BSD-2-Clause | ✅ | Ruby stdlib gem |
| json | 2.18.1 | Ruby / BSD-2-Clause | ✅ | Ruby stdlib gem |
| json_schemer | 2.5.0 | MIT | ✅ | |
| language_server-protocol | 3.17.0.5 | MIT | ✅ | |
| lint_roller | 1.1.0 | MIT | ✅ | |
| logger | 1.7.0 | Ruby / BSD-2-Clause | ✅ | Ruby stdlib gem |
| loofah | 2.25.0 | MIT | ✅ | |
| mail | 2.9.0 | MIT | ✅ | |
| marcel | 1.1.0 | MIT / Apache-2.0 | ✅ | Dual-licensed; both compatible |
| mini_mime | 1.1.5 | MIT | ✅ | |
| minitest | 6.0.1 | MIT | ✅ | |
| mocha | 2.8.2 | MIT / BSD-2-Clause | ✅ | Dev dependency; dual-licensed, both compatible |
| multipart-post | 2.4.1 | MIT | ✅ | |
| mutex_m | 0.3.0 | Ruby / BSD-2-Clause | ✅ | Ruby stdlib gem |
| net-http | 0.9.1 | Ruby / BSD-2-Clause | ✅ | Ruby stdlib gem |
| net-imap | 0.6.2 | Ruby / BSD-2-Clause | ✅ | Ruby stdlib gem |
| net-pop | 0.1.2 | Ruby / BSD-2-Clause | ✅ | Ruby stdlib gem |
| net-protocol | 0.2.2 | Ruby / BSD-2-Clause | ✅ | Ruby stdlib gem |
| net-smtp | 0.5.1 | Ruby / BSD-2-Clause | ✅ | Ruby stdlib gem |
| nio4r | 2.7.5 | MIT / BSD-2-Clause | ✅ | Dual-licensed, both compatible |
| nokogiri | 1.19.0 | MIT | ✅ | |
| octokit | 9.2.0 | MIT | ✅ | Direct dependency |
| parallel | 1.27.0 | MIT | ✅ | |
| parser | 3.3.10.1 | MIT | ✅ | |
| pastel | 0.8.0 | MIT | ✅ | |
| pp | 0.6.3 | Ruby / BSD-2-Clause | ✅ | Ruby stdlib gem |
| prettyprint | 0.2.0 | Ruby / BSD-2-Clause | ✅ | Ruby stdlib gem |
| prism | 1.9.0 | MIT | ✅ | |
| propshaft | 1.3.1 | MIT | ✅ | Dev dependency |
| psych | 5.3.1 | MIT | ✅ | |
| public_suffix | 7.0.2 | MIT | ✅ | |
| puma | 7.2.0 | BSD-3-Clause | ✅ | Dev dependency |
| racc | 1.8.1 | Ruby / BSD-2-Clause | ✅ | Both licenses compatible |
| rack | 3.2.4 | MIT | ✅ | |
| rack-session | 2.1.1 | MIT | ✅ | |
| rack-test | 2.2.0 | MIT | ✅ | |
| rackup | 2.3.1 | MIT | ✅ | |
| rails | 8.1.2 | MIT | ✅ | Direct dependency |
| rails-dom-testing | 2.3.0 | MIT | ✅ | |
| rails-html-sanitizer | 1.6.2 | MIT | ✅ | |
| railties | 8.1.2 | MIT | ✅ | |
| rainbow | 3.1.1 | MIT | ✅ | |
| rake | 13.3.1 | MIT | ✅ | |
| rdoc | 7.1.0 | Ruby / BSD-2-Clause | ✅ | Ruby stdlib gem |
| regexp_parser | 2.11.3 | MIT | ✅ | |
| reline | 0.6.3 | Ruby / BSD-2-Clause | ✅ | Ruby stdlib gem |
| rexml | 3.4.4 | BSD-2-Clause | ✅ | |
| rubocop | 1.84.1 | MIT | ✅ | Dev dependency |
| rubocop-ast | 1.49.0 | MIT | ✅ | Dev dependency |
| rubocop-performance | 1.26.1 | MIT | ✅ | Dev dependency |
| rubocop-rails | 2.34.3 | MIT | ✅ | Dev dependency |
| rubocop-rails-omakase | 1.1.0 | MIT | ✅ | Dev dependency |
| ruby-anthropic | 0.4.2 | MIT | ✅ | Direct dependency |
| ruby-openai | 7.4.0 | MIT | ✅ | Direct dependency |
| ruby-progressbar | 1.13.0 | MIT | ✅ | |
| ruby2_keywords | 0.0.5 | Ruby / BSD-2-Clause | ✅ | Both licenses compatible |
| sawyer | 0.9.3 | MIT | ✅ | |
| securerandom | 0.4.1 | Ruby / BSD-2-Clause | ✅ | Ruby stdlib gem |
| simpleidn | 0.2.3 | MIT | ✅ | |
| sorbet-runtime | 0.6.12945 | Apache-2.0 | ✅ | Apache-2.0 compatible with MIT projects |
| sqlite3 | 2.9.0 | BSD-3-Clause | ✅ | Dev dependency |
| stringio | 3.2.0 | Ruby / BSD-2-Clause | ✅ | Ruby stdlib gem |
| thor | 1.5.0 | MIT | ✅ | Direct dependency |
| timeout | 0.6.0 | Ruby / BSD-2-Clause | ✅ | Ruby stdlib gem |
| tsort | 0.2.0 | Ruby / BSD-2-Clause | ✅ | Ruby stdlib gem |
| tty-color | 0.6.0 | MIT | ✅ | |
| tty-cursor | 0.7.1 | MIT | ✅ | |
| tty-prompt | 0.23.1 | MIT | ✅ | Direct dependency |
| tty-reader | 0.9.0 | MIT | ✅ | |
| tty-screen | 0.8.2 | MIT | ✅ | |
| tzinfo | 2.0.6 | MIT | ✅ | |
| unicode-display_width | 3.2.0 | MIT | ✅ | |
| unicode-emoji | 4.2.0 | MIT | ✅ | |
| unparser | 0.8.1 | MIT | ✅ | |
| uri | 1.1.1 | Ruby / BSD-2-Clause | ✅ | Ruby stdlib gem |
| useragent | 0.16.11 | MIT | ✅ | |
| webmock | 3.26.1 | MIT | ✅ | Dev dependency |
| websocket-driver | 0.8.0 | Apache-2.0 | ✅ | Apache-2.0 compatible with MIT projects |
| websocket-extensions | 0.1.5 | Apache-2.0 | ✅ | Apache-2.0 compatible with MIT projects |
| wisper | 2.0.1 | MIT | ✅ | |
| zeitwerk | 2.7.4 | MIT | ✅ | |

**Summary:** 79 compatible (✅), 1 conditional (⚠️), 2 incompatible/flagged (❌), 0 unknown (❓)

---

## 3. Copyright Header Audit

### Scope

Files scanned:
- `app/**/*.rb` — 14 files
- `lib/**/*.rb` — 82 files
- `test/**/*.rb` — approximately 85 files (excluding `test/dummy/` generated Rails files)

**Total project-owned Ruby source files: approximately 181**
**Files with `# frozen_string_literal: true` pragma: 0**
**Files with any copyright notice: 0**
**Coverage: 0% (0 of ~181 files)**

### What was found

None of the project's Ruby source files contain any of:
- `# frozen_string_literal: true`
- A copyright notice
- A license declaration comment

This is a significant gap. In Ruby, `# frozen_string_literal: true` is a strong idiom for performance and correctness (it prevents accidental string mutation). Its absence is a code quality signal. For open source, the absence of any copyright header means:
- No source-level attribution exists
- Contributors cannot determine ownership from file inspection alone
- Automated compliance tools scanning the source tree will report zero license coverage

The `test/dummy/` directory contains Rails-generated boilerplate (application_controller.rb, schema.rb, etc.) — these are conventionally left without headers and are excluded from the count above.

### Recommended header template

Apply this template to all files in `app/**/*.rb` and `lib/**/*.rb` as the highest priority. Test files can follow separately.

```ruby
# frozen_string_literal: true
#
# Copyright (c) 2024-2026 ArtifactHQ. All rights reserved.
# Licensed under the MIT License. See MIT-LICENSE in the project root.
```

Note: The `frozen_string_literal` pragma must be the very first line of the file when present.

### Files missing headers (representative sample — all 181 files are affected)

**app/ (14 files — 0 with headers):**
- `app/controllers/arnold_pipeline/application_controller.rb`
- `app/helpers/arnold_pipeline/application_helper.rb`
- `app/jobs/arnold_pipeline/application_job.rb`
- `app/jobs/arnold_pipeline/pipeline_job.rb`
- `app/mailers/arnold_pipeline/application_mailer.rb`
- `app/models/arnold_pipeline/application_record.rb`
- `app/models/arnold_pipeline/drift_finding.rb`
- `app/models/arnold_pipeline/iteration.rb`
- `app/models/arnold_pipeline/pipeline_event.rb`
- `app/models/arnold_pipeline/pipeline_run.rb`
- `app/models/arnold_pipeline/spec_delta.rb`
- `app/models/arnold_pipeline/spec_revision.rb`
- `app/models/arnold_pipeline/specification.rb`
- `app/models/arnold_pipeline/task.rb`

**lib/ (82 files — 0 with headers):**
All files under `lib/arnold_pipeline/` including agents, providers, prompts, MCP tools, CLI, and configuration.

**test/ (85 project test files — 0 with headers):**
All files under `test/` (excluding `test/dummy/` generated files).

---

## 4. Vendored Code Audit

### Vendor directory

No `vendor/` directory exists in this repository. No vendored third-party code detected.

### lib/ custom code check

A scan of all `lib/**/*.rb` files for third-party copyright markers (alternate copyright holders, license headers, or "borrowed" attributions) found **no third-party copyright notices**. All lib code appears to be original.

### Embedded/generated code

`test/dummy/` is a standard Rails engine test harness generated by `rails plugin new`. It contains scaffolded boilerplate (controllers, mailers, models, config files). This is standard practice for Rails engine testing and raises no compliance concerns. These files were generated by the Rails framework (MIT) and modified for test configuration.

### Conclusion

No vendored or copied third-party code was found outside of the standard gem dependency system.

---

## 5. Recommendations (Prioritized)

### P1 — Blocking (must fix before public release)

1. **Fix the LICENSE file copyright holder.** Replace `Copyright TODO: Write your name` with the actual legal entity name and year range (e.g., `Copyright (c) 2024-2026 ArtifactHQ`). This is the single most critical issue — a LICENSE file with a TODO placeholder is not a valid license.

2. **Resolve the `mutant`/`mutant-minitest` license situation.** These gems use a proprietary EULA. You must either:
   - Verify in writing (or via the mutant website) that this project qualifies for the Free Project License tier
   - Add a comment in the `Gemfile` documenting that these are dev-only dependencies under the mutant commercial EULA, free tier
   - Consider whether to keep them at all — mutation testing is powerful but not a common CI gate for open-source Ruby gems

### P2 — Strong Recommendation (complete before first public gem release)

3. **Add `# frozen_string_literal: true` to all `lib/**/*.rb` and `app/**/*.rb` files.** This is both a Ruby best practice and helps performance. A one-liner shell command or Rubocop can automate this: `rubocop --autocorrect-all -A` with the `Style/FrozenStringLiteralComment` cop enabled.

4. **Add copyright header comments to all `lib/**/*.rb` and `app/**/*.rb` files.** Use the template in Section 3. This provides source-level attribution and makes automated compliance scanning possible.

5. **Document the `diff-lcs` license election.** Add a `NOTICE` file or section in `CONTRIBUTING.md` stating: "This project uses `diff-lcs` under its MIT license option (the library is disjunctively licensed MIT / Artistic-1.0-Perl / GPL-2.0-or-later; we elect MIT)."

### P3 — Polish (before v1.0 or significant adoption)

6. **Consider adding a `NOTICE` file** listing all direct dependencies with their licenses. This is required by Apache-2.0 licensed dependencies (addressable, sorbet-runtime, websocket-driver, websocket-extensions) when redistributing — a NOTICE file satisfies that requirement for Apache-2.0.

7. **Rename `MIT-LICENSE` to `LICENSE`** (or `LICENSE.md`). While `MIT-LICENSE` is a common Rails convention, the SPDX standard and most tooling (e.g., GitHub's license detection, `license_finder`) prefer the name `LICENSE`. This is a minor cosmetic change but improves tool compatibility.

---

## Appendix: License Tool Notes

`license_finder` was not available in this environment. License data was obtained directly from the RubyGems.org API (`rubygems.org/api/v1/gems/<name>.json`) and verified against upstream GitHub repositories for flagged gems. The `Gemfile.lock` was used as the authoritative list of all resolved gem versions.

The Ruby standard library gems (base64, bigdecimal, date, drb, etc.) ship under the Ruby License and/or BSD-2-Clause. Both are permissive and fully compatible with MIT-licensed projects.

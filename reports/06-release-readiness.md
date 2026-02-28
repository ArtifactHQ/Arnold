# Release Readiness Report — arnold_pipeline v0.1.0

**Audit Date:** 2026-02-27
**Auditor:** release-readiness agent
**Branch:** repo-prep (HEAD at 41a343f)

---

## Summary

**NOT READY** — 3 blocking issues must be resolved before public release.

---

## Results

| Check                          | Status | Details                                                                 |
|--------------------------------|--------|-------------------------------------------------------------------------|
| Version valid                  | PASS   | 0.1.0 — SemVer compliant, appropriate for first public release          |
| CHANGELOG mentions version     | WARN   | `[0.1.0]` section exists but marked "Unreleased"; content is sparse     |
| Gemspec — required fields      | PASS   | name, version, authors, email, summary, description, license all set    |
| Gemspec — metadata keys        | WARN   | `homepage_uri` = `source_code_uri` triggers RubyGems dedup warning     |
| Gemspec — placeholder values   | FAIL   | `email` is `arnold@example.com`; `homepage` points to non-existent org  |
| Gemspec — `bug_tracker_uri`    | WARN   | Missing recommended metadata key                                        |
| Gemspec — `config/mutant_bootstrap.rb` | WARN | Dev-only file included in distributed gem via `config/**/*` glob |
| Gem builds cleanly             | WARN   | Builds successfully (159KB) but emits 2 warnings (see below)            |
| Build artifact — sensitive files | PASS | No `.env`, credentials, keys, or database files in gem                 |
| Build artifact — expected files | PASS  | lib/, app/, db/migrate/, exe/, library/, README, LICENSE all present    |
| Isolated install test          | PASS   | `gem install --local` succeeded; 88 gems installed cleanly              |
| Load test                      | PASS   | `require 'arnold_pipeline'` loads; `ArnoldPipeline::VERSION` = "0.1.0" |
| RubyGems name availability     | PASS   | Name is not registered on RubyGems.org                                 |
| Git tag for v0.1.0             | FAIL   | No git tags exist in the repository                                     |
| Homebrew formula               | SKIP   | Removed from repo (commit 4703b29); moved to ArtifactHQ/homebrew_arnold |
| GitHub homepage URL            | FAIL   | `spec.homepage` points to `github.com/arnold-pipeline/arnold_pipeline` (404); actual repo is `ArtifactHQ/arnold_pipeline` |
| Branch protection (master)     | FAIL   | No branch protection rules configured on ArtifactHQ/arnold_pipeline master |
| Repo cleanliness               | WARN   | 125 modified tracked files + 18 untracked files not yet committed        |
| Current branch                 | WARN   | On `repo-prep`, not `master` — release should be tagged on master       |
| Gemfile.lock consistency       | PASS   | `bundle check` passes cleanly                                           |
| Debug statements               | WARN   | 4 `puts` calls in `lib/arnold_pipeline/verification_runner.rb` (intentional diagnostic output written into a heredoc script, not interactive debugger remnants — low severity) |

---

## Blockers

### FAIL 1: `spec.email` and `spec.homepage` contain placeholder/wrong values

- **File:** `/home/kyle/Documents/Projects/artifact/arnold_pipeline/arnold_pipeline.gemspec`
- `spec.email = [ "arnold@example.com" ]` — `@example.com` is a placeholder domain; RubyGems publishers are expected to use a real contact address.
- `spec.homepage = "https://github.com/arnold-pipeline/arnold_pipeline"` — the org `arnold-pipeline` does not exist on GitHub (returns 404). The actual repository lives at `https://github.com/ArtifactHQ/arnold_pipeline`.
- All three `metadata` URIs (`homepage_uri`, `source_code_uri`, `changelog_uri`) inherit from `spec.homepage` and are therefore also wrong.

**Fix:**
```ruby
spec.email       = [ "your-real-email@example.com" ]  # or a team alias
spec.homepage    = "https://github.com/ArtifactHQ/arnold_pipeline"

spec.metadata["homepage_uri"]    = spec.homepage
spec.metadata["source_code_uri"] = spec.homepage
spec.metadata["changelog_uri"]   = "#{spec.homepage}/blob/master/CHANGELOG.md"
spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"
```

---

### FAIL 2: No git tag for v0.1.0

The repository has zero git tags. RubyGems release convention and consumers of the gem both expect a git tag (`v0.1.0`) that marks the exact commit from which the gem was built. Without it, the release cannot be reproduced, rollback is ambiguous, and the GitHub Releases page will be empty.

**Fix (after all blockers are resolved and changes are committed to master):**
```bash
git tag -a v0.1.0 -m "Release v0.1.0"
git push origin v0.1.0
```

---

### FAIL 3: No branch protection on `master`

The GitHub API returns `404 Branch not protected` for `ArtifactHQ/arnold_pipeline/branches/master/protection`. For a public gem repository, the master branch is the source of truth for releases. Without protection:
- Any collaborator can force-push to master and silently alter release history.
- There is no requirement for CI to pass before merging.
- There is no required review before changes reach the release branch.

**Fix:** In GitHub repository settings, enable branch protection for `master` with at minimum:
- Require a pull request before merging (1 required reviewer)
- Require status checks to pass before merging (CI test workflow)
- Do not allow force pushes
- Do not allow branch deletion

---

## Warnings (non-blocking, should be reviewed)

### WARN 1: Gem build emits 2 warnings

```
WARNING: You have specified the uri:
  https://github.com/arnold-pipeline/arnold_pipeline
for all of the following keys:
  homepage_uri
  source_code_uri
Only the first one will be shown on rubygems.org
```

This will be resolved automatically once `spec.homepage` is corrected (Blocker 1). Additionally, once `source_code_uri` is given a distinct value from `homepage_uri` (they can be the same, but one will be suppressed), this warning disappears. Adding `bug_tracker_uri` as a distinct fourth key ensures all useful links surface on the gem's RubyGems page.

---

### WARN 2: CHANGELOG `[0.1.0]` section is sparse and marked "Unreleased"

`CHANGELOG.md` has two sections — `[Unreleased]` (containing all the feature additions) and `[0.1.0] - Unreleased` (containing only "Initial release."). Before publishing, move all content from `[Unreleased]` into `[0.1.0]`, set its date, and leave `[Unreleased]` empty.

---

### WARN 3: `config/mutant_bootstrap.rb` included in the distributed gem

The gemspec's `files` glob includes `config/**/*`, which picks up `config/mutant_bootstrap.rb`. This file is a development/mutation-testing bootstrap that eager-loads all classes so Mutant can discover them. It has no value to gem consumers and adds noise. It also depends on `Rails.application.eager_load!` being available in the consumer's context.

**Fix:** Either exclude it explicitly or move it to a location outside the `config/` directory (e.g., `scripts/` or `.mutant/`):
```ruby
spec.files = Dir.chdir(File.expand_path(__dir__)) do
  Dir["{app,config,db,exe,lib,library}/**/*", "MIT-LICENSE", "Rakefile", "README.md"]
    .reject { |f| f == "config/mutant_bootstrap.rb" }
end
```

---

### WARN 4: `metadata["source_code_uri"]` duplicates `metadata["homepage_uri"]`

Per RubyGems conventions, `source_code_uri` and `homepage_uri` can be different (e.g., homepage = docs site, source_code_uri = GitHub). When they are identical, RubyGems only displays one. This is not wrong, but it prevents a `bug_tracker_uri` from being added to differentiate the links shown on the gem page. After fixing Blocker 1, add:
```ruby
spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"
```

---

### WARN 5: 125 modified tracked files not committed

The working tree on the `repo-prep` branch has 125 modified tracked files (source files, tests, migrations) and 18 untracked files. This means the built gem may not exactly match a reproducible commit. The gem should only be built and published from a clean, committed, tagged state on `master`.

---

### WARN 6: On branch `repo-prep`, not `master`

The release tag and the `gem push` should be done from `master` (the default branch). Ensure all repo-prep changes are reviewed, merged to `master`, and the tag is applied to the merge commit.

---

## Gemspec Field Audit

| Field                    | Value                                                              | Status  |
|--------------------------|--------------------------------------------------------------------|---------|
| `name`                   | `arnold_pipeline`                                                  | PASS    |
| `version`                | `0.1.0` (from `lib/arnold_pipeline/version.rb`)                    | PASS    |
| `authors`                | `["Arnold Pipeline Contributors"]`                                 | PASS    |
| `email`                  | `["arnold@example.com"]`                                           | FAIL    |
| `summary`                | "Agentic workflow system that transforms natural language..."       | PASS    |
| `description`            | Full sentence describing Rails engine and orchestration            | PASS    |
| `homepage`               | `https://github.com/arnold-pipeline/arnold_pipeline` (404)         | FAIL    |
| `license`                | `MIT`                                                              | PASS    |
| `required_ruby_version`  | `>= 4.0`                                                           | PASS    |
| `metadata["homepage_uri"]`    | Same as `spec.homepage` (wrong URL)                           | FAIL    |
| `metadata["source_code_uri"]` | Same as `spec.homepage` (wrong URL, deduplicated by RubyGems) | WARN    |
| `metadata["changelog_uri"]`   | Correct path, but base URL is wrong                           | FAIL    |
| `metadata["bug_tracker_uri"]` | Not set                                                       | WARN    |
| `bindir` / `executables`      | `exe/arnold`                                                  | PASS    |
| `files` — sensitive content   | None found                                                    | PASS    |
| `files` — mutant bootstrap    | `config/mutant_bootstrap.rb` included unnecessarily           | WARN    |

**Runtime dependencies:**

| Gem              | Constraint | Status |
|------------------|------------|--------|
| `rails`          | `>= 8.0`   | PASS — aligns with engine requirements |
| `thor`           | `~> 1.3`   | PASS |
| `ruby-anthropic` | `~> 0.4`   | PASS — correct gem name (not `anthropic`) |
| `ruby-openai`    | `~> 7.0`   | PASS |
| `octokit`        | `~> 9.0`   | PASS |
| `faraday-retry`  | `~> 2.0`   | PASS |
| `tty-prompt`     | `~> 0.23`  | PASS |

---

## Version Assessment

**0.1.0 is the correct version for a first public release.** The gem is a Rails 8 engine with an active and evolving API. Releasing as `0.1.0` sets appropriate expectations that:
- The public API may change in minor versions
- The project is functional but not necessarily API-stable

`1.0.0` would be appropriate only after the API is considered stable and the project has a compatibility commitment. Do not use `0.0.1` — the feature set is substantial enough that `0.1.0` is more accurate.

---

## Pre-Publish Checklist

Complete these steps in order:

1. [ ] Fix `spec.email` with a real contact address
2. [ ] Fix `spec.homepage` to `https://github.com/ArtifactHQ/arnold_pipeline`
3. [ ] Add `metadata["bug_tracker_uri"]`
4. [ ] Exclude `config/mutant_bootstrap.rb` from gem files
5. [ ] Move all CHANGELOG entries from `[Unreleased]` into `[0.1.0]` with today's date
6. [ ] Commit all outstanding changes on `repo-prep`
7. [ ] Open PR from `repo-prep` → `master` and merge
8. [ ] On `master` with clean working tree: `gem build arnold_pipeline.gemspec`
9. [ ] Verify no build warnings remain
10. [ ] `git tag -a v0.1.0 -m "Release v0.1.0" && git push origin v0.1.0`
11. [ ] `gem push arnold_pipeline-0.1.0.gem`
12. [ ] Create a GitHub Release at `v0.1.0` with CHANGELOG content as release notes
13. [ ] Enable branch protection on `master` (required reviews + CI status checks)

---

## Notes

- **Homebrew formula:** Removed from this repo at commit `4703b29` and moved to `ArtifactHQ/homebrew_arnold`. No formula to audit here. Ensure the Homebrew tap formula is updated to reference the correct gem once published to RubyGems.
- **RubyGems name:** `arnold_pipeline` is not registered. The name is available. First publisher wins the name.
- **Repo ownership mismatch:** The gemspec references `github.com/arnold-pipeline/arnold_pipeline` (non-existent org) while the actual code lives at `github.com/ArtifactHQ/arnold_pipeline`. This inconsistency should be audited in any other documentation, README links, or configuration files that reference the old URL.
- **Security scanning:** GitHub secret scanning and push protection are currently disabled on `ArtifactHQ/arnold_pipeline`. These should be enabled before public release.

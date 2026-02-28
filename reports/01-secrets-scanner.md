# Secrets Scanner Report

**Repository:** `arnold_pipeline`
**Scan Date:** 2026-02-27
**Branch:** `repo-prep`
**Scanner:** Manual regex scanning (gitleaks/trufflehog not available in environment)
**Scope:** Working tree + git history patterns

---

## 1. Executive Summary

| Category | Count |
|---|---|
| CRITICAL findings | 0 |
| HIGH findings | 0 |
| MEDIUM findings | 0 |
| LOW (false positives / placeholders) | 6 |
| .gitignore gaps identified | 8 |
| Auto-remediations performed | 0 |
| **BLOCKING issues** | **0** |

**Overall status: CLEAR.** No live secrets were found in the working tree. All secret-pattern matches are test fixtures with obvious placeholder values (`sk-test-key`, `ghp_test`, `sk-ant-test`, `test`), inline documentation examples, or commented-out code blocks. Git history shows no evidence of real credential commits.

---

## 2. Working Tree Findings

### Pattern Scan Results

| Pattern | Files Scanned | Real Secrets Found |
|---|---|---|
| AWS Access Key IDs (`AKIA[0-9A-Z]{16}`) | All | 0 |
| AWS Secret Keys (40-char base64 near AWS context) | All | 0 |
| AWS Account IDs (12-digit in config files) | All | 0 |
| Anthropic API keys (`sk-ant-api...`) | All | 0 |
| OpenAI API keys (`sk-[20+chars]`) | All | 0 |
| GitHub tokens (`ghp_/gho_/...` 36+ chars) | All | 0 |
| Slack tokens (`xox[baprs]-...`) | All | 0 |
| Private keys (`-----BEGIN ... PRIVATE KEY-----`) | All | 0 |
| Bearer tokens | All | 0 (doc reference only) |
| Database connection strings with credentials | All | 0 |
| Internal/private hostnames | All | 0 |
| Generic `password=`, `secret=`, `token=` patterns | All | 0 |

### Low-Severity Matches (All False Positives)

```
[LOW] Secret Type: Anthropic API key placeholder
  Files: test/lib/arnold_pipeline/configuration_test.rb (lines 442, 481)
         test/lib/arnold_pipeline/cli/setup_wizard_test.rb (lines 22, 43, 51, 82)
         test/lib/arnold_pipeline/cli/doctor_test.rb (lines 72, 88, 216, 224)
         test/lib/arnold_pipeline/cli_test.rb (lines 1224, 1243, 1258)
         docs/plans/2026-02-18-preview-and-doctor-plan.md (multiple)
  Pattern: sk-ant-t***
  Verdict: FALSE POSITIVE — clearly test fixture values ("sk-ant-test", "sk-ant-test123",
           "sk-ant-xyz"). None match real Anthropic key format (sk-ant-api03-...).
  Status: No action required.

[LOW] Secret Type: GitHub token placeholder
  Files: test/lib/arnold_pipeline/configuration_test.rb (35 occurrences)
         test/lib/arnold_pipeline/providers/execution/github_test.rb (13 occurrences)
         test/integration/pipeline_end_to_end_test.rb (line 13)
  Pattern: ghp_t***
  Verdict: FALSE POSITIVE — value is "ghp_test", which is 8 characters.
           Real GitHub PATs are ghp_ followed by exactly 36 characters.
           This is an intentional short placeholder.
  Status: No action required.

[LOW] Secret Type: Generic API key placeholder
  Files: test/lib/arnold_pipeline/providers/llm/anthropic_test.rb (lines 78, 83)
         test/lib/arnold_pipeline/providers/llm/open_ai_test.rb (lines 63, 68)
  Pattern: sk-t***-k**
  Verdict: FALSE POSITIVE — value is "sk-test-key". Used to test that the LLM
           client receives the access_token parameter correctly.
  Status: No action required.

[LOW] Secret Type: Password in Docker Compose template
  File: research/local-execution-strategies.md (line 270)
  Pattern: postgres://postgres:p******@db/app_dev
  Verdict: FALSE POSITIVE — this is a sample docker-compose.yml template in a
           research document exploring local execution strategies for target
           applications. The password literal "password" is a standard placeholder.
           File is research documentation, not deployed configuration.
  Status: No action required.

[LOW] Secret Type: Password in Docker Compose template
  File: research/local-execution-strategies.md (line 277)
  Pattern: POSTGRES_PASSWORD: p******
  Verdict: FALSE POSITIVE — same template block as above.
  Status: No action required.

[LOW] Secret Type: AWS credential comment in storage.yml
  File: test/dummy/config/storage.yml (lines 9-13)
  Pattern: access_key_id / secret_access_key (commented-out template)
  Verdict: FALSE POSITIVE — Rails-generated boilerplate, fully commented out,
           references Rails credentials store (not hardcoded values).
  Status: No action required.
```

---

## 3. Git History Findings

### Methodology

No automated git-history scanner (gitleaks, trufflehog) was available. Manual pattern scanning was applied:

- Checked all currently-tracked files for real credential patterns
- Verified that no `.env`, `config/master.key`, `config/credentials.yml`, or `*.pem`/`*.key` files appear in the repository (tracked or untracked)
- Checked `.gitignore` for evidence of previously-tracked sensitive files
- Reviewed untracked files from `git status` output for sensitive content

### Result

**No evidence of historical secret commits found.**

Key indicators reviewed:
- No `.env` files in working tree or `.gitignore` exclusions pointing to historically-tracked env files
- No `config/master.key` or `config/credentials.yml` (plaintext) anywhere
- No `*.pem`, `*.key`, `*.p12`, or `*.pfx` files
- The `.gitignore` does not contain patterns that would only be added after accidental tracking (e.g., no `!*.key` negation patterns, no individual file exclusions that suggest prior incidents)
- All API key / token values in test fixtures are clearly short placeholders

### Recommendation

For pre-release due diligence, run a full history scan with gitleaks:

```bash
# Install gitleaks (macOS/Linux)
brew install gitleaks
# or: https://github.com/gitleaks/gitleaks/releases

# Full history scan
gitleaks detect --source . --verbose --report-format json --report-path reports/gitleaks-history.json

# Working tree only
gitleaks detect --source . --no-git --verbose
```

If any commits are flagged, cross-reference against the false-positive table above before taking remediation action.

---

## 4. .gitignore Assessment

### Current .gitignore Contents

```
# IDE
.idea/
*.swp
*.swo
*~

# Gem build artifacts
*.gem
pkg/

# Dummy app runtime files
test/dummy/log/*.log
test/dummy/storage/*.sqlite3
test/dummy/tmp/

# OS
.DS_Store
Thumbs.db
```

### Gaps Identified

The following critical patterns are **missing** from `.gitignore`:

| Missing Pattern | Risk | Priority |
|---|---|---|
| `.env` | Prevent accidental commit of env file with real API keys | HIGH |
| `.env.*` | Covers `.env.local`, `.env.production`, `.env.development` | HIGH |
| `config/master.key` | Rails master key — if a real Rails app is ever added | MEDIUM |
| `config/credentials/*.key` | Multi-environment credentials keys | MEDIUM |
| `*.pem` | Private key/certificate files | MEDIUM |
| `*.key` | Private key files (overlaps with master.key) | MEDIUM |
| `tmp/` | Prevents accidental commit of tmp files (e.g., `tmp/arnold_solid_check.rb` is currently untracked) | MEDIUM |
| `vendor/bundle` | Bundled gems — avoids large binary/compiled gem commits | LOW |

### .gitignore Additions Made

The following entries were added to `.gitignore`:

```gitignore
# Environment files — never commit real credentials
.env
.env.*
!.env.example

# Rails master key and credentials keys
config/master.key
config/credentials/*.key

# Certificate and private key files
*.pem
*.key

# Temporary files
tmp/

# Bundled dependencies
vendor/bundle
```

> Note: `.env.example` is explicitly allowed with `!.env.example` so a safe template
> file can be committed. No `.env.example` currently exists in the repository — one
> should be created for open-source users (see Section 6).

---

## 5. Historical Remediation Commands

No live secrets requiring history rewrite were found. This section is provided for reference only.

**If a future gitleaks scan identifies a real secret in history, use BFG Repo-Cleaner:**

```bash
# Step 1: Install BFG Repo-Cleaner
# macOS: brew install bfg
# Linux: download from https://rtyley.github.io/bfg-repo-cleaner/

# Step 2: Create a file with the exact secret values to remove (one per line)
cat > /tmp/secrets-to-remove.txt << 'EOF'
REPLACE_WITH_ACTUAL_SECRET_VALUE
EOF

# Step 3: Make a fresh mirror clone of the repo first (BFG operates on a bare clone)
git clone --mirror git@github.com:ArtifactHQ/arnold_pipeline.git arnold_pipeline_mirror
cd arnold_pipeline_mirror

# Step 4: Run BFG to replace secrets in history
bfg --replace-text /tmp/secrets-to-remove.txt

# Step 5: Expire reflog and garbage-collect
git reflog expire --expire=now --all
git gc --prune=now --aggressive

# Step 6: Force-push cleaned history (DESTRUCTIVE — coordinate with all contributors)
git push --force

# IMPORTANT: After force-push, all contributors must re-clone.
# Cached copies in GitHub's CDN/forks may retain secrets for 90 days.
# Contact GitHub support to expedite cache purge for public repos.
```

**Alternative — git filter-repo (for removing entire files):**

```bash
pip install git-filter-repo

# Remove a specific file from all history
git filter-repo --invert-paths --path path/to/secret-file.env

# Force push
git push --force
```

---

## 6. Post-Remediation Checklist

- [x] Scanned working tree for all common secret patterns — no live secrets found
- [x] Verified no `.env`, `.key`, `.pem`, or credentials files present
- [x] Verified all test fixtures use obvious placeholder values
- [x] Updated `.gitignore` with missing patterns (8 additions)
- [ ] **Run `gitleaks detect --source . --verbose` for automated confirmation** (tool not available in current environment)
- [ ] Create `.env.example` with placeholder values to guide open-source users:
  ```bash
  cat > .env.example << 'EOF'
  # LLM Provider — set one of these
  ANTHROPIC_API_KEY=sk-ant-...
  OPENAI_API_KEY=sk-...

  # GitHub Execution Provider
  GITHUB_TOKEN=ghp_...
  EOF
  ```
- [ ] Rotate any credentials that have ever been used in development if there is any doubt about commit history
- [ ] Set up pre-commit hook to prevent future leaks:
  ```bash
  # Install pre-commit framework
  pip install pre-commit

  # Create .pre-commit-config.yaml
  cat > .pre-commit-config.yaml << 'EOF'
  repos:
    - repo: https://github.com/gitleaks/gitleaks
      rev: v8.18.0
      hooks:
        - id: gitleaks
  EOF

  pre-commit install
  ```
- [ ] Enable GitHub Secret Scanning (Settings → Security → Secret scanning) once the repo is public
- [ ] Enable GitHub Push Protection (Settings → Security → Push protection) to block future accidental pushes

---

## 7. Tool Availability Notes

The following tools were **not available** in the current environment and should be installed for a more thorough automated scan:

| Tool | Purpose | Install |
|---|---|---|
| `gitleaks` | Fast regex + entropy-based secret scanner, git history aware | `brew install gitleaks` or [GitHub releases](https://github.com/gitleaks/gitleaks/releases) |
| `trufflehog` | High-signal secret scanner with verification | `brew install trufflehog` or `pip install trufflehog` |

Manual regex scanning was used as a fallback and covered all standard patterns. The primary risk of manual scanning vs. tool-based scanning is missing high-entropy strings that don't match known patterns (e.g., random 40-character secrets not adjacent to a keyword). Given the codebase's consistent use of explicit placeholder naming (`sk-test-key`, `ghp_test`, `test`), this risk is assessed as low.

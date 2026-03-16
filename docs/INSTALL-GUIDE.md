# Arnold — Install Guide

## Quick Reference

| Method | Command | Works with private repo? |
|--------|---------|------------------------|
| Local install | `~/path/to/Arnold-Lite/install.sh` | Yes |
| Plugin (Claude Code) | `/plugin marketplace add ArtifactHQ/Arnold-Lite` | Only if public |
| Remote install | `curl ... \| bash` | Only if public |

If the repo is private, use the **local install**. It's the same result.

---

## Local Install (Private Repo)

This is the recommended method when the Arnold-Lite repo is private or not yet published.

### Step 1: Clone Arnold-Lite

```bash
git clone https://github.com/ArtifactHQ/Arnold-Lite.git ~/Arnold-Lite
```

If using SSH:

```bash
git clone git@github.com:ArtifactHQ/Arnold-Lite.git ~/Arnold-Lite
```

You only need to do this once. The cloned repo stays on your machine.

### Step 2: Go to your project

```bash
cd ~/Documents/GitHub/my-project
```

This is the project you want to add Arnold to, not the Arnold repo itself.

### Step 3: Run the installer

```bash
~/Arnold-Lite/install.sh
```

You should see:

```
🦕 Arnold v0.2.0
   Hold on to your docs.

✓ Created .claude/commands/arnold/
→ Downloading Arnold commands...
✓   /arnold:init
✓   /arnold:plan
✓   /arnold:check
✓   /arnold:update
✓   /arnold:status
✓   /arnold:help
✓   /arnold:decide
✓   /arnold:resolve
✓   /arnold:recap
✓   /arnold:diff
✓   /arnold:spec
✓ Created .claude/CLAUDE.md

Arnold v0.2.0 is installed.

  Next steps:
    1. Open Claude Code in this project
    2. Run /arnold:init      — scaffold docs from your project
    3. Run /arnold:plan      — flesh out feature specs
    4. Build your code
    5. Run /arnold:check     — compare docs to code, find drift
    6. Run /arnold:update    — sync docs after code changes

    Run /arnold:help anytime for the full command reference.
```

### Step 4: Verify

```bash
~/Arnold-Lite/install.sh --verify
```

This checks that all 11 command files are installed and valid.

### Step 5: Open Claude Code and start using Arnold

```bash
claude
```

Then type `/arnold:help` to see all commands and how to get started.

---

## Using Arnold

### If you're starting a new project (no code yet)

```
/arnold:init
```

Arnold asks what you're building, then creates a `docs/` folder with feature overviews, open questions, and a status tracker.

### If you have existing code but no docs

```
/arnold:init --auto
```

Arnold scans your codebase (package.json, models, routes, config files, constants), identifies features, extracts business rules, and generates documentation that matches your code. The `--auto` flag skips all confirmation prompts.

Without `--auto`, Arnold presents what it found and asks you to confirm before creating docs.

### If you have a spec or PRD document

```
/arnold:spec docs/my-spec.md
```

Arnold reads your document, extracts features, rules, decisions, and open questions, and creates the full doc structure from it. Your original spec is preserved as a reference.

### After setup, the core loop

1. **Build your code** however you normally do.

2. **Check for drift:**
   ```
   /arnold:check
   ```
   Arnold reads your docs AND your code, then reports where they disagree. Example: "docs say session timeout is 24 hours, code has 72 hours."

3. **Fix drift:**
   ```
   /arnold:resolve
   ```
   For each mismatch, Arnold asks: "docs say X, code says Y. Which is correct?" You choose, Arnold fixes the other side.

4. **Sync docs:**
   ```
   /arnold:update
   ```
   Arnold reads your git diff, sees what changed, and proposes doc updates. You approve each one.

5. **Repeat.** Every time you code, check, resolve, update.

### Other useful commands

- `/arnold:diff` — quick drift scan, faster than full check
- `/arnold:plan` — flesh out thin docs with flows, edge cases, acceptance criteria
- `/arnold:decide` — record a decision (e.g., "chose PostgreSQL over MongoDB")
- `/arnold:status` — quick look at feature statuses and last check date
- `/arnold:recap` — start-of-session briefing, shows what changed since last time
- `/arnold:help` — full command reference

---

## Uninstall

### From the cloned repo

```bash
cd ~/Documents/GitHub/my-project
~/Arnold-Lite/install.sh --uninstall
```

### What gets removed

- `.claude/commands/arnold/` (all Arnold command files)
- Arnold rules from your CLAUDE.md (the content between the Arnold markers)
- Empty `.claude/commands/` and `.claude/` directories if nothing else is in them

### What is NOT removed

- Your `docs/` folder and all documentation Arnold created. Those are yours.
- The Arnold-Lite clone on your machine (`~/Arnold-Lite/`). Delete it manually if you want.

---

## Upgrade

When Arnold gets updated, pull the latest and re-run:

```bash
cd ~/Arnold-Lite
git pull

cd ~/Documents/GitHub/my-project
~/Arnold-Lite/install.sh
```

The installer detects the previous version and shows "Upgrading Arnold v0.1.0 → v0.2.0". Commands are overwritten with the new versions. CLAUDE.md rules are replaced (your own content is preserved, only Arnold's section is updated).

---

## Install on Multiple Projects

The cloned Arnold-Lite repo works for all your projects. Just run the installer from each one:

```bash
cd ~/Documents/GitHub/project-a
~/Arnold-Lite/install.sh

cd ~/Documents/GitHub/project-b
~/Arnold-Lite/install.sh

cd ~/Documents/GitHub/project-c
~/Arnold-Lite/install.sh
```

Each project gets its own copy of the command files. They're independent.

---

## Troubleshooting

**"Arnold commands don't show up in Claude Code"**

Make sure `.claude/commands/arnold/` exists in your project:
```bash
ls .claude/commands/arnold/
```
You should see 11 `.md` files. If not, re-run the installer.

**"Permission denied when running install.sh"**

Make the installer executable:
```bash
chmod +x ~/Arnold-Lite/install.sh
```

**"CLAUDE.md looks wrong after install"**

Arnold wraps its rules between two marker lines:
```
# ── Arnold Rules ──────────────────────────────
...
# ── End Arnold Rules ──────────────────────────
```
Your own content above or below these markers is untouched. If the markers are broken, uninstall and reinstall.

**"I want to check if Arnold is installed correctly"**

```bash
~/Arnold-Lite/install.sh --verify
```

**"I want to see the installed version"**

```bash
~/Arnold-Lite/install.sh --version
```

Or check the version file directly:
```bash
cat .claude/commands/arnold/.version
```

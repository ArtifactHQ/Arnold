# Arnold — Install Guide

## Quick Reference

| Method | Command | Works with private repo? |
|--------|---------|------------------------|
| Local install | `path/to/Arnold-Lite/install.sh` | Yes |
| Plugin (Claude Code) | `/plugin marketplace add ArtifactHQ/Arnold-Lite` | Only if public |
| Remote install | `curl ... \| bash` | Only if public |

If the repo is private, use the **local install**. It produces the same result as the other methods.

---

## Local Install (Private Repo)

This is the recommended method when the Arnold-Lite repo is private or not yet published. If you're already working on the Arnold-Lite repo locally, you already have everything you need.

### Step 1: Make sure you have Arnold-Lite locally

If you've been developing Arnold-Lite, it's already on your machine (e.g., `~/Documents/GitHub/Arnold-Lite`).

If not, clone it:

```bash
git clone https://github.com/ArtifactHQ/Arnold-Lite.git
```

Or via SSH:

```bash
git clone git@github.com:ArtifactHQ/Arnold-Lite.git
```

Note the path where it lives. You'll reference it when installing into other projects.

### Step 2: Go to the project you want to add Arnold to

```bash
cd ~/Documents/GitHub/my-project
```

This is your target project, not the Arnold-Lite repo itself. You must be inside the project where you want Arnold's commands.

### Step 3: Run the installer

```bash
~/Documents/GitHub/Arnold-Lite/install.sh
```

Replace the path with wherever Arnold-Lite lives on your machine. You should see output like:

```
🦕 Arnold v0.3.0
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
✓   /arnold:bug
✓   /arnold:archive
✓   /arnold:milestone
✓ Created .claude/CLAUDE.md

Arnold v0.3.0 is installed.
```

### Step 4: Verify it worked

Still inside your target project, run:

```bash
~/Documents/GitHub/Arnold-Lite/install.sh --verify
```

You should see checkmarks for all 17 commands plus CLAUDE.md rules.

### Step 5: Open Claude Code and try it

```bash
claude
```

Then type `/arnold:help` to see the full command guide.

---

## Using Arnold

### Starting fresh (no code, no docs)

```
/arnold:init
```

Arnold asks what you're building, then creates a `docs/` folder with feature overviews, open questions, and a status tracker.

### Existing code, no docs

```
/arnold:init --auto
```

Arnold scans your codebase (package.json, models, routes, config files, constants), identifies features, extracts business rules, and generates documentation that matches your code. The `--auto` flag skips all confirmation prompts and just does it.

Without `--auto`, Arnold shows what it found and asks you to confirm before creating docs.

### You already have a spec or PRD document

```
/arnold:spec docs/my-spec.md
```

Arnold reads your document, extracts features, rules, decisions, and open questions, and creates the full doc structure from it. Your original spec is preserved in `docs/` as a reference.

### The core loop (after setup)

1. **Build your code** however you normally do.

2. **Check for drift:**
   ```
   /arnold:check
   ```
   Arnold reads your docs AND your code, then reports where they disagree.

3. **Fix drift:**
   ```
   /arnold:resolve
   ```
   For each mismatch: "docs say X, code says Y. Which is correct?" You choose, Arnold fixes the other side.

4. **Sync docs:**
   ```
   /arnold:update
   ```
   Arnold reads your git diff, proposes doc updates. You approve each one.

5. **Repeat.** Build, check, resolve, update.

### Other commands

- `/arnold:diff` — quick drift scan (faster than full check)
- `/arnold:plan` — flesh out thin docs with flows, edge cases, acceptance criteria
- `/arnold:decide` — record a decision (e.g., "chose Stripe over Square")
- `/arnold:status` — feature statuses, open questions, last check date
- `/arnold:recap` — start-of-session briefing
- `/arnold:bug` — record a structured bug report in docs/issues/
- `/arnold:milestone` — define and track phased work
- `/arnold:archive` — move stale or reference docs to archive/reference folders
- `/arnold:help` — full command reference

---

## Uninstall

From inside the project you installed Arnold into:

```bash
cd ~/Documents/GitHub/my-project
~/Documents/GitHub/Arnold-Lite/install.sh --uninstall
```

### What gets removed

- `.claude/commands/arnold/` and all 17 command files inside it
- Arnold's rules from your CLAUDE.md (the content between the `Arnold Rules` markers)
- The `.version` file
- Empty `.claude/commands/` and `.claude/` directories if nothing else is in them

### What stays

- Your `docs/` folder and everything in it. Arnold never deletes your documentation.
- The Arnold-Lite repo on your machine. That's your source, not a dependency.

---

## The Test Cycle (Install, Test, Uninstall, Iterate)

If you're developing Arnold and want to test changes:

```bash
# 1. Make changes to Arnold-Lite
cd ~/Documents/GitHub/Arnold-Lite
# ... edit commands, fix prompts, etc.

# 2. Install into a test project
cd ~/Documents/GitHub/test-project
~/Documents/GitHub/Arnold-Lite/install.sh

# 3. Open Claude Code and test
claude
# Try /arnold:help, /arnold:init, etc.

# 4. If something doesn't work, uninstall
~/Documents/GitHub/Arnold-Lite/install.sh --uninstall

# 5. Go back to Arnold-Lite, fix the issue
cd ~/Documents/GitHub/Arnold-Lite
# ... make fixes ...

# 6. Reinstall and test again
cd ~/Documents/GitHub/test-project
~/Documents/GitHub/Arnold-Lite/install.sh
```

You don't need to uninstall before reinstalling. Running the installer again overwrites all command files with the latest versions.

---

## Upgrade

When Arnold-Lite gets updated (either by you or via git pull):

```bash
# Pull latest changes (if working with others)
cd ~/Documents/GitHub/Arnold-Lite
git pull

# Reinstall into your project
cd ~/Documents/GitHub/my-project
~/Documents/GitHub/Arnold-Lite/install.sh
```

The installer detects the previous version and shows the upgrade (e.g., "Upgrading Arnold v0.2.0 → v0.3.0"). All commands are overwritten with new versions. Your CLAUDE.md rules are updated (your own content is preserved).

---

## Install on Multiple Projects

Run the installer from each project directory:

```bash
cd ~/Documents/GitHub/project-a
~/Documents/GitHub/Arnold-Lite/install.sh

cd ~/Documents/GitHub/project-b
~/Documents/GitHub/Arnold-Lite/install.sh
```

Each project gets its own independent copy of the command files.

---

## Checking What's Installed

```bash
# Check version
~/Documents/GitHub/Arnold-Lite/install.sh --version

# Verify all commands are present and valid
cd ~/Documents/GitHub/my-project
~/Documents/GitHub/Arnold-Lite/install.sh --verify

# Check version file directly
cat .claude/commands/arnold/.version

# List installed commands
ls .claude/commands/arnold/
```

---

## Troubleshooting

**"Arnold commands don't show up in Claude Code"**

Check that the files exist in your project:
```bash
ls .claude/commands/arnold/
```
You should see 17 `.md` files. If not, re-run the installer.

Also make sure you opened Claude Code from the project directory (not from a different folder).

**"Permission denied when running install.sh"**

```bash
chmod +x ~/Documents/GitHub/Arnold-Lite/install.sh
```

**"I installed but /arnold:help doesn't work"**

Make sure you're running Claude Code from the project where you installed Arnold, not from the Arnold-Lite repo itself. The commands are in your project's `.claude/commands/arnold/`, not in Arnold-Lite's.

**"CLAUDE.md looks wrong after install"**

Arnold wraps its rules between two marker lines:
```
# ── Arnold Rules ──────────────────────────────
...
# ── End Arnold Rules ──────────────────────────
```
Your own content above or below these markers is untouched. If the markers are broken, uninstall and reinstall.

**"I want to start over completely"**

```bash
cd ~/Documents/GitHub/my-project
~/Documents/GitHub/Arnold-Lite/install.sh --uninstall
rm -rf docs/    # Only if you want to delete Arnold-generated docs too
~/Documents/GitHub/Arnold-Lite/install.sh
```

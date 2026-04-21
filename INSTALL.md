# Arnold — Agent Install Procedure

You are an AI coding agent reading this document because the user has asked you to install Arnold into their project. This document is the canonical install procedure. Follow it exactly. If anything below is ambiguous in your situation, stop and ask the user — do not improvise.

## What Arnold is and what gets installed

Arnold is a set of slash commands and skills for AI coding agents that govern documentation generation and drift detection in the user's codebase. It installs as files on disk — no binary, no daemon, no background process, no network service. The footprint varies by tool and by install scope:

- **User-global installs** (Codex plugin, future Claude Code plugin, future Cursor plugin) place Arnold once under the user's home directory, making it available to every project.
- **Project-scoped installs** (Codex project skills, Antigravity, Windsurf, Gemini CLI) place Arnold into a single project's directory, typically committed to git so teammates inherit it on clone.

Where a project-rules file exists (`AGENTS.md`, `CLAUDE.md`, `GEMINI.md`, `.windsurfrules`), Arnold's development rules are merged in, wrapped in markers for clean uninstall. Rules merges are always project-scoped — even for user-global plugin installs, the rules block lives in the project where the user wants Arnold active.

## When NOT to follow this procedure

- **Claude Code with plugin marketplace available.** Use `/plugin marketplace add ArtifactHQ/arnold` followed by `/plugin install arnold@arnold-marketplace`.
- **Cursor with plugin marketplace available.** Direct the user to install "Arnold" from the Cursor Marketplace UI.
- **Codex, once the official Plugin Directory ships.** Until then, Codex has no public marketplace and the procedure below is the supported install path.

Run this procedure when (a) the marketplace install is unavailable in the user's tool version, (b) the user is in a tool without a marketplace, or (c) the user explicitly asks for a manual install.

---

## Step 1 — Confirm the install context

Before touching the filesystem, gather and confirm four things with the user. Do not proceed if any are uncertain.

**1. Tool identity.** Detection cues, in priority order:

- Claude Code: `CLAUDECODE` env var set, or `.claude/commands/` exists in the project
- Codex: `CODEX_*` env vars, or `~/.codex/config.toml` exists, or `.agents/skills/` exists in the project
- Antigravity: `.agent/skills/` exists (singular `.agent` — distinct from Codex's plural `.agents`)
- Windsurf: `.windsurf/` directory exists
- Gemini CLI: `.gemini/` directory exists or `GEMINI.md` is present at project root

If detection is ambiguous, ask the user explicitly which agent they are running in.

**2. Target project directory.** Default to the current working directory if it looks like a project root (`.git`, `package.json`, `requirements.txt`, `Cargo.toml`, `go.mod`, or a `Makefile`). Otherwise, ask the user to confirm. Never install into the user's home directory or filesystem root. For user-global installs (see scope below), the target project is still used for the rules-file merge — skip the merge if the user explicitly declines a per-project scope.

**3. Install source.** One of three shapes. The user should have specified one in their prompt; if they did not, default to the canonical repo spec `ArtifactHQ/arnold` at the latest release tag.

| Shape | Example | When it's used |
| --- | --- | --- |
| Repo spec | `ArtifactHQ/arnold`, `ArtifactHQ/arnold@v0.5.0`, `acme/arnold-fork@main` | Default. Works whenever the agent can reach github.com. |
| Local path | `./vendor/arnold/`, `~/Downloads/arnold-v0.5.0/`, `/opt/arnold-bundle/` | Vendored installs, air-gapped environments, development against a working copy, enterprise policy requiring pre-approved local artifacts. |
| URL | `https://artifacts.acme.internal/arnold-v0.5.0.tar.gz` | Enterprise artifact registries, internal mirrors. |

**4. Install scope.** Only relevant for Codex — every other tool has exactly one install shape.

| Scope | Footprint location | When it's used |
| --- | --- | --- |
| User-global (default for Codex) | `~/.codex/plugins/arnold/` plus an entry in `~/.agents/plugins/marketplace.json` | Arnold is available in every Codex session the user starts, across all projects. |
| Project-scoped | `<target>/.agents/skills/arnold-*/` | Arnold is committed into one repo; teammates who clone the repo inherit it automatically. |

If the user says "install Arnold," default to user-global for Codex. If they say "vendor Arnold into this project" or "add Arnold to this repo," use project-scoped. If their intent is unclear, ask.

Confirm all four back to the user in one short message before continuing.

---

## Step 2 — Resolve the source to a tool tree

The goal of this step is to end up with a concrete local directory on disk that contains the install layout for the user's tool and scope. The resolution path depends on the source shape.

**Tool-tree targets**, by tool and scope:

| Tool | Scope | Target directory name |
| --- | --- | --- |
| Codex | User-global | `codex-plugin` |
| Codex | Project-scoped | `codex-skills` |
| Antigravity | Project-scoped | `antigravity-skills` |
| Claude Code | User-global (manual fallback) | `claude-plugin` |
| Cursor | User-global (manual fallback) | `cursor-plugin` |

**If source is a repo spec** (`<owner>/<repo>` or `<owner>/<repo>@<ref>`):

1. Resolve `<ref>` to a concrete commit or tag. If omitted, use the latest release tag from the GitHub Releases API.
2. If `<ref>` is a release tag, attempt to download the per-target tarball:
   ```
   https://github.com/<owner>/<repo>/releases/download/<ref>/arnold-<target>-<ref>.tar.gz
   ```
   Extract to a temp directory; the extracted root is the tool tree.
3. If no release asset exists (404, or `<ref>` is a branch or commit SHA rather than a release tag), fall back to clone + build: clone the repo at `<ref>`, run `make build` from the repo root, and use `dist/<target>/` as the tool tree. Clone + build requires Python 3 and `make` on PATH — if either is missing, stop and tell the user.

**If source is a local path**:

1. Resolve the path. If relative, resolve against the user's current working directory. If it does not exist or is not a directory, stop and report.
2. Determine the shape of the directory by looking for sentinels, in priority order:
   - Contains `dist/<target>/` → already-built repo. Use `dist/<target>/` as the tool tree.
   - Contains `skills/` and a `Makefile` at root → unbuilt repo. Run `make build`, then use `dist/<target>/` as the tool tree. Requires Python 3 and `make`.
   - Contains the target layout directly at root (matching one of the per-tool layouts in Step 3) → extracted tarball. Use the directory itself as the tool tree.
3. If none of the sentinels match, stop and report: "source path does not look like an Arnold distribution."

**If source is a URL**:

1. Download the asset to a temp directory. Validate the response is a tarball (gzip magic bytes `1f 8b`); if not, stop.
2. Extract. Apply the same sentinel check as the local-path case to determine shape.
3. Proceed as with local path.

---

## Step 2b — Validate the resolved source

Before any writes to the user's system, verify the tool tree:

1. **Version.** Read `VERSION` at the root of the tool tree (or, if absent, at the root of the enclosing distribution). Report the resolved version to the user. If the user specified a version that does not match, stop.
2. **Layout.** Confirm the tool tree contains the structure expected for the target (see Step 3). If the structure is wrong, stop and report what was expected vs. what was found.
3. **Sanity.** The tool tree must contain at least one `arnold-*` skill directory (for skills-targets) or a `.codex-plugin/plugin.json` plus a `skills/` directory (for plugin targets). An empty tree is a bug in the source, not a valid install.

If any check fails, stop. Do not proceed to Step 3 with an unverified source.

---

## Step 3 — Install

Follow the section matching the user's tool and scope. Each specifies the expected tool-tree layout and the destination paths. Do not freelance paths.

### 3a — Codex (user-global plugin, default)

Expected tool-tree layout:
```
.codex-plugin/plugin.json       # Codex plugin manifest
skills/<skill-name>/SKILL.md    # 17 skills; frontmatter names stripped of arnold: prefix
```

The skill directory layout uses short names (`init/SKILL.md`, `check/SKILL.md`, ...) not prefixed names — Codex namespaces skills under the plugin `name` automatically.

Operations:

1. Stage the plugin under `~/.codex/plugins/arnold/`. If the directory exists, the user has already confirmed overwrite in Step 1 — remove it first. Copy the entire tool tree (including `.codex-plugin/` and `skills/`) into the new `~/.codex/plugins/arnold/`.
2. Register Arnold in the personal marketplace at `~/.agents/plugins/marketplace.json`:
   - **File does not exist.** Create it with Arnold as the sole plugin:
     ```json
     {
       "name": "personal",
       "interface": { "displayName": "Personal Plugins" },
       "plugins": [
         {
           "name": "arnold",
           "source": { "source": "local", "path": "./.codex/plugins/arnold" },
           "policy": { "installation": "AVAILABLE", "authentication": "ON_INSTALL" },
           "category": "Productivity"
         }
       ]
     }
     ```
     The marketplace root is the user's home directory; `source.path` is relative to it.
   - **File exists with no `arnold` entry.** Append a new entry to the `plugins[]` array matching the shape above. Preserve existing formatting and entries.
   - **File exists with an `arnold` entry.** Leave the entry in place if it already points to `./.codex/plugins/arnold` — the plugin files themselves have been replaced in step 1.
3. Tell the user to restart Codex and enable Arnold via the plugin directory (Settings → Plugins, or the equivalent surface in their Codex client). This final activation step is not currently exposed through the Codex CLI and requires a UI interaction.
4. If the user provided a target project, merge Arnold's rules into `<target>/AGENTS.md` using the marker convention in Step 4. Source rules content is at `~/.codex/plugins/arnold/AGENTS.md` if present in the tool tree; if absent, skip the rules merge and note it in the final report. Rules merges are per-project even for user-global plugin installs.

### 3b — Codex (project-scoped skills)

Expected tool-tree layout:
```
.agents/skills/arnold-<n>/SKILL.md   # 17 skills with full arnold: prefix preserved
AGENTS.md                             # rules content
```

Operations:

1. Create `<target>/.agents/skills/` if it does not exist.
2. For each `arnold-<n>/` directory in the tool tree, copy to `<target>/.agents/skills/arnold-<n>/`. Remove any existing destination first.
3. Merge `AGENTS.md` content into `<target>/AGENTS.md` using the marker convention in Step 4.

This install is fully project-scoped: nothing is written outside `<target>`. The user does not need to restart Codex or enable anything in a UI — project skills are auto-discovered.

### 3c — Antigravity

Expected tool-tree layout:
```
.agent/skills/arnold-<n>/SKILL.md     # singular .agent — Antigravity convention
```

Operations:

1. Create `<target>/.agent/skills/` if it does not exist. **Note the singular `.agent` — this is not a typo and is distinct from Codex's `.agents/`.**
2. For each `arnold-<n>/` directory, copy to `<target>/.agent/skills/arnold-<n>/`.
3. Antigravity has no rules-file equivalent. Do not write a rules file.

### 3d — Claude Code (manual fallback only — prefer marketplace)

Expected tool-tree layout: the `claude-plugin` tree contains a `.claude-plugin/` manifest directory and a `skills/` tree.

Operations:

1. Copy each `skills/<n>/SKILL.md` (short directory names — the plugin namespaces them) to `<target>/.claude/commands/arnold/<n>.md`. Skip `skills/arnold-rules/` — its content is the rules file, not a command. The manual install uses the legacy `commands/` layout; the plugin layout is reserved for marketplace installs.
2. Merge rules into `<target>/CLAUDE.md` using the marker convention.

### 3e — Cursor (manual fallback only — prefer marketplace)

Expected tool-tree layout: the `cursor-plugin` tree has hyphenated skill names already applied (`arnold-init` not `arnold:init`).

Operations:

1. Copy `rules/arnold-rules.mdc` to `<target>/.cursor/rules/arnold-rules.mdc`.
2. Copy each skill to `<target>/.cursor/commands/<n>.md`.

### 3f — Windsurf, Gemini CLI, and other agent tools

Arnold does not yet ship dedicated build targets for these tools. Use the `codex-skills` tool tree as the source, with these path adjustments:

| Tool | Skills destination | Rules file |
| --- | --- | --- |
| Windsurf | `<target>/.windsurf/workflows/arnold-<n>/` | `<target>/.windsurfrules` |
| Gemini CLI | `<target>/.gemini/commands/arnold-<n>/` | `<target>/GEMINI.md` |

Apply the marker convention in Step 4 to the rules file.

If the user is in a tool not listed here, ask them which directory their tool reads skills from before proceeding.

---

## Step 4 — Marker convention for rules-file merges

When inserting Arnold's rules into a project rules file (`AGENTS.md`, `CLAUDE.md`, `GEMINI.md`, `.windsurfrules`), always wrap the inserted content in these exact marker lines:

```
# ── Arnold Rules ──────────────────────────────
<rules content>
# ── End Arnold Rules ──────────────────────────
```

Rules for the merge:

- **File does not exist.** Create it with the marker block as the entire content.
- **File exists, no Arnold start marker present.** Append a blank line, then the marker block, at the end of the file.
- **File exists, Arnold start marker present.** Strip the existing block (start marker through end marker, inclusive). Then append a fresh block at the end of the file.
- **Never modify content outside the marker block.**

This convention is load-bearing for clean uninstall. Do not deviate from the exact marker text — uninstall searches for byte-exact matches.

---

## Step 5 — Verify the install

After file operations complete, run these checks. If any fail, report the specific failure to the user and offer to roll back.

**For all installs:**

1. **Skill count matches.** Count subdirectories matching `arnold-*` (for skills-targets) or `<skill-name>/` (for plugin targets) in the destination skills directory. Count must equal the number in the source tool tree (17 as of v0.5.0).
2. **Skill structure intact.** For at least three randomly chosen skill directories, confirm `SKILL.md` exists and starts with YAML frontmatter.
3. **Markers balanced.** If a rules file was written, confirm both start and end markers are present exactly once each.

**Additionally for Codex user-global plugin install:**

4. **Manifest present.** `~/.codex/plugins/arnold/.codex-plugin/plugin.json` exists and is valid JSON.
5. **Marketplace entry.** `~/.agents/plugins/marketplace.json` contains a `plugins[]` entry with `name: "arnold"` whose `source.path` points at `./.codex/plugins/arnold`.

**No half-install on abort.** If you aborted partway through file operations, remove everything you created in this run.

---

## Step 6 — Report to the user

After a successful install, send one short message containing:

- The tool, scope, and resolved version
- The source installed from (repo+ref, local path, or URL)
- The destination directory for skills
- The rules file modified, if any
- **For Codex user-global installs:** explicit next-step instruction — restart Codex, open the plugin directory, enable Arnold. Do not skip this.
- One concrete invocation example for the user's tool (e.g., "type `/arnold:init` in Codex once the plugin is enabled" or "the `arnold-init` skill is now auto-discoverable")
- The exact prompt the user can give you to uninstall later

Do not enumerate every file copied. The verification in Step 5 is for you, not the user.

---

## Uninstall

If the user asks you to uninstall Arnold, mirror the install procedure in reverse. Uninstall requires the same tool + scope clarification as install.

**For Codex user-global plugin install:**

1. Confirm with the user.
2. Remove `~/.codex/plugins/arnold/`.
3. Remove the Arnold entry from `~/.agents/plugins/marketplace.json`. If Arnold was the only plugin, either remove the file entirely or leave an empty-plugins marketplace in place — ask the user.
4. Codex's plugin cache at `~/.codex/plugins/cache/personal/arnold/local/` and the enabled-state flag in `~/.codex/config.toml` will be cleaned up by Codex when the user disables the plugin or restarts. Do not hand-edit `config.toml`.
5. If a per-project `AGENTS.md` was modified, strip the marker block per Step 4's inverse. Ask the user which projects to clean; do not scan the filesystem.

**For project-scoped installs (Codex skills, Antigravity, Windsurf, Gemini CLI, Claude Code manual, Cursor manual):**

1. Confirm the target project directory and tool with the user.
2. Remove all subdirectories matching `arnold-*` from the tool's skills directory.
3. If the immediate parent (e.g., `.agents/skills/`) is now empty, remove it. If its parent (e.g., `.agents/`) is now empty, remove that too. **Do not remove non-empty directories.**
4. If a rules file was modified, strip the marker block. If the resulting file is whitespace-only, remove it.

**Always, regardless of scope:** never touch `<target>/docs/`. Arnold-generated documentation is the user's content and survives uninstall.

Report what was removed in one short message.

---

## Failure modes

| Situation | What to do |
| --- | --- |
| Tool identity unclear | Stop. Ask the user. Do not guess. |
| Install scope ambiguous (Codex only) | Stop. Ask the user: user-global plugin or project-scoped skills? |
| Source not specified and default (`ArtifactHQ/arnold`) unreachable | Stop. Ask the user for a local path or internal URL. |
| Repo-spec source: release asset 404 and ref is not a release tag | Fall back to clone + `make build` as specified in Step 2. |
| Local-path source: path does not exist | Stop. Report. Do not create it or fall back to the network. |
| Local-path source: path exists but matches no sentinel | Stop. Report "source path does not look like an Arnold distribution." |
| URL source: response is not a gzip tarball | Stop. Report. Do not retry against a different URL. |
| `make` or Python 3 missing when build is required | Stop. Report. Do not attempt a third path. |
| Version mismatch (user-specified ≠ resolved) | Stop. Report both values. Let the user decide. |
| Permission denied on file write | Stop. Report. Do not retry with elevated permissions or `sudo`. |
| Target directory does not look like a project | Ask the user to confirm the path explicitly. |
| Existing Arnold install detected | Confirm with the user before overwriting. Do not silently replace. |
| Codex plugin install: `~/.codex/` or `~/.agents/` does not exist | Create them. The user has Codex installed (confirmed in Step 1) but may not have initialized the config yet. |
| Codex plugin install: user's existing marketplace.json is malformed | Stop. Do not overwrite — ask the user to resolve the malformation first. |
| Sandboxed without filesystem write access | Stop. Print the file list and exact operations you would perform. Ask the user to grant access or apply manually. |
| Network fetch blocked | Report and ask whether the user has a local path to install from. |

---

## Determinism contract

This procedure is deterministic. For a given Arnold version, tool, scope, and target project, two runs of this procedure must produce byte-identical results — regardless of which source shape was used — and must produce results identical to running `scripts/install.sh --tool=<tool> --target=<project> [--scope=<scope>]` from a clone of the repo at the same version. That script covers every tool+scope pair in Step 3 (`claude-code`, `cursor`, `codex` with `--scope=project|user-global`, `antigravity`, `windsurf`, `gemini-cli`). If your execution diverges from any of these, that is a bug in this document or in your execution. Report the divergence; do not paper over it.

## Notes for the agent

- Copy skill files and `plugin.json` manifests verbatim. Do not edit frontmatter, rename keys, "fix" formatting, or summarize content. The build system has already applied the correct per-target transforms; the tool tree is final.
- The rules content is also final. Do not summarize it into the rules file — copy verbatim into the marker block.
- Do not hand-edit `~/.codex/config.toml`. Codex owns that file. The plugin is made available via the marketplace entry; the user activates it through the plugin directory UI.
- If the user asks you to "customize" Arnold during install (different paths, renamed skills, etc.), refuse and explain that this procedure installs Arnold as-shipped. Customization happens after install via the user's own project conventions.
- The source, the scope (Codex only), and the target project are the only variables the user controls; everything downstream is fixed. If you find yourself wanting to vary something else per-user, stop and ask — it's probably a bug.
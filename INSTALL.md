# Arnold — Agent Install Procedure

You are an AI coding agent reading this document because the user has asked you to install Arnold into their project. This document is the canonical install procedure. Follow it exactly. If anything below is ambiguous in your situation, stop and ask the user — do not improvise.

## What Arnold is and what gets installed

Arnold is a set of slash commands and skills for AI coding agents that govern documentation generation and drift detection in the user's codebase. It installs as files inside the user's project. There is no binary, no daemon, no background process, and no network service. The install footprint is:

- A directory of skill files (per-tool path; see Step 3)
- A block of rules merged into the tool's project-rules file (where one exists), wrapped in markers for clean uninstall

## When NOT to follow this procedure

- **Claude Code with plugin marketplace available.** Use `/plugin marketplace add ArtifactHQ/arnold` followed by `/plugin install arnold@arnold-marketplace` instead. The marketplace gives version tracking and clean updates that this manual procedure does not.
- **Cursor with plugin marketplace available.** Direct the user to install "Arnold" from the Cursor Marketplace UI.

Run this procedure only when (a) the marketplace install is unavailable in the user's tool version, (b) the user is in Codex, Antigravity, Windsurf, Gemini CLI, or another agent without a marketplace, or (c) the user explicitly asks for a manual install.

---

## Step 1 — Confirm the install context

Before touching the filesystem, gather and confirm three things with the user. Do not proceed if any are uncertain.

**1. Tool identity.** Detection cues, in priority order:

- Claude Code: `CLAUDECODE` env var set, or `.claude/commands/` exists in the project
- Codex: `CODEX_*` env vars, or `.agents/skills/` exists
- Antigravity: `.agent/skills/` exists (singular `.agent` — distinct from Codex's plural `.agents`)
- Windsurf: `.windsurf/` directory exists
- Gemini CLI: `.gemini/` directory exists or `GEMINI.md` is present at project root

If detection is ambiguous (e.g., a project has both `.claude/` and `.agents/` from a teammate using a different tool), ask the user explicitly which agent they are running in.

**2. Target project directory.** Default to the current working directory if it looks like a project root (`.git`, `package.json`, `requirements.txt`, `Cargo.toml`, `go.mod`, or a `Makefile`). Otherwise, ask the user to confirm the path. Never install into the user's home directory or filesystem root.

**3. Arnold version.** Default to the latest release tag (resolve via the GitHub Releases API). If the user specifies a version, use that exactly. Resolve to a concrete tag string like `v0.5.0` before proceeding — do not install from `main` HEAD without explicit user confirmation.

Confirm all three back to the user in one short message before continuing.

---

## Step 2 — Resolve the artifact source

For each tool, the install artifact is a tarball published as a GitHub Release asset:

```
https://github.com/ArtifactHQ/arnold/releases/download/<version>/arnold-<tool>-<version>.tar.gz
```

Where `<tool>` is one of: `claude-plugin`, `cursor-plugin`, `codex-skills`, `antigravity-skills`.

Download the tarball to a temporary directory and extract it. Verify the extracted layout matches the per-tool spec in Step 3. If verification fails, abort and report the discrepancy.

**Fallback.** If the release asset returns 404, clone `https://github.com/ArtifactHQ/arnold` at the version tag and run `make build` from the repo root. The fallback requires Python 3 on PATH and `make` available. If either is missing, stop and tell the user — do not attempt a third fallback.

---

## Step 3 — Install per tool

Follow the section matching the user's tool. Each specifies the source layout (inside the extracted artifact), the destination paths (inside `<target>`), and any transforms. Do not freelance paths.

### 3a — Codex

Source layout:
```
.agents/skills/arnold-<n>/SKILL.md   # 17 skills, names like arnold-init, arnold-check, ...
AGENTS.md                             # rules content
```

Operations:
1. Create `<target>/.agents/skills/` if it does not exist.
2. For each `arnold-<n>/` directory in the source, copy the entire directory to `<target>/.agents/skills/arnold-<n>/`. If the destination already exists, remove it first (the user has already confirmed overwrite in Step 1).
3. Merge the source `AGENTS.md` content into `<target>/AGENTS.md` using the marker convention in Step 4.

### 3b — Antigravity

Source layout:
```
.agent/skills/arnold-<n>/SKILL.md     # singular .agent — Antigravity convention
```

Operations:
1. Create `<target>/.agent/skills/` if it does not exist. **Note the singular `.agent` — this is not a typo and is distinct from Codex's `.agents/`.**
2. For each `arnold-<n>/` directory in the source, copy to `<target>/.agent/skills/arnold-<n>/`.
3. Antigravity has no rules-file equivalent. Do not write an `AGENTS.md`.

### 3c — Claude Code (manual fallback only — prefer marketplace)

Source layout: the `claude-plugin` artifact contains a `.claude-plugin/` manifest directory and a `skills/` tree.

Operations:
1. Copy each `skills/arnold-<n>/SKILL.md` to `<target>/.claude/commands/arnold/<n>.md` (note: the manual install uses the legacy `commands/` layout, not the plugin layout — the plugin layout is reserved for marketplace installs).
2. Merge rules into `<target>/CLAUDE.md` using the marker convention.

### 3d — Cursor (manual fallback only — prefer marketplace)

Source layout: the `cursor-plugin` artifact has hyphenated skill names already applied (`arnold-init` not `arnold:init`).

Operations:
1. Copy `rules/arnold-rules.mdc` to `<target>/.cursor/rules/arnold-rules.mdc`.
2. Copy each skill to `<target>/.cursor/commands/<n>.md`.

### 3e — Windsurf, Gemini CLI, and other agent tools

Arnold does not yet ship dedicated build targets for these tools. Use the `codex-skills` artifact as the source, with these path adjustments:

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
- **Never modify content outside the marker block.** Other tools and the user may have written content there.

This convention is load-bearing for clean uninstall. Do not deviate from the exact marker text — uninstall searches for byte-exact matches.

---

## Step 5 — Verify the install

After file operations complete, run these checks. If any fail, report the specific failure to the user and offer to roll back.

1. **Skill count matches.** Count subdirectories matching `arnold-*` in the destination skills directory. The count must equal the number of `arnold-*` directories in the source artifact (17 as of v0.5.0).
2. **Skill structure intact.** For at least three randomly chosen `arnold-*` directories, confirm `SKILL.md` exists and starts with YAML frontmatter (a line containing only `---`).
3. **Markers balanced.** If a rules file was written, confirm both start and end markers are present, exactly once each.
4. **No half-install on abort.** If you aborted partway through file operations, remove everything you created in this run.

---

## Step 6 — Report to the user

After successful install, send one short message containing:

- The tool you installed for and the version
- The destination directory for skills
- The rules file modified, if any
- One concrete invocation example for the user's tool (e.g., "type `/arnold:init` to create the initial spec" for Claude Code, or "the `arnold-init` skill is now auto-discoverable" for Codex)
- The exact prompt the user can give you to uninstall later

Do not enumerate every file copied. The verification step in Step 5 is for you, not the user.

---

## Uninstall

If the user asks you to uninstall Arnold, mirror the install procedure in reverse:

1. Confirm the target project directory and tool with the user (same checks as Step 1).
2. Remove all subdirectories matching `arnold-*` from the tool's skills directory.
3. If the immediate parent (e.g., `.agents/skills/`) is now empty, remove it. If its parent (e.g., `.agents/`) is now empty, remove that too. **Do not remove non-empty directories** — they may belong to the user or to other tools.
4. If a rules file was modified, strip the marker block (start through end, inclusive). If the resulting file contains only whitespace, remove the file.
5. **Never touch `<target>/docs/`.** Arnold-generated documentation is the user's content. It is not part of the install footprint and survives uninstall.

Report what was removed in one short message.

---

## Failure modes

| Situation | What to do |
| --- | --- |
| Tool identity unclear | Stop. Ask the user. Do not guess. |
| Release asset returns 404 | Try the clone + `make build` fallback once. If unavailable, stop and report. |
| `make` or Python 3 missing for fallback | Stop. Report. Do not attempt a third path. |
| Permission denied on file write | Stop. Report. Do not retry with elevated permissions or `sudo`. |
| Target directory does not look like a project | Ask the user to confirm the path explicitly. |
| Existing Arnold install detected (skill dirs or marker block present) | Confirm with the user before overwriting. Do not silently replace. |
| Sandboxed without filesystem write access | Stop. Print the file list and exact operations you would perform. Ask the user to grant access or apply manually. |
| Network fetch blocked | Try the clone fallback. If clone is also blocked, stop and ask the user to apply manually. |

---

## Determinism contract

This procedure is deterministic. For a given Arnold version and a given target project, two runs of this procedure must produce byte-identical results — and must produce results identical to running `scripts/install-skills.sh --tool=<tool> --target=<project>` from a clone of the repo at the same version. If your execution diverges from either, that is a bug in this document or in your execution. Report the divergence; do not paper over it.

## Notes for the agent

- Copy skill files verbatim. Do not edit frontmatter, rename keys, "fix" formatting, or summarize content. The build system in the Arnold repo has already applied the correct per-tool transforms; the artifact is final.
- The rules content is also final. Do not summarize it into the rules file — copy the source `AGENTS.md` (or equivalent) verbatim into the marker block.
- If the user asks you to "customize" Arnold during install (different paths, renamed skills, etc.), refuse and explain that this procedure installs Arnold as-shipped. Customization happens after install via the user's own project conventions.
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

**3. Install source.** One of three shapes. The user should have specified one in their prompt; if they did not, default to the canonical repo spec `ArtifactHQ/arnold` at the latest release tag.

| Shape | Example | When it's used |
| --- | --- | --- |
| Repo spec | `ArtifactHQ/arnold`, `ArtifactHQ/arnold@v0.5.0`, `acme/arnold-fork@main` | Default. Works whenever the agent can reach github.com. |
| Local path | `./vendor/arnold/`, `~/Downloads/arnold-v0.5.0/`, `/opt/arnold-bundle/` | Vendored installs, air-gapped environments, development against a working copy, enterprise policy requiring pre-approved local artifacts. |
| URL | `https://artifacts.acme.internal/arnold-v0.5.0.tar.gz` | Enterprise artifact registries, internal mirrors. |

Confirm tool, target, and source back to the user in one short message before continuing.

---

## Step 2 — Resolve the source to a tool tree

The goal of this step is to end up with a concrete local directory on disk that contains the install layout for the user's tool (per Step 3). The resolution path depends on the source shape.

**If source is a repo spec** (`<owner>/<repo>` or `<owner>/<repo>@<ref>`):

1. Resolve `<ref>` to a concrete commit or tag. If omitted, use the latest release tag from the GitHub Releases API.
2. If `<ref>` is a release tag, attempt to download the per-tool tarball:
   ```
   https://github.com/<owner>/<repo>/releases/download/<ref>/arnold-<tool>-<ref>.tar.gz
   ```
   where `<tool>` is one of `claude-plugin`, `cursor-plugin`, `codex-skills`, `antigravity-skills`. Extract to a temp directory; the extracted root is the tool tree.
3. If no release asset exists (404, or `<ref>` is a branch or commit SHA rather than a release tag), fall back to clone + build: clone the repo at `<ref>`, run `make build` from the repo root, and use `dist/<tool-dir>/` as the tool tree (where `<tool-dir>` matches the tool: `claude-plugin`, `cursor-plugin`, `codex-skills`, or `antigravity-skills`). Clone + build requires Python 3 and `make` on PATH — if either is missing, stop and tell the user.

**If source is a local path**:

1. Resolve the path. If relative, resolve against the user's current working directory. If it does not exist or is not a directory, stop and report.
2. Determine the shape of the directory by looking for sentinels, in priority order:
   - Contains `dist/<tool-dir>/` → already-built repo. Use `dist/<tool-dir>/` as the tool tree.
   - Contains `skills/` and a `Makefile` at root → unbuilt repo. Run `make build` in the directory, then use `dist/<tool-dir>/` as the tool tree. Requires Python 3 and `make`.
   - Contains the per-tool layout directly at root (e.g., `.agents/skills/arnold-*/` for Codex, `.agent/skills/arnold-*/` for Antigravity) → extracted tarball. Use the directory itself as the tool tree.
3. If none of the sentinels match, stop and report: "source path does not look like an Arnold distribution."

**If source is a URL**:

1. Download the asset to a temp directory. Validate the response is a tarball (gzip magic bytes `1f 8b`); if not, stop.
2. Extract. Apply the same sentinel check as the local-path case to determine shape.
3. Proceed as with local path.

---

## Step 2b — Validate the resolved source

Before any writes to the user's project, verify the tool tree:

1. **Version.** Read `VERSION` at the root of the tool tree (or, if absent, at the root of the enclosing distribution). Report the resolved version to the user. If the user specified a version that does not match, stop.
2. **Layout.** Confirm the tool tree contains the structure expected for the user's tool (detailed per-tool in Step 3). If the structure is wrong, stop and report what was expected vs. what was found.
3. **Sanity.** The tool tree must contain at least one `arnold-*` skill directory. An empty tree is a bug in the source, not a valid install.

If any check fails, stop. Do not proceed to Step 3 with an unverified source.

---

## Step 3 — Install per tool

Follow the section matching the user's tool. Each specifies the expected tool-tree layout and the destination paths inside `<target>`. Do not freelance paths.

### 3a — Codex

Expected tool-tree layout:
```
.agents/skills/arnold-<n>/SKILL.md   # 17 skills, names like arnold-init, arnold-check, ...
AGENTS.md                             # rules content
```

Operations:
1. Create `<target>/.agents/skills/` if it does not exist.
2. For each `arnold-<n>/` directory in the tool tree, copy the entire directory to `<target>/.agents/skills/arnold-<n>/`. If the destination already exists, remove it first (the user has already confirmed overwrite in Step 1).
3. Merge the source `AGENTS.md` content into `<target>/AGENTS.md` using the marker convention in Step 4.

### 3b — Antigravity

Expected tool-tree layout:
```
.agent/skills/arnold-<n>/SKILL.md     # singular .agent — Antigravity convention
```

Operations:
1. Create `<target>/.agent/skills/` if it does not exist. **Note the singular `.agent` — this is not a typo and is distinct from Codex's `.agents/`.**
2. For each `arnold-<n>/` directory, copy to `<target>/.agent/skills/arnold-<n>/`.
3. Antigravity has no rules-file equivalent. Do not write an `AGENTS.md`.

### 3c — Claude Code (manual fallback only — prefer marketplace)

Expected tool-tree layout: the `claude-plugin` tree contains a `.claude-plugin/` manifest directory and a `skills/` tree.

Operations:
1. Copy each `skills/arnold-<n>/SKILL.md` to `<target>/.claude/commands/arnold/<n>.md` (the manual install uses the legacy `commands/` layout; the plugin layout is reserved for marketplace installs).
2. Merge rules into `<target>/CLAUDE.md` using the marker convention.

### 3d — Cursor (manual fallback only — prefer marketplace)

Expected tool-tree layout: the `cursor-plugin` tree has hyphenated skill names already applied (`arnold-init` not `arnold:init`).

Operations:
1. Copy `rules/arnold-rules.mdc` to `<target>/.cursor/rules/arnold-rules.mdc`.
2. Copy each skill to `<target>/.cursor/commands/<n>.md`.

### 3e — Windsurf, Gemini CLI, and other agent tools

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
- **Never modify content outside the marker block.** Other tools and the user may have written content there.

This convention is load-bearing for clean uninstall. Do not deviate from the exact marker text — uninstall searches for byte-exact matches.

---

## Step 5 — Verify the install

After file operations complete, run these checks. If any fail, report the specific failure to the user and offer to roll back.

1. **Skill count matches.** Count subdirectories matching `arnold-*` in the destination skills directory. The count must equal the number of `arnold-*` directories in the source tool tree (17 as of v0.5.0).
2. **Skill structure intact.** For at least three randomly chosen `arnold-*` directories, confirm `SKILL.md` exists and starts with YAML frontmatter (a line containing only `---`).
3. **Markers balanced.** If a rules file was written, confirm both start and end markers are present, exactly once each.
4. **No half-install on abort.** If you aborted partway through file operations, remove everything you created in this run.

---

## Step 6 — Report to the user

After successful install, send one short message containing:

- The tool you installed for and the resolved version
- The source you installed from (repo+ref, local path, or URL — so the user knows what bits they got)
- The destination directory for skills
- The rules file modified, if any
- One concrete invocation example for the user's tool (e.g., "type `/arnold:init` to create the initial spec" for Claude Code, or "the `arnold-init` skill is now auto-discoverable" for Codex)
- The exact prompt the user can give you to uninstall later

Do not enumerate every file copied. The verification step in Step 5 is for you, not the user.

---

## Uninstall

If the user asks you to uninstall Arnold, mirror the install procedure in reverse. Uninstall does not need a source — it only needs the target project directory and the tool.

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
| Source not specified and default (`ArtifactHQ/arnold`) unreachable | Stop. Ask the user for a local path or internal URL. |
| Repo-spec source: release asset 404 and ref is not a release tag | Fall back to clone + `make build` as specified in Step 2. |
| Local-path source: path does not exist | Stop. Report. Do not create it or fall back to the network. |
| Local-path source: path exists but matches no sentinel | Stop. Report "source path does not look like an Arnold distribution." |
| URL source: response is not a gzip tarball | Stop. Report. Do not retry against a different URL. |
| `make` or Python 3 missing when build is required | Stop. Report. Do not attempt a third path. |
| Version mismatch (user-specified ≠ resolved) | Stop. Report both values. Let the user decide. |
| Permission denied on file write | Stop. Report. Do not retry with elevated permissions or `sudo`. |
| Target directory does not look like a project | Ask the user to confirm the path explicitly. |
| Existing Arnold install detected (skill dirs or marker block present) | Confirm with the user before overwriting. Do not silently replace. |
| Sandboxed without filesystem write access | Stop. Print the file list and exact operations you would perform. Ask the user to grant access or apply manually. |
| Network fetch blocked (repo-spec or URL source) | Report to the user and ask whether they have a local path to install from instead. |

---

## Determinism contract

This procedure is deterministic. For a given Arnold version and a given target project, two runs of this procedure must produce byte-identical results — regardless of which source shape was used — and must produce results identical to running `scripts/install-skills.sh --tool=<tool> --target=<project>` from a clone of the repo at the same version. If your execution diverges from any of these, that is a bug in this document or in your execution. Report the divergence; do not paper over it.

## Notes for the agent

- Copy skill files verbatim. Do not edit frontmatter, rename keys, "fix" formatting, or summarize content. The build system has already applied the correct per-tool transforms; the tool tree is final.
- The rules content is also final. Do not summarize it into the rules file — copy the source `AGENTS.md` (or equivalent) verbatim into the marker block.
- If the user asks you to "customize" Arnold during install (different paths, renamed skills, etc.), refuse and explain that this procedure installs Arnold as-shipped. Customization happens after install via the user's own project conventions.
- The source is the only variable the user controls; everything downstream of source resolution is fixed. If you find yourself wanting to vary something else per-user, stop and ask — it's probably a bug.
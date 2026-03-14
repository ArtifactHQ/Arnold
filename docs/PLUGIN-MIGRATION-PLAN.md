# Arnold — Plugin & Cross-Agent Migration Plan

> **Date:** March 14, 2026
> **Authors:** Chris Sotraidis + Claude
> **Status:** Phase 1 and Phase 2 complete — plugin manifest and skills shipped

---

## Executive Summary

Arnold currently ships as a bash installer (`install.sh`) that copies slash commands into `.claude/commands/arnold/`. This works but limits distribution to manual installs and Claude Code only.

Research reveals three distribution paths that Arnold should support — not as alternatives, but as complementary layers:

| Method | Reach | Install UX | Auto-Update | Uninstall |
|--------|-------|-----------|-------------|-----------|
| **Shell script** (`install.sh`) | Any tool, any platform | `curl \| bash` | Manual re-run | `--uninstall` flag |
| **Claude Code Plugin** | Claude Code native | `/plugin install` | Automatic at startup | `/plugin uninstall` |
| **Agent Skills** (`.agents/skills/`) | 32+ AI coding tools | Copy to project | Via Git | Delete directory |

The recommended path: **ship all three from the same repo**, with the Agent Skills format as the canonical source. The plugin manifest and install script both reference the same skill files.

---

## Part 1: The Agent Skills Standard

### What It Is

Agent Skills is an open standard (agentskills.io) originally developed by Anthropic and adopted by 32+ tools. A skill is a directory containing a `SKILL.md` file with YAML frontmatter and markdown instructions.

### Who Supports It

| Tool | Discovery Path | Status |
|------|---------------|--------|
| Claude Code | `.claude/skills/`, `.agents/skills/` | Full support (originator) |
| Cursor | `.cursor/skills/`, `.agents/skills/` | Full support |
| Windsurf | `.windsurf/skills/`, `.agents/skills/` | Full support |
| Gemini CLI | `.gemini/skills/`, `.agents/skills/` | Full support |
| Codex CLI | `.agents/skills/`, `~/.agents/skills/` | Full support |
| OpenCode | `.agents/skills/` | Supported |
| GitHub Copilot | `.agents/skills/` | Supported |
| VS Code | `.agents/skills/` | Supported |
| JetBrains Junie | `.agents/skills/` | Supported |
| Roo Code | `.agents/skills/` | Supported |
| 20+ others | `.agents/skills/` | Supported |

**The universal fallback path is `.agents/skills/`** — nearly all tools scan this directory.

### What Arnold's Skills Would Look Like

```
.agents/skills/
├── arnold-init/
│   └── SKILL.md          # /arnold-init (or /arnold:init in Claude Code plugin)
├── arnold-plan/
│   └── SKILL.md
├── arnold-check/
│   └── SKILL.md
├── arnold-update/
│   └── SKILL.md
└── arnold-status/
    └── SKILL.md
```

Each `SKILL.md` uses the same YAML frontmatter Arnold already has:

```yaml
---
name: arnold-init
description: "Initialize Arnold — scaffold docs for your project"
allowed-tools:
  - Read
  - Write
  - Edit
  - Bash
  - Glob
  - Grep
---

[Full prompt content — same as current init.md]
```

### Naming Consideration

In the Agent Skills standard (non-plugin), there's no automatic namespacing. The skill name IS the command name. So:
- `.agents/skills/init/SKILL.md` → `/init` (conflicts with other tools)
- `.agents/skills/arnold-init/SKILL.md` → `/arnold-init` (safe, but uses hyphen not colon)

In Claude Code's **plugin** system, namespacing is automatic:
- Plugin name `arnold` + `skills/init/SKILL.md` → `/arnold:init` (colon-separated)

**Decision needed:** Do we use `arnold-init` (cross-agent compatible) or `init` (relies on plugin namespacing for Claude Code, potentially conflicts elsewhere)?

**Recommendation:** Use `arnold-init` as the directory/skill name for cross-agent compatibility. In the Claude Code plugin manifest, the plugin name `arnold` will override this, giving Claude Code users the clean `/arnold:init` experience via automatic namespacing.

---

## Part 2: Claude Code Plugin

### What It Is

Claude Code has a first-party plugin system with:
- A manifest file (`.claude-plugin/plugin.json`)
- Marketplace distribution (`.claude-plugin/marketplace.json`)
- Automatic install/uninstall/update via `/plugin` commands
- Automatic namespacing (`plugin-name:skill-name`)
- Auto-updates at startup

### What Arnold's Plugin Would Look Like

**Directory additions to the repo:**

```
Arnold-Lite/
├── .claude-plugin/
│   ├── plugin.json              # Plugin manifest
│   └── marketplace.json         # Self-contained marketplace
├── skills/                      # Plugin skills (Claude Code discovers these)
│   ├── init/
│   │   └── SKILL.md
│   ├── plan/
│   │   └── SKILL.md
│   ├── check/
│   │   └── SKILL.md
│   ├── update/
│   │   └── SKILL.md
│   └── status/
│       └── SKILL.md
├── commands/                    # Legacy commands (keep for install.sh)
│   └── arnold/
│       ├── init.md
│       ├── plan.md
│       ├── check.md
│       ├── update.md
│       └── status.md
├── install.sh                   # Legacy installer (keep)
├── CLAUDE.md                    # Template (keep)
└── ...existing files
```

### plugin.json

```json
{
  "name": "arnold",
  "version": "0.1.0",
  "description": "Documentation-first development toolkit. Write requirements in plain English, build with any coding agent, check that what got built matches what you asked for.",
  "author": {
    "name": "Artifact",
    "url": "https://artifact.new"
  },
  "homepage": "https://github.com/ArtifactHQ/Arnold-Lite",
  "repository": "https://github.com/ArtifactHQ/Arnold-Lite",
  "license": "MIT",
  "keywords": [
    "documentation",
    "docs-first",
    "drift-detection",
    "requirements",
    "specification"
  ]
}
```

### marketplace.json

```json
{
  "name": "arnold-marketplace",
  "owner": {
    "name": "Artifact",
    "email": "hello@artifact.new"
  },
  "metadata": {
    "description": "Arnold — documentation-first development toolkit",
    "version": "1.0.0"
  },
  "plugins": [
    {
      "name": "arnold",
      "source": ".",
      "description": "Write requirements in plain English. Build with any coding agent. Check that what got built matches what you asked for.",
      "version": "0.1.0",
      "author": {
        "name": "Artifact"
      },
      "homepage": "https://github.com/ArtifactHQ/Arnold-Lite",
      "repository": "https://github.com/ArtifactHQ/Arnold-Lite",
      "license": "MIT",
      "keywords": ["documentation", "docs-first", "drift-detection"],
      "category": "productivity"
    }
  ]
}
```

### Install Experience for Users

**Plugin install (Claude Code only):**
```
# One-time: add the Arnold marketplace
/plugin marketplace add ArtifactHQ/Arnold-Lite

# Install Arnold
/plugin install arnold@arnold-marketplace

# That's it. /arnold:init, /arnold:check, etc. are available immediately.
# Auto-updates on Claude Code startup.
```

**vs. current install.sh:**
```bash
curl -fsSL https://raw.githubusercontent.com/ArtifactHQ/Arnold-Lite/main/install.sh | bash
```

### What the Plugin System Handles That install.sh Currently Does

| Concern | install.sh (current) | Plugin system |
|---------|---------------------|---------------|
| Copy commands | Manual curl + cp | Automatic |
| CLAUDE.md rules | Append with markers | Background skill (see below) |
| Namespacing | Directory convention | Automatic from plugin name |
| Updates | Re-run install | Auto-update at startup |
| Uninstall | `--uninstall` flag | `/plugin uninstall` |
| Version tracking | Hardcoded `ARNOLD_VERSION` | `plugin.json` version |
| Team distribution | Commit `.claude/commands/` | `extraKnownMarketplaces` in settings |

### Handling CLAUDE.md Rules in the Plugin

The current `install.sh` appends Arnold's documentation-first rules to the user's CLAUDE.md. In the plugin system, this can be handled with a **background knowledge skill**:

```
skills/
└── arnold-rules/
    └── SKILL.md
```

```yaml
---
name: arnold-rules
description: "Arnold documentation-first development rules — always active when Arnold is installed"
user-invocable: false
disable-model-invocation: false
---

[Content of current CLAUDE.md template — the Before/After Writing Code rules,
 doc structure conventions, status markers, provenance tags, etc.]
```

With `user-invocable: false`, this skill doesn't appear in the `/` menu. With `disable-model-invocation: false` (the default), Claude loads its description into context and can reference the full content when relevant. This replaces the CLAUDE.md injection entirely — no marker-based append/remove, no CLAUDE.md surgery.

---

## Part 3: Pros and Cons

### Shell Script (install.sh)

**Pros:**
- Works with ANY tool (Cursor, Windsurf, Aider, etc.) — not Claude Code specific
- No dependencies — just bash and curl
- User controls exactly what's in their project
- Simple to understand and debug
- Works offline after install
- Can be committed to Git for team distribution

**Cons:**
- Manual install, manual update, manual uninstall
- CLAUDE.md marker-based injection is fragile
- No version tracking after install
- No auto-discovery by the tool — user must know commands exist
- Platform-specific issues (BSD sed, interactive prompts)
- Doesn't benefit from Claude Code's plugin infrastructure

**Best for:** Users of non-Claude-Code tools, users who want maximum control, CI/CD environments, teams that commit tooling config to their repo.

### Claude Code Plugin

**Pros:**
- First-class Claude Code citizen — native install/update/uninstall
- Automatic namespacing (`/arnold:init`)
- Auto-updates at startup
- Marketplace discovery — users can find Arnold without knowing the GitHub URL
- Background knowledge skill replaces CLAUDE.md injection (cleaner)
- Team distribution via `extraKnownMarketplaces` in settings
- `/reload-plugins` for live development
- Version tracking, error reporting, validation

**Cons:**
- Claude Code only — doesn't help Cursor, Windsurf, Gemini CLI users
- Requires marketplace setup (even if self-hosted)
- Users must trust the plugin system (permissions, auto-updates)
- Plugin files are cached — can't reference files outside plugin directory
- Minimum Claude Code version required (v1.0.33+)
- Debugging is harder (cached copies, auto-updates)

**Best for:** Claude Code power users, teams standardized on Claude Code, marketplace visibility, frictionless install/update experience.

### Agent Skills (.agents/skills/)

**Pros:**
- Works across 32+ tools — Cursor, Windsurf, Gemini CLI, Codex, GitHub Copilot, VS Code, JetBrains, etc.
- Open standard (agentskills.io) — not vendor-locked
- Same format as Claude Code skills — no conversion needed
- Auto-discovered by tools that scan `.agents/skills/`
- Commit to project repo → instant team distribution
- No installer needed — just copy the directory
- The most future-proof option as more tools adopt the standard

**Cons:**
- No automatic namespacing (must use `arnold-` prefix in directory names)
- No auto-update mechanism — updates come via Git
- No built-in uninstall — delete the directory
- Tools may interpret frontmatter fields differently
- Some tools may not support all frontmatter fields (e.g., `allowed-tools`, `context: fork`)
- The `.agents/` directory convention is newer — some tools may not scan it yet

**Best for:** Projects that use multiple AI coding tools, teams that want one set of skills to work everywhere, open-source projects targeting maximum adoption.

---

## Part 4: Recommended Architecture

### Ship All Three

The repo should support all three distribution methods simultaneously. Here's the proposed structure:

```
Arnold-Lite/
├── .claude-plugin/                    # Claude Code plugin manifest
│   ├── plugin.json
│   └── marketplace.json
│
├── skills/                            # Canonical skill source (used by plugin)
│   ├── init/
│   │   └── SKILL.md
│   ├── plan/
│   │   └── SKILL.md
│   ├── check/
│   │   └── SKILL.md
│   ├── update/
│   │   └── SKILL.md
│   ├── status/
│   │   └── SKILL.md
│   └── arnold-rules/                 # Background knowledge (replaces CLAUDE.md injection)
│       └── SKILL.md
│
├── install.sh                         # Legacy installer for non-Claude-Code users
│   # Updated to:
│   # 1. Copy skills/ to .agents/skills/arnold-*/ (for cross-agent compatibility)
│   # 2. OR copy to .claude/commands/arnold/ (for Claude Code without plugin)
│   # 3. Optionally append rules to CLAUDE.md / AGENTS.md / GEMINI.md
│
├── CLAUDE.md                          # Template (still needed for install.sh path)
├── README.md
├── LICENSE
├── CONTRIBUTING.md
│
├── commands/                          # Keep for backward compatibility
│   └── arnold/
│       ├── init.md
│       ├── plan.md
│       ├── check.md
│       ├── update.md
│       └── status.md
│
├── examples/
│   └── fitness-studio-booking/
│
└── docs/
    ├── ARNOLD-LITE-BUILD-SPEC.md
    └── PLUGIN-MIGRATION-PLAN.md       # This document
```

### How Each Method Works

**Path A — Claude Code Plugin (recommended for Claude Code users):**
1. User runs `/plugin marketplace add ArtifactHQ/Arnold-Lite`
2. User runs `/plugin install arnold@arnold-marketplace`
3. Plugin system reads `.claude-plugin/plugin.json`, discovers `skills/`
4. Commands register as `/arnold:init`, `/arnold:plan`, etc. (auto-namespaced)
5. Background knowledge skill (`arnold-rules`) loads rules into context
6. Auto-updates on startup when version bumps in `plugin.json`
7. Uninstall via `/plugin uninstall`

**Path B — Shell Script (for Cursor, Windsurf, Aider, and other tools):**
1. User runs `curl ... | bash` or `./install.sh`
2. Script detects the user's tool and copies to the right location:
   - `.agents/skills/arnold-init/SKILL.md` (universal Agent Skills path)
   - Appends rules to the appropriate config file (CLAUDE.md, .cursorrules, GEMINI.md, etc.)
3. Update by re-running install
4. Uninstall via `--uninstall`

**Path C — Manual / Git (for teams):**
1. Team adds Arnold's `skills/` directory to their project (or `.agents/skills/`)
2. Commit to Git
3. Every team member who clones gets Arnold automatically
4. Updates via Git pull
5. No installer needed

### Migration Steps

**Phase 1: Add plugin manifest (non-breaking)**
1. Create `.claude-plugin/plugin.json`
2. Create `.claude-plugin/marketplace.json`
3. The existing `commands/arnold/*.md` files continue to work for install.sh users
4. Claude Code plugin users get a new, cleaner install path
5. Both paths coexist

**Phase 2: Create skills/ directory**
1. Create `skills/init/SKILL.md` through `skills/status/SKILL.md`
2. Content is identical to current `commands/arnold/*.md` (same frontmatter, same prompts)
3. Create `skills/arnold-rules/SKILL.md` (background knowledge, replaces CLAUDE.md injection)
4. Keep `commands/arnold/` for backward compatibility

**Phase 3: Update install.sh for cross-agent support**
1. Add `--agent-skills` flag to install to `.agents/skills/` instead of `.claude/commands/`
2. Add tool detection (check for `.cursor/`, `.windsurf/`, `.gemini/` directories)
3. Copy rules to the appropriate config file per tool
4. Keep current behavior as default for backward compatibility

**Phase 4: Submit to Anthropic's official plugin marketplace**
1. Submit via `claude.ai/settings/plugins/submit`
2. If accepted, users can install with just `/plugin install arnold`
3. Auto-updates managed by the marketplace

---

## Part 5: Open Questions

### Q1: Should skills/ replace commands/ or coexist?

**Recommendation: Coexist for v0.2.0, deprecate commands/ in v1.0.**
- The `commands/` directory is what install.sh currently copies
- The `skills/` directory is what the plugin system and Agent Skills standard use
- In Claude Code, if both exist, skills take precedence (no conflict)
- In v1.0, remove `commands/` and update install.sh to copy from `skills/`

### Q2: What about the CLAUDE.md template?

**Recommendation: Keep it for install.sh users, replace with background skill for plugin users.**
- `install.sh` still needs the CLAUDE.md template for non-plugin installs
- The plugin system uses `skills/arnold-rules/SKILL.md` with `user-invocable: false`
- Both accomplish the same thing — injecting Arnold's rules into the agent's context

### Q3: Should install.sh detect Claude Code plugin and skip?

**Recommendation: Yes.**
- If `.claude-plugin/` exists in the target project (unlikely for most users), warn
- If Arnold is already installed as a plugin (check `~/.claude/settings.json` for `enabledPlugins`), skip and suggest using the plugin instead

### Q4: How do we handle the `.agents/skills/` naming (hyphens) vs plugin naming (colons)?

**Recommendation: Accept the difference.**
- Agent Skills (cross-agent): `/arnold-init`, `/arnold-plan`, etc.
- Claude Code Plugin: `/arnold:init`, `/arnold:plan`, etc.
- Both are clean. The colon is Claude Code's convention; hyphens are the universal convention.
- Documentation should show both forms.

### Q5: Should we submit to the Anthropic official marketplace?

**Recommendation: Yes, after v0.2.0 stabilizes.**
- Being in the official marketplace dramatically increases discoverability
- Arnold is exactly the kind of tool Anthropic would want in their ecosystem
- Wait until the plugin version is tested and stable

---

## Part 6: Timeline

| Phase | What | When |
|-------|------|------|
| **v0.1.0** | Shell script install, Claude Code commands | Done |
| **v0.2.0** | Add plugin manifest + marketplace.json + skills/ directory | Done |
| **v0.3.0** | Update install.sh for cross-agent support (.agents/skills/) | Following sprint |
| **v1.0.0** | Submit to Anthropic marketplace, deprecate commands/ | When stable |

---

*This plan was compiled from research into: Claude Code plugin docs (code.claude.com), the Agent Skills standard (agentskills.io), GSD (get-shit-done) architecture, Compound Engineering Plugin (EveryInc), Cursor/Windsurf/Gemini CLI/Codex CLI extension systems, and community plugin examples.*

*Hold on to your docs.*

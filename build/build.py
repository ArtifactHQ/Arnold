#!/usr/bin/env python3
"""
Arnold build system — generate per-target plugin/skill artifacts from one canonical source.

Usage:
    python3 build/build.py <target>
    python3 build/build.py all

Targets:
    claude       -> dist/claude-plugin/     (Claude Code plugin, submit-ready)
    cursor       -> dist/cursor-plugin/     (Cursor plugin with frontmatter transforms)
    codex        -> dist/codex-skills/      (OpenAI Codex skills at .agents/skills/)
    antigravity  -> dist/antigravity-skills/ (Google Antigravity skills at .agent/skills/)
    all          -> all of the above

Canonical source: skills/*/SKILL.md
Build output: dist/<target>/  (gitignored — see .gitignore)

Determinism: every build is pure — same source yields byte-identical output. File
mtimes are pinned to the source file mtime. No network calls. No timestamps in output.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import sys
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parent.parent
SOURCE_SKILLS = REPO_ROOT / "skills"
SOURCE_CLAUDE_PLUGIN = REPO_ROOT / ".claude-plugin"
SOURCE_CLAUDE_MD = REPO_ROOT / "CLAUDE.md"
DIST = REPO_ROOT / "dist"


# ─── Frontmatter parsing ──────────────────────────────────────────────
# Kept deliberately minimal: SKILL.md frontmatter is a small, well-formed subset
# of YAML. We preserve key order and re-emit. No external YAML dep so that
# `make build` works on a clean checkout with nothing but the Python stdlib.


def split_frontmatter(text: str) -> tuple[list[tuple[str, str]], str]:
    """Parse `---\\nkey: value\\n---\\n…` preamble into an ordered [(key, raw_value)] list.

    `raw_value` is the exact text after the colon, including any indented
    continuation lines (for list values). Returns ([], text) if no frontmatter.
    """
    if not text.startswith("---\n"):
        return [], text

    end = text.find("\n---\n", 4)
    if end == -1:
        return [], text

    fm_text = text[4:end]
    body = text[end + 5 :]

    entries: list[tuple[str, str]] = []
    lines = fm_text.splitlines()
    i = 0
    while i < len(lines):
        line = lines[i]
        if not line.strip() or line.startswith("#"):
            i += 1
            continue
        if ":" not in line:
            raise ValueError(f"Malformed frontmatter line (no colon): {line!r}")
        key, _, rest = line.partition(":")
        key = key.strip()
        raw_value_lines = [rest]
        # Collect indented continuation lines (multi-line list values)
        j = i + 1
        while j < len(lines) and (lines[j].startswith((" ", "\t")) or lines[j].startswith("-")):
            # list-style continuation: lines starting with `  -` or `-`
            # only consume lines that are clearly part of a yaml value block
            if lines[j].lstrip().startswith("-") or lines[j].startswith((" ", "\t")):
                raw_value_lines.append(lines[j])
                j += 1
            else:
                break
        entries.append((key, "\n".join(raw_value_lines)))
        i = j
    return entries, body


def emit_frontmatter(entries: list[tuple[str, str]], body: str) -> str:
    """Re-serialize (entries, body) to a full SKILL.md string."""
    if not entries:
        return body
    lines = ["---"]
    for key, raw in entries:
        if "\n" in raw:
            # multi-line value (list). Emit key: then the raw continuation.
            first, _, rest = raw.partition("\n")
            lines.append(f"{key}:{first}")
            lines.append(rest)
        else:
            lines.append(f"{key}:{raw}")
    lines.append("---")
    return "\n".join(lines) + "\n" + body


def list_skill_dirs() -> list[Path]:
    """Return sorted list of skill directories (deterministic order)."""
    return sorted([d for d in SOURCE_SKILLS.iterdir() if d.is_dir() and (d / "SKILL.md").is_file()])


def pin_mtime(path: Path, source: Path) -> None:
    """Copy mtime from source to path for deterministic output."""
    st = source.stat()
    os.utime(path, (st.st_atime, st.st_mtime))


# ─── Per-target builders ──────────────────────────────────────────────


def build_claude() -> None:
    """Claude Code plugin. Submit-ready as-is; just copy source to dist/."""
    target = DIST / "claude-plugin"
    if target.exists():
        shutil.rmtree(target)
    target.mkdir(parents=True)

    # .claude-plugin/ manifests (plugin.json, marketplace.json) — copy verbatim
    claude_plugin_dir = target / ".claude-plugin"
    shutil.copytree(SOURCE_CLAUDE_PLUGIN, claude_plugin_dir)

    # skills/ tree — copy verbatim; Claude Code accepts SKILL.md frontmatter as-is
    dest_skills = target / "skills"
    dest_skills.mkdir()
    for skill_dir in list_skill_dirs():
        dest = dest_skills / skill_dir.name
        shutil.copytree(skill_dir, dest)

    # Pin mtimes for determinism
    for p in sorted(target.rglob("*")):
        if p.is_file():
            rel = p.relative_to(target)
            # Find the original source file
            if rel.parts[0] == ".claude-plugin":
                src = SOURCE_CLAUDE_PLUGIN / Path(*rel.parts[1:])
            elif rel.parts[0] == "skills":
                src = SOURCE_SKILLS / Path(*rel.parts[1:])
            else:
                continue
            if src.is_file():
                pin_mtime(p, src)


def build_cursor() -> None:
    """Cursor plugin. Four transforms per PRD FR-014 (Phase 0 S0.2 findings).

    1. Manifest at `.cursor-plugin/plugin.json` (not `.claude-plugin/`)
    2. Rename `name: arnold:X` -> `arnold-X` in all SKILL.md frontmatter
    3. Strip three fields: `argument-hint`, `allowed-tools`, `user-invocable`
    4. Relocate arnold-rules/ -> rules/arnold-rules.mdc with `alwaysApply: false`
    """
    target = DIST / "cursor-plugin"
    if target.exists():
        shutil.rmtree(target)
    target.mkdir(parents=True)

    # .cursor-plugin/plugin.json — minimal manifest (only `name` required; additionalProperties: false)
    (target / ".cursor-plugin").mkdir()
    plugin_manifest = {
        "name": "arnold",
        "displayName": "Arnold",
        "description": "Documentation-first development toolkit",
        "version": "0.4.0",
        "author": {"name": "Artifact", "email": "hello@artifact.new"},
        "homepage": "https://artifact.new",
        "repository": "https://github.com/ArtifactHQ/arnold",
        "license": "MIT",
        "keywords": ["documentation", "specs", "drift-detection", "arnold"],
    }
    (target / ".cursor-plugin" / "plugin.json").write_text(
        json.dumps(plugin_manifest, indent=2) + "\n"
    )

    # skills/ tree — transformed SKILL.md files (excluding arnold-rules which becomes a rule)
    skills_dest = target / "skills"
    skills_dest.mkdir()

    strip_keys = {"argument-hint", "allowed-tools", "user-invocable"}

    for skill_dir in list_skill_dirs():
        if skill_dir.name == "arnold-rules":
            continue  # relocated below

        src_skill = skill_dir / "SKILL.md"
        src_text = src_skill.read_text()
        entries, body = split_frontmatter(src_text)

        # Transform frontmatter
        new_entries: list[tuple[str, str]] = []
        for key, value in entries:
            if key in strip_keys:
                continue
            if key == "name":
                # arnold:init -> arnold-init (colon to hyphen; Cursor kebab-case regex)
                new_entries.append((key, value.replace(":", "-")))
            else:
                new_entries.append((key, value))

        out_text = emit_frontmatter(new_entries, body)
        dest_dir = skills_dest / skill_dir.name
        dest_dir.mkdir()
        dest_file = dest_dir / "SKILL.md"
        dest_file.write_text(out_text)
        pin_mtime(dest_file, src_skill)

    # rules/arnold-rules.mdc — relocated from skills/arnold-rules/SKILL.md
    rules_dest = target / "rules"
    rules_dest.mkdir()
    src_rules = SOURCE_SKILLS / "arnold-rules" / "SKILL.md"
    entries, body = split_frontmatter(src_rules.read_text())

    # Rules frontmatter: description + alwaysApply (Cursor rule-specific fields)
    desc = next((v for k, v in entries if k == "description"), ' "Arnold documentation-first development rules"')
    rules_text = f"---\ndescription:{desc}\nalwaysApply: false\n---\n{body}"
    rules_file = rules_dest / "arnold-rules.mdc"
    rules_file.write_text(rules_text)
    pin_mtime(rules_file, src_rules)


def build_codex_plugin() -> None:
    """OpenAI Codex user-global plugin. Manifest + short-named skills (plugin namespaces).

    Layout per INSTALL.md Step 3a:
        .codex-plugin/plugin.json       # manifest
        skills/<name>/SKILL.md          # short dir names; arnold: prefix stripped from frontmatter
        AGENTS.md                       # rules content
    """
    target = DIST / "codex-plugin"
    if target.exists():
        shutil.rmtree(target)
    target.mkdir(parents=True)

    (target / ".codex-plugin").mkdir()
    plugin_manifest = {
        "name": "arnold",
        "version": "0.4.0",
        "description": "Documentation-first development toolkit",
        "author": {"name": "Artifact", "url": "https://artifact.new"},
        "homepage": "https://artifact.new",
        "repository": "https://github.com/ArtifactHQ/arnold",
        "license": "MIT",
        "keywords": ["documentation", "specs", "drift-detection", "arnold"],
    }
    (target / ".codex-plugin" / "plugin.json").write_text(
        json.dumps(plugin_manifest, indent=2) + "\n"
    )

    (target / "AGENTS.md").write_text(SOURCE_CLAUDE_MD.read_text())
    pin_mtime(target / "AGENTS.md", SOURCE_CLAUDE_MD)

    skills_dest = target / "skills"
    skills_dest.mkdir()

    strip_keys = {"argument-hint", "allowed-tools", "user-invocable"}

    for skill_dir in list_skill_dirs():
        if skill_dir.name == "arnold-rules":
            continue  # content already in AGENTS.md

        src_skill = skill_dir / "SKILL.md"
        entries, body = split_frontmatter(src_skill.read_text())

        new_entries: list[tuple[str, str]] = []
        for key, value in entries:
            if key in strip_keys:
                continue
            if key == "name":
                # arnold:init -> init (the `arnold` plugin namespaces automatically)
                new_entries.append((key, value.replace("arnold:", "")))
            else:
                new_entries.append((key, value))

        out_text = emit_frontmatter(new_entries, body)
        dest_dir = skills_dest / skill_dir.name
        dest_dir.mkdir()
        dest_file = dest_dir / "SKILL.md"
        dest_file.write_text(out_text)
        pin_mtime(dest_file, src_skill)


def build_codex() -> None:
    """OpenAI Codex skills. Project-scoped path: .agents/skills/ (plural)."""
    target = DIST / "codex-skills"
    if target.exists():
        shutil.rmtree(target)
    target.mkdir(parents=True)

    # AGENTS.md at repo root (Codex reads rules from here, CLAUDE.md-equivalent)
    (target / "AGENTS.md").write_text(SOURCE_CLAUDE_MD.read_text())
    pin_mtime(target / "AGENTS.md", SOURCE_CLAUDE_MD)

    # .agents/skills/arnold-<name>/SKILL.md (plural — the Codex path)
    skills_dest = target / ".agents" / "skills"
    skills_dest.mkdir(parents=True)

    strip_keys = {"argument-hint", "allowed-tools", "user-invocable"}

    for skill_dir in list_skill_dirs():
        if skill_dir.name == "arnold-rules":
            continue  # content already in AGENTS.md

        src_skill = skill_dir / "SKILL.md"
        entries, body = split_frontmatter(src_skill.read_text())

        new_entries: list[tuple[str, str]] = []
        for key, value in entries:
            if key in strip_keys:
                continue
            if key == "name":
                # Codex agentskills.io spec uses kebab-case; colons unclear — use hyphen for safety
                new_entries.append((key, value.replace(":", "-")))
            else:
                new_entries.append((key, value))

        out_text = emit_frontmatter(new_entries, body)
        dest_dir = skills_dest / f"arnold-{skill_dir.name}"
        dest_dir.mkdir()
        dest_file = dest_dir / "SKILL.md"
        dest_file.write_text(out_text)
        pin_mtime(dest_file, src_skill)


def build_antigravity() -> None:
    """Google Antigravity skills. Project-scoped path: .agent/skills/ (singular)."""
    target = DIST / "antigravity-skills"
    if target.exists():
        shutil.rmtree(target)
    target.mkdir(parents=True)

    # .agent/skills/arnold-<name>/SKILL.md (singular — the Antigravity path)
    skills_dest = target / ".agent" / "skills"
    skills_dest.mkdir(parents=True)

    strip_keys = {"argument-hint", "allowed-tools", "user-invocable"}

    for skill_dir in list_skill_dirs():
        if skill_dir.name == "arnold-rules":
            # Antigravity reads skills, not a top-level rules file. Keep arnold-rules as a skill.
            pass

        src_skill = skill_dir / "SKILL.md"
        entries, body = split_frontmatter(src_skill.read_text())

        new_entries: list[tuple[str, str]] = []
        for key, value in entries:
            if key in strip_keys:
                continue
            if key == "name":
                new_entries.append((key, value.replace(":", "-")))
            else:
                new_entries.append((key, value))

        out_text = emit_frontmatter(new_entries, body)
        dest_name = skill_dir.name if skill_dir.name == "arnold-rules" else f"arnold-{skill_dir.name}"
        dest_dir = skills_dest / dest_name
        dest_dir.mkdir()
        dest_file = dest_dir / "SKILL.md"
        dest_file.write_text(out_text)
        pin_mtime(dest_file, src_skill)


# ─── Validation ───────────────────────────────────────────────────────
# Pre-flight manifest + frontmatter checks. Catches the common rejections
# documented in Phase 0 S0.1 / S0.2 before submission to either marketplace.

import re

KEBAB_CASE_RE = re.compile(r"^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$")
CLAUDE_RESERVED_PREFIXES = ("claude-", "claude_", "anthropic-", "anthropic_")


def _fail(errors: list[str], msg: str) -> None:
    errors.append(msg)


def validate_claude_plugin() -> list[str]:
    """Validate dist/claude-plugin/ against the schema documented in
    code.claude.com/docs/en/plugins-reference (Phase 0 S0.1 findings).
    Returns list of error strings; empty means valid."""
    errors: list[str] = []
    root = DIST / "claude-plugin"
    if not root.exists():
        return [f"{root} does not exist — run `make claude` first"]

    plugin_json = root / ".claude-plugin" / "plugin.json"
    if not plugin_json.exists():
        _fail(errors, f"missing {plugin_json.relative_to(REPO_ROOT)}")
        return errors

    data = json.loads(plugin_json.read_text())

    # Required: name
    if "name" not in data:
        _fail(errors, "plugin.json missing required field: name")
    else:
        name = data["name"]
        if not KEBAB_CASE_RE.match(name):
            _fail(errors, f"plugin.json name {name!r} is not kebab-case")
        if any(name.startswith(p) for p in CLAUDE_RESERVED_PREFIXES):
            _fail(errors, f"plugin.json name {name!r} starts with reserved prefix")

    # marketplace.json required fields
    mp_json = root / ".claude-plugin" / "marketplace.json"
    if mp_json.exists():
        mp = json.loads(mp_json.read_text())
        for required in ("name", "owner", "plugins"):
            if required not in mp:
                _fail(errors, f"marketplace.json missing required field: {required}")
        if isinstance(mp.get("owner"), dict) and "name" not in mp["owner"]:
            _fail(errors, "marketplace.json owner missing required subfield: name")
        for i, p in enumerate(mp.get("plugins", [])):
            if "name" not in p:
                _fail(errors, f"marketplace.json plugins[{i}] missing: name")
            if "source" not in p:
                _fail(errors, f"marketplace.json plugins[{i}] missing: source")

    # skills/ tree must exist and have at least one SKILL.md
    skills_dir = root / "skills"
    if not skills_dir.exists():
        _fail(errors, "skills/ directory missing from plugin root")
    elif not any(skills_dir.rglob("SKILL.md")):
        _fail(errors, "skills/ contains no SKILL.md files")

    # Components must NOT live inside .claude-plugin/ (plugin-reference warning)
    cp = root / ".claude-plugin"
    for forbidden in ("skills", "commands", "agents", "hooks"):
        if (cp / forbidden).exists():
            _fail(errors, f".claude-plugin/{forbidden}/ exists — components must be at plugin root")

    return errors


def validate_cursor_plugin() -> list[str]:
    """Validate dist/cursor-plugin/ against cursor.com/schemas (Phase 0 S0.2).
    Cursor enforces additionalProperties: false on plugin.json."""
    errors: list[str] = []
    root = DIST / "cursor-plugin"
    if not root.exists():
        return [f"{root} does not exist — run `make cursor` first"]

    plugin_json = root / ".cursor-plugin" / "plugin.json"
    if not plugin_json.exists():
        _fail(errors, f"missing {plugin_json.relative_to(REPO_ROOT)}")
        return errors

    data = json.loads(plugin_json.read_text())

    if "name" not in data:
        _fail(errors, "plugin.json missing required field: name")
    else:
        name = data["name"]
        if not KEBAB_CASE_RE.match(name):
            _fail(errors, f"plugin.json name {name!r} is not kebab-case (Cursor regex)")

    # Known-valid Cursor plugin.json keys (from S0.2 schema review)
    allowed_keys = {
        "name", "displayName", "description", "version", "author", "publisher",
        "homepage", "repository", "license", "logo", "keywords", "category", "tags",
        "commands", "agents", "skills", "rules", "hooks", "mcpServers",
    }
    unknown = set(data) - allowed_keys
    if unknown:
        _fail(errors, f"plugin.json has unknown keys (Cursor additionalProperties:false): {sorted(unknown)}")

    # SKILL.md frontmatter must not contain stripped keys
    stripped = {"argument-hint", "allowed-tools", "user-invocable"}
    for skill_md in sorted((root / "skills").rglob("SKILL.md")) if (root / "skills").exists() else []:
        entries, _ = split_frontmatter(skill_md.read_text())
        present_keys = {k for k, _ in entries}
        leaked = present_keys & stripped
        if leaked:
            _fail(errors, f"{skill_md.relative_to(REPO_ROOT)} has Claude-only keys: {sorted(leaked)}")
        # name must be kebab-case (no colons)
        for k, v in entries:
            if k == "name" and ":" in v:
                _fail(errors, f"{skill_md.relative_to(REPO_ROOT)} name contains colon (kebab-case violation): {v.strip()}")

    # rules/arnold-rules.mdc must exist after relocation
    rules_file = root / "rules" / "arnold-rules.mdc"
    if not rules_file.exists():
        _fail(errors, "rules/arnold-rules.mdc missing — arnold-rules relocation failed")

    return errors


def validate_codex_plugin() -> list[str]:
    """Validate dist/codex-plugin/ (INSTALL.md Step 3a)."""
    errors: list[str] = []
    root = DIST / "codex-plugin"
    if not root.exists():
        return [f"{root} does not exist — run `make codex-plugin` first"]

    plugin_json = root / ".codex-plugin" / "plugin.json"
    if not plugin_json.exists():
        _fail(errors, f"missing {plugin_json.relative_to(REPO_ROOT)}")
        return errors

    data = json.loads(plugin_json.read_text())
    if "name" not in data:
        _fail(errors, "plugin.json missing required field: name")
    elif not KEBAB_CASE_RE.match(data["name"]):
        _fail(errors, f"plugin.json name {data['name']!r} is not kebab-case")

    skills_dir = root / "skills"
    if not skills_dir.exists():
        _fail(errors, "skills/ directory missing from plugin root")
    else:
        # Skill dirs must be short-named (plugin namespaces under plugin.name automatically)
        for d in sorted(skills_dir.iterdir()):
            if d.is_dir() and d.name.startswith("arnold-"):
                _fail(errors, f"skill directory {d.name!r} should be short-named (plugin namespaces)")
        if not any(skills_dir.rglob("SKILL.md")):
            _fail(errors, "skills/ contains no SKILL.md files")

    if not (root / "AGENTS.md").exists():
        _fail(errors, "AGENTS.md missing from tool-tree root")

    # arnold: prefix must be stripped from frontmatter name in every SKILL.md
    for skill_md in sorted(skills_dir.rglob("SKILL.md")) if skills_dir.exists() else []:
        entries, _ = split_frontmatter(skill_md.read_text())
        for k, v in entries:
            if k == "name" and "arnold:" in v:
                _fail(errors, f"{skill_md.relative_to(REPO_ROOT)} name still contains 'arnold:' prefix: {v.strip()}")

    return errors


def validate_codex_skills() -> list[str]:
    """Validate dist/codex-skills/ (Phase 0 S0.4: .agents/skills/ path)."""
    errors: list[str] = []
    root = DIST / "codex-skills"
    if not root.exists():
        return [f"{root} does not exist — run `make codex` first"]

    skills_path = root / ".agents" / "skills"
    if not skills_path.exists():
        _fail(errors, ".agents/skills/ directory missing (Codex expects plural .agents/)")
        return errors
    # Every skill must start with arnold- prefix (namespace for Codex)
    for d in skills_path.iterdir():
        if d.is_dir() and not d.name.startswith("arnold-"):
            _fail(errors, f"skill directory {d.name} missing arnold- namespace prefix")
    if not (root / "AGENTS.md").exists():
        _fail(errors, "AGENTS.md missing from repo root")
    return errors


def validate_antigravity_skills() -> list[str]:
    """Validate dist/antigravity-skills/ (Phase 0 S0.3: .agent/skills/ SINGULAR)."""
    errors: list[str] = []
    root = DIST / "antigravity-skills"
    if not root.exists():
        return [f"{root} does not exist — run `make antigravity` first"]

    # Explicit trap check: .agents/ (plural) is Codex, NOT Antigravity
    if (root / ".agents").exists():
        _fail(errors, ".agents/ (plural) found — Antigravity uses .agent/ (singular). Build bug.")
    if not (root / ".agent" / "skills").exists():
        _fail(errors, ".agent/skills/ directory missing (Antigravity singular path)")
    return errors


def validate_all() -> bool:
    print("Validating build output against known schema constraints...")
    checks = [
        ("claude-plugin", validate_claude_plugin),
        ("cursor-plugin", validate_cursor_plugin),
        ("codex-plugin", validate_codex_plugin),
        ("codex-skills", validate_codex_skills),
        ("antigravity-skills", validate_antigravity_skills),
    ]
    all_ok = True
    for name, fn in checks:
        errs = fn()
        if errs:
            all_ok = False
            print(f"  ✗ {name}")
            for e in errs:
                print(f"      {e}")
        else:
            print(f"  ✓ {name}")
    return all_ok


# ─── Verification ─────────────────────────────────────────────────────


def dir_hash(path: Path) -> str:
    """Hash (file path, bytes) over the entire tree — for determinism checks."""
    h = hashlib.sha256()
    for p in sorted(path.rglob("*")):
        if p.is_file():
            rel = p.relative_to(path)
            h.update(str(rel).encode())
            h.update(b"\0")
            h.update(p.read_bytes())
            h.update(b"\0")
    return h.hexdigest()


def verify_deterministic() -> bool:
    """Build everything twice and compare hashes (FR-004)."""
    print("Verifying determinism: building twice, comparing hashes...")
    dist_dirs = ["claude-plugin", "cursor-plugin", "codex-plugin", "codex-skills", "antigravity-skills"]
    build_all()
    first_hashes = {t: dir_hash(DIST / t) for t in dist_dirs}
    build_all()
    second_hashes = {t: dir_hash(DIST / t) for t in dist_dirs}
    all_match = True
    for target, h1 in first_hashes.items():
        h2 = second_hashes[target]
        match = h1 == h2
        print(f"  {'✓' if match else '✗'} {target}: {h1[:12]} == {h2[:12] if match else h2[:12] + ' MISMATCH'}")
        if not match:
            all_match = False
    return all_match


# ─── Entry point ──────────────────────────────────────────────────────


TARGETS = {
    "claude": build_claude,
    "cursor": build_cursor,
    "codex-plugin": build_codex_plugin,
    "codex": build_codex,
    "antigravity": build_antigravity,
}


def build_all() -> None:
    for name, fn in TARGETS.items():
        fn()


def main() -> int:
    parser = argparse.ArgumentParser(description="Arnold multi-target build")
    parser.add_argument("target", choices=list(TARGETS.keys()) + ["all", "verify", "validate"], help="build target")
    args = parser.parse_args()

    if args.target == "verify":
        return 0 if verify_deterministic() else 1

    if args.target == "validate":
        return 0 if validate_all() else 1

    if args.target == "all":
        print("Building all targets...")
        build_all()
        for t in TARGETS:
            count = sum(1 for _ in (DIST / t_dir).rglob("*") if _.is_file()) if (t_dir := _resolve_dir(t)) else 0
            print(f"  ✓ dist/{t_dir}  ({count} files)")
    else:
        t_dir = _resolve_dir(args.target)
        print(f"Building {args.target} -> dist/{t_dir}/")
        TARGETS[args.target]()
        count = sum(1 for _ in (DIST / t_dir).rglob("*") if _.is_file())
        print(f"  ✓ dist/{t_dir}  ({count} files)")
    return 0


def _resolve_dir(target: str) -> str:
    return {
        "claude": "claude-plugin",
        "cursor": "cursor-plugin",
        "codex-plugin": "codex-plugin",
        "codex": "codex-skills",
        "antigravity": "antigravity-skills",
    }[target]


if __name__ == "__main__":
    sys.exit(main())

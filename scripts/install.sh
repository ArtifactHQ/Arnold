#!/usr/bin/env bash
# Arnold — manual install script.
#
# This is the non-agentic counterpart to INSTALL.md. It implements the same
# procedure with flags instead of tool-driven detection — faster for users who
# already know what they want. Any divergence between this script and
# INSTALL.md is a bug in one of them.
#
# Usage:
#   scripts/install.sh --tool=<TOOL> --target=<DIR> [--scope=<SCOPE>] [--uninstall]
#
# Supported tools (INSTALL.md Step 3 sections in parens):
#   claude-code   (3d, manual fallback — prefer the plugin marketplace)
#   cursor        (3e)
#   codex         (3a user-global, 3b project-scoped — default: user-global)
#   antigravity   (3c)
#   windsurf      (3f)
#   gemini-cli    (3f)
#
# Scopes (codex only):
#   project       Writes into <target>/.agents/skills/ (committed with the repo)
#   user-global   Writes into ~/.codex/plugins/arnold/ and registers in
#                 ~/.agents/plugins/marketplace.json. <target> is still used
#                 for the per-project AGENTS.md rules merge.
#
# Requirements:
#   - Run `make build` (or `make preflight`) first so dist/ exists. The script
#     fails fast if the relevant dist/<target>/ tree is missing.
#   - --target must be an existing directory.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

ARNOLD_START_MARKER="# ── Arnold Rules ──────────────────────────────"
ARNOLD_END_MARKER="# ── End Arnold Rules ──────────────────────────"

usage() {
    sed -n '/^# Usage/,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

ok()    { echo -e "${GREEN}✓${NC} $1"; }
warn()  { echo -e "${YELLOW}⚠${NC} $1"; }
err()   { echo -e "${RED}✗${NC} $1" >&2; }
info()  { echo -e "${CYAN}→${NC} $1"; }

# ── Args ──────────────────────────────────────
TOOL=""
TARGET=""
SCOPE=""
UNINSTALL=false
for arg in "$@"; do
    case "$arg" in
        --tool=*) TOOL="${arg#--tool=}" ;;
        --target=*) TARGET="${arg#--target=}" ;;
        --scope=*) SCOPE="${arg#--scope=}" ;;
        --uninstall|-u) UNINSTALL=true ;;
        --help|-h) usage 0 ;;
        *)
            err "Unknown argument: $arg"
            usage 1
            ;;
    esac
done

if [ -z "$TOOL" ] || [ -z "$TARGET" ]; then
    err "--tool and --target are both required"
    echo "  Example: $0 --tool=codex --target=/path/to/your-project" >&2
    exit 1
fi

case "$TOOL" in
    claude-code|cursor|codex|antigravity|windsurf|gemini-cli) ;;
    *)
        err "Unknown tool: $TOOL"
        echo "  Supported: claude-code, cursor, codex, antigravity, windsurf, gemini-cli" >&2
        exit 1
        ;;
esac

# Scope is codex-only; default to project.
if [ -n "$SCOPE" ] && [ "$TOOL" != "codex" ]; then
    err "--scope is only valid with --tool=codex"
    exit 1
fi
if [ "$TOOL" = "codex" ] && [ -z "$SCOPE" ]; then
    # Matches INSTALL.md line 55: "If the user says 'install Arnold,' default to
    # user-global for Codex." Pass --scope=project to vendor into a single repo.
    SCOPE="user-global"
fi
if [ "$TOOL" = "codex" ] && [ "$SCOPE" != "project" ] && [ "$SCOPE" != "user-global" ]; then
    err "--scope must be 'project' or 'user-global'"
    exit 1
fi

if [ ! -d "$TARGET" ]; then
    err "--target directory does not exist: $TARGET"
    exit 1
fi
TARGET="$(cd "$TARGET" && pwd)"  # canonicalize for clear reporting

# ── Rules-file marker helpers (INSTALL.md Step 4) ──────────────────

# Strip an existing Arnold marker block from the file, if present.
strip_arnold_block() {
    local file="$1"
    [ -f "$file" ] || return 0
    grep -qF "$ARNOLD_START_MARKER" "$file" 2>/dev/null || return 0
    awk -v start="$ARNOLD_START_MARKER" -v end="$ARNOLD_END_MARKER" \
        '$0 == start {skip=1} $0 == end {skip=0; next} !skip' "$file" > "${file}.tmp" \
        && mv "${file}.tmp" "$file"
}

# Merge rules content from $1 into rules file $2, always wrapping in markers.
# Idempotent: if Arnold block already exists, it is stripped and replaced.
merge_rules_file() {
    local src="$1"
    local dest="$2"
    [ -f "$src" ] || { warn "rules source missing: $src — skipping merge"; return 0; }

    if [ -f "$dest" ]; then
        if grep -qF "$ARNOLD_START_MARKER" "$dest" 2>/dev/null; then
            strip_arnold_block "$dest"
            local verb="Replaced Arnold rules in"
        else
            local verb="Appended Arnold rules to"
        fi
        printf '\n%s\n\n' "$ARNOLD_START_MARKER" >> "$dest"
        cat "$src" >> "$dest"
        printf '\n%s\n' "$ARNOLD_END_MARKER" >> "$dest"
        ok "${verb} $(basename "$dest")"
    else
        mkdir -p "$(dirname "$dest")"
        {
            echo "$ARNOLD_START_MARKER"
            echo ""
            cat "$src"
            echo ""
            echo "$ARNOLD_END_MARKER"
        } > "$dest"
        ok "Created $(basename "$dest")"
    fi
}

# Remove Arnold marker block from rules file; delete the file if it's now
# whitespace-only (implies the marker block was the entire content).
cleanup_rules_file() {
    local dest="$1"
    [ -f "$dest" ] || return 0
    grep -qF "$ARNOLD_START_MARKER" "$dest" 2>/dev/null || return 0
    strip_arnold_block "$dest"
    ok "Removed Arnold rules from $(basename "$dest")"
    if [ -z "$(tr -d '[:space:]' < "$dest")" ]; then
        rm -f "$dest"
        ok "Removed empty $(basename "$dest")"
    fi
}

# Remove directory if empty (silent on non-empty). Scoped to this directory
# only — each uninstall function calls this explicitly at every level it wants
# cleaned, so walking further would risk removing the user's $TARGET itself.
rmdir_if_empty() {
    local d="$1"
    [ -d "$d" ] || return 0
    if [ -z "$(ls -A "$d" 2>/dev/null)" ]; then
        rmdir "$d" 2>/dev/null || true
    fi
}

# Copy prefixed skill directories (arnold-*) from $1 into $2.
# Wipes any existing arnold-* destination dirs first so reinstall is clean.
copy_arnold_prefixed_skills() {
    local src_skills_dir="$1"
    local dest_skills_dir="$2"
    mkdir -p "$dest_skills_dir"
    local count=0
    for skill_dir in "$src_skills_dir"/arnold-*; do
        [ -d "$skill_dir" ] || continue
        local name dest
        name="$(basename "$skill_dir")"
        dest="${dest_skills_dir}/${name}"
        [ -e "$dest" ] && rm -rf "$dest"
        cp -R "$skill_dir" "$dest"
        count=$((count + 1))
    done
    ok "Installed ${count} skills to ${dest_skills_dir}/"
}

# Remove arnold-* subdirectories from a skills dir; clean up empty parents.
remove_arnold_prefixed_skills() {
    local dest_skills_dir="$1"
    [ -d "$dest_skills_dir" ] || return 0
    local removed=0
    for d in "$dest_skills_dir"/arnold-*; do
        [ -d "$d" ] || continue
        rm -rf "$d"
        removed=$((removed + 1))
    done
    [ "$removed" -gt 0 ] && ok "Removed ${removed} skill directories from ${dest_skills_dir}/"
    rmdir_if_empty "$dest_skills_dir"
}

# Copy short-named skills (dist/<tree>/skills/<n>/SKILL.md) into a flat dir
# as <n>.md. Used by claude-code (.claude/commands/arnold/) and cursor
# (.cursor/commands/) manual fallbacks.
copy_short_skills_flat() {
    local src_skills_dir="$1"
    local dest_dir="$2"
    mkdir -p "$dest_dir"
    local count=0
    for skill_dir in "$src_skills_dir"/*/; do
        [ -d "$skill_dir" ] || continue
        local name="$(basename "$skill_dir")"
        [ "$name" = "arnold-rules" ] && continue  # rules go to the rules file
        local src_file="${skill_dir}SKILL.md"
        [ -f "$src_file" ] || continue
        cp "$src_file" "${dest_dir}/${name}.md"
        count=$((count + 1))
    done
    ok "Installed ${count} commands to ${dest_dir}/"
}

# Remove individual command files from a flat dir (claude-code, cursor).
remove_short_skills_flat() {
    local dest_dir="$1"
    local src_skills_dir="$2"
    [ -d "$dest_dir" ] || return 0
    local removed=0
    for skill_dir in "$src_skills_dir"/*/; do
        [ -d "$skill_dir" ] || continue
        local name="$(basename "$skill_dir")"
        [ "$name" = "arnold-rules" ] && continue
        if [ -f "${dest_dir}/${name}.md" ]; then
            rm -f "${dest_dir}/${name}.md"
            removed=$((removed + 1))
        fi
    done
    [ "$removed" -gt 0 ] && ok "Removed ${removed} commands from ${dest_dir}/"
    rmdir_if_empty "$dest_dir"
}

# Pre-flight: ensure a given dist/ subtree exists before touching the user's system.
require_dist() {
    local dist_path="$1"
    if [ ! -d "$dist_path" ]; then
        err "${dist_path} does not exist"
        echo "  Run from the Arnold repo root: make build" >&2
        exit 1
    fi
}

# ── Per-tool install / uninstall ──────────────

install_claude_code() {
    local src_skills="${REPO_ROOT}/dist/claude-plugin/skills"
    require_dist "$src_skills"
    local dest_cmds="${TARGET}/.claude/commands/arnold"
    copy_short_skills_flat "$src_skills" "$dest_cmds"
    merge_rules_file "${REPO_ROOT}/CLAUDE.md" "${TARGET}/CLAUDE.md"
}

uninstall_claude_code() {
    local src_skills="${REPO_ROOT}/dist/claude-plugin/skills"
    [ -d "$src_skills" ] || src_skills="${REPO_ROOT}/skills"  # fall back to source tree for dir names
    remove_short_skills_flat "${TARGET}/.claude/commands/arnold" "$src_skills"
    cleanup_rules_file "${TARGET}/CLAUDE.md"
    rmdir_if_empty "${TARGET}/.claude/commands"
    rmdir_if_empty "${TARGET}/.claude"
}

install_cursor() {
    local src_root="${REPO_ROOT}/dist/cursor-plugin"
    require_dist "${src_root}/skills"
    copy_short_skills_flat "${src_root}/skills" "${TARGET}/.cursor/commands"
    local rules_src="${src_root}/rules/arnold-rules.mdc"
    if [ -f "$rules_src" ]; then
        mkdir -p "${TARGET}/.cursor/rules"
        cp "$rules_src" "${TARGET}/.cursor/rules/arnold-rules.mdc"
        ok "Installed rules/arnold-rules.mdc"
    fi
}

uninstall_cursor() {
    local src_skills="${REPO_ROOT}/dist/cursor-plugin/skills"
    [ -d "$src_skills" ] || src_skills="${REPO_ROOT}/skills"
    remove_short_skills_flat "${TARGET}/.cursor/commands" "$src_skills"
    if [ -f "${TARGET}/.cursor/rules/arnold-rules.mdc" ]; then
        rm -f "${TARGET}/.cursor/rules/arnold-rules.mdc"
        ok "Removed rules/arnold-rules.mdc"
    fi
    rmdir_if_empty "${TARGET}/.cursor/rules"
    rmdir_if_empty "${TARGET}/.cursor/commands"
    rmdir_if_empty "${TARGET}/.cursor"
}

install_codex_project() {
    local src_root="${REPO_ROOT}/dist/codex-skills"
    require_dist "${src_root}/.agents/skills"
    copy_arnold_prefixed_skills "${src_root}/.agents/skills" "${TARGET}/.agents/skills"
    merge_rules_file "${src_root}/AGENTS.md" "${TARGET}/AGENTS.md"
}

uninstall_codex_project() {
    remove_arnold_prefixed_skills "${TARGET}/.agents/skills"
    cleanup_rules_file "${TARGET}/AGENTS.md"
    rmdir_if_empty "${TARGET}/.agents"
}

# Codex user-global plugin (INSTALL.md 3a): copy the full tool tree into
# ~/.codex/plugins/arnold/, register in ~/.agents/plugins/marketplace.json,
# and merge AGENTS.md rules into the per-project <target>/AGENTS.md.
install_codex_user_global() {
    local src_root="${REPO_ROOT}/dist/codex-plugin"
    require_dist "$src_root"

    local home_plugins="${HOME}/.codex/plugins"
    local home_plugin_dir="${home_plugins}/arnold"
    mkdir -p "$home_plugins"
    [ -e "$home_plugin_dir" ] && rm -rf "$home_plugin_dir"
    cp -R "$src_root" "$home_plugin_dir"
    ok "Installed plugin to ${home_plugin_dir}/"

    # Register in ~/.agents/plugins/marketplace.json.
    local mp_dir="${HOME}/.agents/plugins"
    local mp="${mp_dir}/marketplace.json"
    mkdir -p "$mp_dir"
    if [ ! -f "$mp" ]; then
        cat > "$mp" <<'JSON'
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
JSON
        ok "Created ${mp}"
    else
        # Normalize the arnold entry: drop any existing one (may point at a
        # stale path from a prior install) and append the canonical shape.
        # This keeps the install deterministic regardless of the file's prior
        # state, and matches INSTALL.md Step 3a's third sub-bullet — which
        # only preserves an existing entry if it already points at
        # ./.codex/plugins/arnold.
        if ! command -v python3 >/dev/null 2>&1; then
            err "python3 required to merge ${mp} — correct the arnold entry manually"
            err "  See INSTALL.md Step 3a for the entry shape."
            return 1
        fi
        python3 - "$mp" <<'PY' || { err "failed to merge marketplace.json"; return 1; }
import json, sys, pathlib
p = pathlib.Path(sys.argv[1])
data = json.loads(p.read_text())
canonical = {
    "name": "arnold",
    "source": {"source": "local", "path": "./.codex/plugins/arnold"},
    "policy": {"installation": "AVAILABLE", "authentication": "ON_INSTALL"},
    "category": "Productivity",
}
plugins = [pl for pl in data.get("plugins", []) if pl.get("name") != "arnold"]
plugins.append(canonical)
data["plugins"] = plugins
p.write_text(json.dumps(data, indent=2) + "\n")
PY
        ok "Normalized arnold entry in ${mp}"
    fi

    # Per-project rules merge (INSTALL.md 3a step 4).
    if [ -f "${src_root}/AGENTS.md" ]; then
        merge_rules_file "${src_root}/AGENTS.md" "${TARGET}/AGENTS.md"
    fi
}

uninstall_codex_user_global() {
    local home_plugin_dir="${HOME}/.codex/plugins/arnold"
    if [ -d "$home_plugin_dir" ]; then
        rm -rf "$home_plugin_dir"
        ok "Removed ${home_plugin_dir}/"
    fi
    rmdir_if_empty "${HOME}/.codex/plugins"
    rmdir_if_empty "${HOME}/.codex"

    local mp="${HOME}/.agents/plugins/marketplace.json"
    if [ -f "$mp" ] && grep -q '"name"[[:space:]]*:[[:space:]]*"arnold"' "$mp"; then
        if command -v python3 >/dev/null 2>&1; then
            python3 - "$mp" <<'PY'
import json, sys, pathlib
p = pathlib.Path(sys.argv[1])
data = json.loads(p.read_text())
plugins = data.get("plugins", [])
data["plugins"] = [pl for pl in plugins if pl.get("name") != "arnold"]
p.write_text(json.dumps(data, indent=2) + "\n")
PY
            ok "Removed arnold entry from ${mp}"
        else
            warn "python3 missing — edit ${mp} manually to remove the arnold entry"
        fi
    fi

    cleanup_rules_file "${TARGET}/AGENTS.md"
}

install_antigravity() {
    local src_root="${REPO_ROOT}/dist/antigravity-skills"
    require_dist "${src_root}/.agent/skills"
    copy_arnold_prefixed_skills "${src_root}/.agent/skills" "${TARGET}/.agent/skills"
    # Antigravity has no rules-file equivalent (INSTALL.md 3c).
}

uninstall_antigravity() {
    remove_arnold_prefixed_skills "${TARGET}/.agent/skills"
    rmdir_if_empty "${TARGET}/.agent"
}

install_windsurf() {
    local src_root="${REPO_ROOT}/dist/codex-skills"
    require_dist "${src_root}/.agents/skills"
    copy_arnold_prefixed_skills "${src_root}/.agents/skills" "${TARGET}/.windsurf/workflows"
    merge_rules_file "${src_root}/AGENTS.md" "${TARGET}/.windsurfrules"
}

uninstall_windsurf() {
    remove_arnold_prefixed_skills "${TARGET}/.windsurf/workflows"
    cleanup_rules_file "${TARGET}/.windsurfrules"
    rmdir_if_empty "${TARGET}/.windsurf"
}

install_gemini_cli() {
    local src_root="${REPO_ROOT}/dist/codex-skills"
    require_dist "${src_root}/.agents/skills"
    copy_arnold_prefixed_skills "${src_root}/.agents/skills" "${TARGET}/.gemini/commands"
    merge_rules_file "${src_root}/AGENTS.md" "${TARGET}/GEMINI.md"
}

uninstall_gemini_cli() {
    remove_arnold_prefixed_skills "${TARGET}/.gemini/commands"
    cleanup_rules_file "${TARGET}/GEMINI.md"
    rmdir_if_empty "${TARGET}/.gemini"
}

# ── Dispatch ──────────────────────────────────

describe_destination() {
    case "$TOOL" in
        claude-code) echo "${TARGET}/.claude/commands/arnold/ (manual fallback — prefer the plugin marketplace)" ;;
        cursor)      echo "${TARGET}/.cursor/commands/" ;;
        codex)
            if [ "$SCOPE" = "user-global" ]; then
                echo "${HOME}/.codex/plugins/arnold/ + ${TARGET}/AGENTS.md"
            else
                echo "${TARGET}/.agents/skills/ + ${TARGET}/AGENTS.md"
            fi
            ;;
        antigravity) echo "${TARGET}/.agent/skills/" ;;
        windsurf)    echo "${TARGET}/.windsurf/workflows/ + ${TARGET}/.windsurfrules" ;;
        gemini-cli)  echo "${TARGET}/.gemini/commands/ + ${TARGET}/GEMINI.md" ;;
    esac
}

next_steps() {
    echo ""
    echo "  Next steps:"
    case "$TOOL" in
        claude-code)
            echo "    1. Open ${TARGET} in Claude Code"
            echo "    2. Commands are available at /arnold:<name>"
            ;;
        cursor)
            echo "    1. Open ${TARGET} in Cursor"
            echo "    2. Commands are available at /arnold-<name> (kebab-case)"
            ;;
        codex)
            if [ "$SCOPE" = "user-global" ]; then
                echo "    1. Restart Codex"
                echo "    2. Settings → Plugins → enable Arnold"
                echo "    3. Commands are available at /arnold:<name>"
            else
                echo "    1. Open ${TARGET} in Codex (CLI, IDE extension, or app)"
                echo "    2. Skills auto-discovered from .agents/skills/"
            fi
            ;;
        antigravity)
            echo "    1. Open ${TARGET} in Antigravity"
            echo "    2. Skills auto-discovered from .agent/skills/ (singular — not .agents/)"
            ;;
        windsurf)
            echo "    1. Open ${TARGET} in Windsurf"
            echo "    2. Workflows are available from .windsurf/workflows/"
            ;;
        gemini-cli)
            echo "    1. Open ${TARGET} with Gemini CLI"
            echo "    2. Commands are available from .gemini/commands/"
            ;;
    esac
    echo ""
    local scope_flag=""
    [ "$TOOL" = "codex" ] && scope_flag=" --scope=${SCOPE}"
    echo "  Uninstall:  $0 --tool=${TOOL}${scope_flag} --target=${TARGET} --uninstall"
    echo ""
}

if [ "$UNINSTALL" = true ]; then
    echo -e "${BOLD}Uninstalling Arnold (${TOOL}${SCOPE:+/$SCOPE}) from ${TARGET}${NC}"
    case "$TOOL" in
        claude-code)  uninstall_claude_code ;;
        cursor)       uninstall_cursor ;;
        codex)
            if [ "$SCOPE" = "user-global" ]; then uninstall_codex_user_global; else uninstall_codex_project; fi ;;
        antigravity)  uninstall_antigravity ;;
        windsurf)     uninstall_windsurf ;;
        gemini-cli)   uninstall_gemini_cli ;;
    esac
    echo ""
    echo "  Your docs/ folder was not touched."
    exit 0
fi

echo -e "${BOLD}Installing Arnold (${TOOL}${SCOPE:+/$SCOPE}) into $(describe_destination)${NC}"
echo ""

case "$TOOL" in
    claude-code)  install_claude_code ;;
    cursor)       install_cursor ;;
    codex)
        if [ "$SCOPE" = "user-global" ]; then install_codex_user_global; else install_codex_project; fi ;;
    antigravity)  install_antigravity ;;
    windsurf)     install_windsurf ;;
    gemini-cli)   install_gemini_cli ;;
esac

next_steps

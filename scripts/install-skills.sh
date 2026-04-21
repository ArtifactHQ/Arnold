#!/usr/bin/env bash
# Arnold — user-facing install for tools without a plugin marketplace (Codex, Antigravity).
#
# Usage (run from an Arnold clone):
#   scripts/install-skills.sh --tool=codex        --target=/path/to/your-project
#   scripts/install-skills.sh --tool=antigravity  --target=/path/to/your-project
#   scripts/install-skills.sh --tool=codex        --target=/path/to/your-project --uninstall
#
# What it does:
#   codex        -> copies dist/codex-skills/.agents/skills/arnold-*/ into <target>/.agents/skills/
#                   copies dist/codex-skills/AGENTS.md into <target>/AGENTS.md (or merges marker block
#                   if AGENTS.md already exists)
#   antigravity  -> copies dist/antigravity-skills/.agent/skills/arnold-*/ into <target>/.agent/skills/
#
# Requirements:
#   - Run `make build` (or `make preflight`) first so dist/ exists
#   - Target must be an existing directory
#
# For Claude Code and Cursor, install from their plugin marketplaces — see the README.

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

# ── Args ──────────────────────────────────────
TOOL=""
TARGET=""
UNINSTALL=false
for arg in "$@"; do
    case "$arg" in
        --tool=*) TOOL="${arg#--tool=}" ;;
        --target=*) TARGET="${arg#--target=}" ;;
        --uninstall|-u) UNINSTALL=true ;;
        --help|-h)
            sed -n '/^# Usage/,/^# For Claude/p' "${BASH_SOURCE[0]}" | sed 's/^# //;s/^#//'
            exit 0
            ;;
        *)
            echo -e "${RED}✗${NC} Unknown argument: $arg"
            exit 1
            ;;
    esac
done

if [ -z "$TOOL" ] || [ -z "$TARGET" ]; then
    echo -e "${RED}✗${NC} --tool and --target are both required"
    echo "  Example: $0 --tool=codex --target=/path/to/your-project"
    exit 1
fi

case "$TOOL" in
    codex|antigravity) ;;
    claude-code|cursor)
        echo -e "${YELLOW}⚠${NC} ${TOOL} is available via its plugin marketplace, not this script."
        echo "  See the README for marketplace install instructions."
        exit 1
        ;;
    *)
        echo -e "${RED}✗${NC} Unknown tool: $TOOL (supported: codex, antigravity)"
        exit 1
        ;;
esac

if [ ! -d "$TARGET" ]; then
    echo -e "${RED}✗${NC} --target directory does not exist: $TARGET"
    exit 1
fi

# ── Per-tool paths ────────────────────────────
case "$TOOL" in
    codex)
        DIST_SUBTREE="${REPO_ROOT}/dist/codex-skills/.agents/skills"
        DIST_RULES="${REPO_ROOT}/dist/codex-skills/AGENTS.md"
        TARGET_SKILLS_DIR="${TARGET}/.agents/skills"
        TARGET_RULES_FILE="${TARGET}/AGENTS.md"
        RULES_LABEL="AGENTS.md"
        ;;
    antigravity)
        DIST_SUBTREE="${REPO_ROOT}/dist/antigravity-skills/.agent/skills"
        DIST_RULES=""
        TARGET_SKILLS_DIR="${TARGET}/.agent/skills"
        TARGET_RULES_FILE=""
        RULES_LABEL=""
        ;;
esac

# ── Uninstall ─────────────────────────────────
if [ "$UNINSTALL" = true ]; then
    echo -e "${BOLD}Uninstalling Arnold skills for ${TOOL} from ${TARGET}${NC}"
    removed_any=false
    if [ -d "${TARGET_SKILLS_DIR}" ]; then
        for d in "${TARGET_SKILLS_DIR}"/arnold-*; do
            [ -d "$d" ] || continue
            rm -rf "$d"
            echo -e "${GREEN}✓${NC} Removed $(basename "$d")"
            removed_any=true
        done
        # Remove empty parent dirs we created (but not if user had other things in them)
        if [ -z "$(ls -A "${TARGET_SKILLS_DIR}" 2>/dev/null)" ]; then
            rmdir "${TARGET_SKILLS_DIR}" 2>/dev/null || true
            parent_dir="$(dirname "${TARGET_SKILLS_DIR}")"
            [ -z "$(ls -A "${parent_dir}" 2>/dev/null)" ] && rmdir "${parent_dir}" 2>/dev/null || true
        fi
    fi
    # Strip marker block from rules file if present
    if [ -n "${TARGET_RULES_FILE}" ] && [ -f "${TARGET_RULES_FILE}" ]; then
        if grep -qF "$ARNOLD_START_MARKER" "${TARGET_RULES_FILE}" 2>/dev/null; then
            awk -v start="$ARNOLD_START_MARKER" -v end="$ARNOLD_END_MARKER" \
                '$0 == start {skip=1} $0 == end {skip=0; next} !skip' "${TARGET_RULES_FILE}" > "${TARGET_RULES_FILE}.tmp" \
                && mv "${TARGET_RULES_FILE}.tmp" "${TARGET_RULES_FILE}"
            echo -e "${GREEN}✓${NC} Removed Arnold rules from ${RULES_LABEL}"
            # Remove the file entirely if it's now empty (we created it)
            if [ -z "$(tr -d '[:space:]' < "${TARGET_RULES_FILE}")" ]; then
                rm "${TARGET_RULES_FILE}"
                echo -e "${GREEN}✓${NC} Removed empty ${RULES_LABEL}"
            fi
            removed_any=true
        fi
    fi
    if [ "$removed_any" = false ]; then
        echo -e "${CYAN}→${NC} Nothing to uninstall"
    fi
    echo ""
    echo "  Your docs/ folder was not touched."
    exit 0
fi

# ── Install ───────────────────────────────────

# Preflight: ensure dist/ exists
if [ ! -d "${DIST_SUBTREE}" ]; then
    echo -e "${RED}✗${NC} ${DIST_SUBTREE} does not exist"
    echo "  Run from Arnold repo root: make build"
    exit 1
fi

echo -e "${BOLD}Installing Arnold skills for ${TOOL} into ${TARGET}${NC}"
echo ""

# Copy skills
mkdir -p "${TARGET_SKILLS_DIR}"
count=0
for skill_dir in "${DIST_SUBTREE}"/arnold-*; do
    [ -d "$skill_dir" ] || continue
    name="$(basename "$skill_dir")"
    dest="${TARGET_SKILLS_DIR}/${name}"
    if [ -e "${dest}" ]; then
        rm -rf "${dest}"
    fi
    cp -R "${skill_dir}" "${dest}"
    count=$((count + 1))
done
echo -e "${GREEN}✓${NC} Installed ${count} skills to ${TARGET_SKILLS_DIR}/"

# Copy / merge rules file (Codex only).
# Always wrap in markers so uninstall can reliably strip, whether we created
# the file fresh or appended to an existing one.
if [ -n "${DIST_RULES}" ] && [ -f "${DIST_RULES}" ]; then
    if [ -f "${TARGET_RULES_FILE}" ]; then
        if grep -qF "$ARNOLD_START_MARKER" "${TARGET_RULES_FILE}" 2>/dev/null; then
            # Existing Arnold block — strip it, then append fresh
            awk -v start="$ARNOLD_START_MARKER" -v end="$ARNOLD_END_MARKER" \
                '$0 == start {skip=1} $0 == end {skip=0; next} !skip' "${TARGET_RULES_FILE}" > "${TARGET_RULES_FILE}.tmp" \
                && mv "${TARGET_RULES_FILE}.tmp" "${TARGET_RULES_FILE}"
            merge_verb="Replaced Arnold rules in"
        else
            merge_verb="Appended Arnold rules to"
        fi
        printf '\n%s\n\n' "$ARNOLD_START_MARKER" >> "${TARGET_RULES_FILE}"
        cat "${DIST_RULES}" >> "${TARGET_RULES_FILE}"
        printf '\n%s\n' "$ARNOLD_END_MARKER" >> "${TARGET_RULES_FILE}"
        echo -e "${GREEN}✓${NC} ${merge_verb} ${RULES_LABEL}"
    else
        # Create fresh. Still wrap in markers so uninstall treats it uniformly.
        {
            echo "$ARNOLD_START_MARKER"
            echo ""
            cat "${DIST_RULES}"
            echo ""
            echo "$ARNOLD_END_MARKER"
        } > "${TARGET_RULES_FILE}"
        echo -e "${GREEN}✓${NC} Created ${RULES_LABEL}"
    fi
fi

echo ""
echo "  Next steps:"
case "$TOOL" in
    codex)
        echo "    1. Open ${TARGET} in Codex (CLI, IDE extension, or app)"
        echo "    2. Skills auto-discovered from .agents/skills/"
        echo "    3. AGENTS.md rules are read at session start"
        echo ""
        echo "  Uninstall:  $0 --tool=codex --target=${TARGET} --uninstall"
        ;;
    antigravity)
        echo "    1. Open ${TARGET} in Antigravity"
        echo "    2. Skills auto-discovered from .agent/skills/ (singular — not .agents/)"
        echo ""
        echo "  Uninstall:  $0 --tool=antigravity --target=${TARGET} --uninstall"
        ;;
esac
echo ""

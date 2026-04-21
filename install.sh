#!/usr/bin/env bash
set -euo pipefail

# ══════════════════════════════════════════════
# Arnold — Install Script
# ══════════════════════════════════════════════
# Copies Arnold slash commands and CLAUDE.md
# into the current project directory.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/ArtifactHQ/arnold/main/install.sh | bash
#
# Uninstall:
#   curl -fsSL https://raw.githubusercontent.com/ArtifactHQ/arnold/main/install.sh | bash -s -- --uninstall
#
# Or run from a cloned repo:
#   ./install.sh
#   ./install.sh --uninstall
# ══════════════════════════════════════════════

readonly ARNOLD_VERSION="0.4.0"
readonly ARNOLD_REPO="ArtifactHQ/arnold"
readonly ARNOLD_BRANCH="main"
readonly ARNOLD_RAW_BASE="https://raw.githubusercontent.com/${ARNOLD_REPO}/${ARNOLD_BRANCH}"

# Master command list (single source of truth — used by install, verify, and uninstall)
readonly ARNOLD_COMMAND_NAMES=("init" "plan" "check" "update" "status" "help" "decide" "resolve" "recap" "diff" "spec" "bug" "archive" "milestone" "feature" "build" "review")

# Markers used to delimit Arnold content in CLAUDE.md
readonly ARNOLD_START_MARKER="# ── Arnold Rules ──────────────────────────────"
readonly ARNOLD_END_MARKER="# ── End Arnold Rules ──────────────────────────"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

print_banner() {
    echo ""
    echo -e "${GREEN}🦕 Arnold v${ARNOLD_VERSION}${NC}"
    echo -e "${GREEN}   Hold on to your docs.${NC}"
    echo ""
}

# Deprecation banner (FR-041): prints at runtime, does not block.
# Native installs are preferred as of v0.5.0; this script is removed in v1.0.
print_deprecation_banner() {
    echo -e "${YELLOW}⚠  This shell installer is deprecated as of Arnold v0.5.0.${NC}"
    echo -e "${YELLOW}   Native installs are available for Claude Code, Cursor, Codex, Antigravity, Windsurf, and Gemini CLI.${NC}"
    echo -e "${YELLOW}   See: https://github.com/${ARNOLD_REPO}#install${NC}"
    echo -e "${YELLOW}   This script will be removed in v1.0.${NC}"
    echo ""
    echo -e "${CYAN}   For Claude Code — prefer:${NC}"
    echo "     /plugin marketplace add ${ARNOLD_REPO}"
    echo "     /plugin install arnold@arnold-marketplace"
    echo ""
    echo -e "${CYAN}   For other tools — ask your agent (reads INSTALL.md), or from a clone:${NC}"
    echo "     scripts/install.sh --tool=<claude-code|cursor|codex|antigravity|windsurf|gemini-cli> --target=."
    echo ""
    echo "   Continuing with shell install in 3 seconds... (Ctrl-C to cancel)"
    echo ""
    # Short, skippable delay so interactive users can abort; non-interactive runs
    # (CI, curl | bash) pass through.
    sleep 3 2>/dev/null || true
}

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

print_info() {
    echo -e "${CYAN}→${NC} $1"
}

# Temp directory (unique, unpredictable — avoids symlink attacks on shared systems)
ARNOLD_TMPDIR=""

# Cleanup temp files on exit (success or failure)
cleanup() {
    if [ -n "$ARNOLD_TMPDIR" ] && [ -d "$ARNOLD_TMPDIR" ] && [ ! -L "$ARNOLD_TMPDIR" ]; then
        rm -rf "$ARNOLD_TMPDIR"
    fi
}
trap cleanup EXIT

# ── Functions ─────────────────────────────────

run_verify() {
    echo "Verifying Arnold installation..."
    local verify_ok=true
    for cmd in "${ARNOLD_COMMAND_NAMES[@]}"; do
        if [ -f ".claude/commands/arnold/${cmd}.md" ]; then
            if grep -q "arnold:" ".claude/commands/arnold/${cmd}.md" 2>/dev/null; then
                echo "  ✓ /arnold:${cmd}"
            else
                echo "  ✗ /arnold:${cmd} — file exists but appears corrupted"
                verify_ok=false
            fi
        else
            echo "  ✗ /arnold:${cmd} — not found"
            verify_ok=false
        fi
    done
    # Check CLAUDE.md
    if grep -q "Arnold Rules" "./CLAUDE.md" 2>/dev/null || grep -q "Arnold Rules" ".claude/CLAUDE.md" 2>/dev/null; then
        echo "  ✓ CLAUDE.md rules"
    else
        echo "  ✗ CLAUDE.md rules — not found"
        verify_ok=false
    fi
    echo ""
    if [ "$verify_ok" = true ]; then
        echo "Arnold v${ARNOLD_VERSION} is installed correctly."
    else
        echo "Arnold installation is incomplete. Re-run the install command."
    fi
}

# Write Arnold rules into a CLAUDE.md file with start/end markers
write_arnold_rules() {
    local target="$1"
    local mode="$2" # "append" or "create"
    if [ "$mode" = "create" ]; then
        echo "$ARNOLD_START_MARKER" > "$target"
    else
        echo "" >> "$target"
        echo "$ARNOLD_START_MARKER" >> "$target"
    fi
    echo "" >> "$target"
    cat "${CLAUDE_MD_SOURCE}" >> "$target"
    echo "" >> "$target"
    echo "$ARNOLD_END_MARKER" >> "$target"
}

# Remove Arnold rules from a CLAUDE.md file using exact string matching
remove_arnold_rules() {
    local target="$1"
    awk -v start="$ARNOLD_START_MARKER" -v end="$ARNOLD_END_MARKER" \
        '$0 == start {skip=1} $0 == end {skip=0; next} !skip' "$target" > "${target}.tmp" \
        && mv "${target}.tmp" "$target"
}

# ── Parse Arguments ───────────────────────────

print_help() {
    cat <<EOF
Arnold legacy shell installer (deprecated — prefer the plugin marketplace or
scripts/install.sh; see https://github.com/${ARNOLD_REPO}#install).

Usage:
  curl -fsSL https://raw.githubusercontent.com/${ARNOLD_REPO}/${ARNOLD_BRANCH}/install.sh | bash
  ./install.sh                    Install Arnold into the current project (.claude/commands/arnold/)
  ./install.sh --uninstall, -u    Remove Arnold from the current project
  ./install.sh --verify           Verify an existing install's command files
  ./install.sh --version, -v      Print the Arnold version shipped by this script
  ./install.sh --help, -h         Show this help and exit
EOF
}

UNINSTALL=false
for arg in "$@"; do
    case "$arg" in
        --uninstall|-u)
            UNINSTALL=true
            ;;
        --version|-v)
            echo "Arnold v${ARNOLD_VERSION}"
            exit 0
            ;;
        --verify)
            run_verify
            exit 0
            ;;
        --help|-h)
            print_help
            exit 0
            ;;
    esac
done

# ── Uninstall ─────────────────────────────────

if [ "$UNINSTALL" = true ]; then
    print_banner
    # Uninstall path skips the deprecation banner — user is leaving this path anyway.
    echo -e "${YELLOW}Uninstalling Arnold...${NC}"
    echo ""

    # Remove command files
    if [ -d ".claude/commands/arnold" ]; then
        # Remove only Arnold's known files (preserve user-added files)
        for cmd in "${ARNOLD_COMMAND_NAMES[@]}"; do
            rm -f ".claude/commands/arnold/${cmd}.md"
        done
        rm -f .claude/commands/arnold/.version

        # Check for remaining user-added files
        EXTRA_FILES=()
        for f in .claude/commands/arnold/*; do
            [ -e "$f" ] || continue
            EXTRA_FILES+=("$(basename "$f")")
        done

        if [ "${#EXTRA_FILES[@]}" -gt 0 ]; then
            print_warning "User-added files remain in .claude/commands/arnold/:"
            for ef in "${EXTRA_FILES[@]}"; do
                echo "    - $ef"
            done
            print_info "These were not created by Arnold and have been preserved."
        else
            rmdir .claude/commands/arnold 2>/dev/null || true
        fi
        print_success "Removed Arnold commands"

        if [ -f "${HOME}/.claude/settings.json" ] && grep -q "arnold" "${HOME}/.claude/settings.json" 2>/dev/null; then
            print_warning "Arnold may also be installed as a Claude Code plugin."
            print_info "To fully remove: /plugin uninstall arnold@arnold-marketplace"
        fi
    else
        print_info "No Arnold commands found"
    fi

    # Remove Arnold rules from CLAUDE.md (check both locations)
    for claude_md in "./CLAUDE.md" ".claude/CLAUDE.md"; do
        if [ -f "$claude_md" ] && grep -q "$ARNOLD_START_MARKER" "$claude_md" 2>/dev/null; then
            if grep -q "$ARNOLD_END_MARKER" "$claude_md" 2>/dev/null; then
                remove_arnold_rules "$claude_md"
                print_success "Removed Arnold rules from $claude_md"
            else
                print_warning "Found Arnold start marker in $claude_md but no end marker — please remove Arnold rules manually"
            fi
        fi
    done

    # If .claude/CLAUDE.md is now empty (only whitespace), remove it
    if [ -f ".claude/CLAUDE.md" ]; then
        if [ -z "$(tr -d '[:space:]' < ".claude/CLAUDE.md")" ]; then
            rm -f ".claude/CLAUDE.md"
            print_success "Removed empty .claude/CLAUDE.md"
        fi
    fi

    # Clean up empty directories
    if [ -d ".claude/commands" ] && [ -z "$(ls -A .claude/commands 2>/dev/null)" ]; then
        rmdir .claude/commands 2>/dev/null || true
    fi
    if [ -d ".claude" ] && [ -z "$(ls -A .claude 2>/dev/null)" ]; then
        rmdir .claude 2>/dev/null || true
        print_success "Removed empty .claude/"
    fi

    echo ""
    echo -e "${GREEN}Arnold has been uninstalled.${NC}"
    echo "  Your docs/ folder was not touched — your documentation is still there."
    echo ""
    exit 0
fi

# ── Main Install ──────────────────────────────

print_banner
print_deprecation_banner

# Check if we're in a project directory
if [ ! -d ".git" ] && [ ! -f "package.json" ] && [ ! -f "requirements.txt" ] && [ ! -f "Cargo.toml" ] && [ ! -f "go.mod" ] && [ ! -f "Makefile" ]; then
    print_warning "This doesn't look like a project directory."
    echo "  Arnold works best when installed in a project root."
    echo ""
    # Handle both interactive and piped (curl | bash) usage
    if [ -t 0 ]; then
        read -p "  Install here anyway? (y/N) " -n 1 -r || true
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "  No worries. cd into your project and try again."
            exit 0
        fi
    else
        print_info "Running in non-interactive mode — installing anyway"
    fi
fi

# Check for existing plugin installation
PLUGIN_DETECTED=false
if [ -f "${HOME}/.claude/settings.json" ] && grep -q "arnold" "${HOME}/.claude/settings.json" 2>/dev/null; then
    PLUGIN_DETECTED=true
elif [ -d "${HOME}/.claude/plugins/cache" ] && ls "${HOME}/.claude/plugins/cache/" 2>/dev/null | grep -qi "arnold"; then
    PLUGIN_DETECTED=true
fi

if [ "$PLUGIN_DETECTED" = true ]; then
    print_warning "Arnold appears to be installed as a Claude Code plugin."
    print_info "Using both the plugin and shell install may cause duplicate commands."
    print_info "If you're using Claude Code, the plugin is recommended: /plugin install arnold"
    echo ""
    if [ -t 0 ]; then
        read -p "  Continue with shell install anyway? (y/N) " -n 1 -r || true
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "  Install cancelled."
            exit 0
        fi
    else
        print_warning "Running in non-interactive mode — continuing with install"
    fi
fi

# Create .claude/commands/arnold/ directory (namespace for Arnold commands)
if [ -d ".claude/commands/arnold" ]; then
    if [ -f ".claude/commands/arnold/.version" ]; then
        OLD_VERSION=$(cat .claude/commands/arnold/.version)
        if [ "$OLD_VERSION" = "$ARNOLD_VERSION" ]; then
            print_info "Reinstalling Arnold v${ARNOLD_VERSION}..."
        else
            print_info "Upgrading Arnold v${OLD_VERSION} → v${ARNOLD_VERSION}"
        fi
    else
        print_info "Updating existing Arnold commands..."
    fi
else
    mkdir -p .claude/commands/arnold
    print_success "Created .claude/commands/arnold/"
fi

# Download command files
print_info "Downloading Arnold commands..."

# Create unique temp directory (avoids symlink attacks on shared systems)
ARNOLD_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/arnold-install.XXXXXXXXXX")"

# Check if we're running from a cloned repo (verify it's actually Arnold's source).
# When piped via stdin (curl | bash), BASH_SOURCE[0] is unset — never use local path.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
IS_LOCAL_INSTALL=false
if [ "${BASH_SOURCE[0]:-}" != "" ] && [ -d "${SCRIPT_DIR}/commands/arnold" ] && [ -f "${SCRIPT_DIR}/commands/arnold/init.md" ] && grep -q "arnold:init" "${SCRIPT_DIR}/commands/arnold/init.md" 2>/dev/null; then
    # Local install from cloned repo
    IS_LOCAL_INSTALL=true
    LOCAL_FAILURES=0
    for cmd in "${ARNOLD_COMMAND_NAMES[@]}"; do
        if [ -f "${SCRIPT_DIR}/commands/arnold/${cmd}.md" ] && grep -q "^---" "${SCRIPT_DIR}/commands/arnold/${cmd}.md" 2>/dev/null; then
            cp "${SCRIPT_DIR}/commands/arnold/${cmd}.md" ".claude/commands/arnold/${cmd}.md"
            print_success "  /arnold:${cmd}"
        else
            print_error "  /arnold:${cmd} — file missing or invalid in ${SCRIPT_DIR}/commands/arnold/"
            LOCAL_FAILURES=$((LOCAL_FAILURES + 1))
        fi
    done

    if [ "${LOCAL_FAILURES}" -gt 0 ]; then
        echo ""
        print_error "Some commands were missing or invalid. Please check your local repo."
        exit 1
    fi
else
    # Remote install from GitHub
    DOWNLOAD_FAILURES=0
    for cmd in "${ARNOLD_COMMAND_NAMES[@]}"; do
        if curl --proto '=https' --tlsv1.2 -fsSL "${ARNOLD_RAW_BASE}/commands/arnold/${cmd}.md" -o "${ARNOLD_TMPDIR}/${cmd}.md" 2>/dev/null && [ -s "${ARNOLD_TMPDIR}/${cmd}.md" ] && grep -q "^---" "${ARNOLD_TMPDIR}/${cmd}.md" 2>/dev/null; then
            cp "${ARNOLD_TMPDIR}/${cmd}.md" ".claude/commands/arnold/${cmd}.md"
            print_success "  /arnold:${cmd}"
        else
            print_error "  /arnold:${cmd} — failed to download"
            DOWNLOAD_FAILURES=$((DOWNLOAD_FAILURES + 1))
        fi
    done

    if [ "${DOWNLOAD_FAILURES}" -gt 0 ]; then
        echo ""
        print_error "Some commands failed to download. Please check your network connection and try again."
        # Clean up partial install so re-run starts fresh
        rm -rf .claude/commands/arnold
        print_info "Cleaned up partial install. Check your network and try again."
        exit 1
    fi
fi

# Write version file
echo "${ARNOLD_VERSION}" > .claude/commands/arnold/.version

# Handle CLAUDE.md
CLAUDE_MD_SOURCE=""
if [ "$IS_LOCAL_INSTALL" = true ] && [ -f "${SCRIPT_DIR}/CLAUDE.md" ]; then
    CLAUDE_MD_SOURCE="${SCRIPT_DIR}/CLAUDE.md"
else
    if curl --proto '=https' --tlsv1.2 -fsSL "${ARNOLD_RAW_BASE}/CLAUDE.md" -o "${ARNOLD_TMPDIR}/CLAUDE.md" 2>/dev/null && [ -s "${ARNOLD_TMPDIR}/CLAUDE.md" ]; then
        CLAUDE_MD_SOURCE="${ARNOLD_TMPDIR}/CLAUDE.md"
    fi
fi

if [ -n "${CLAUDE_MD_SOURCE}" ]; then
    # Find target CLAUDE.md (prefer project root, then .claude/)
    TARGET_CLAUDE_MD=""
    if [ -f "./CLAUDE.md" ]; then
        TARGET_CLAUDE_MD="./CLAUDE.md"
    elif [ -f ".claude/CLAUDE.md" ]; then
        TARGET_CLAUDE_MD=".claude/CLAUDE.md"
    fi

    if [ -n "${TARGET_CLAUDE_MD}" ]; then
        # Guard: if source and target resolve to the same file (e.g. running
        # ./install.sh from inside the Arnold repo), redirect to .claude/CLAUDE.md
        SOURCE_REAL="$(cd "$(dirname "${CLAUDE_MD_SOURCE}")" && pwd)/$(basename "${CLAUDE_MD_SOURCE}")"
        TARGET_REAL="$(cd "$(dirname "${TARGET_CLAUDE_MD}")" && pwd)/$(basename "${TARGET_CLAUDE_MD}")"
        if [ "$SOURCE_REAL" = "$TARGET_REAL" ]; then
            print_warning "Source CLAUDE.md is the same as target — redirecting to .claude/CLAUDE.md"
            mkdir -p .claude
            TARGET_CLAUDE_MD=".claude/CLAUDE.md"
        fi

        # Guard: refuse to modify files over 1 MB (likely corrupted)
        TARGET_SIZE=$(wc -c < "$TARGET_CLAUDE_MD" 2>/dev/null || echo 0)
        if [ "$TARGET_SIZE" -gt 1048576 ]; then
            print_error "$TARGET_CLAUDE_MD is $(( TARGET_SIZE / 1048576 ))MB — refusing to modify (file may be corrupted)"
            exit 1
        fi

        # Check if Arnold rules are already present (use our specific marker, not just "Arnold")
        if grep -q "$ARNOLD_START_MARKER" "$TARGET_CLAUDE_MD" 2>/dev/null; then
            # Replace existing Arnold rules (update in place)
            if grep -q "$ARNOLD_END_MARKER" "$TARGET_CLAUDE_MD" 2>/dev/null; then
                remove_arnold_rules "$TARGET_CLAUDE_MD"
            else
                print_warning "Arnold start marker found in $TARGET_CLAUDE_MD but end marker is missing."
                print_warning "Please remove the old Arnold rules manually, then re-run install."
                exit 1
            fi
            write_arnold_rules "$TARGET_CLAUDE_MD" "append"
            print_success "Updated Arnold rules in $TARGET_CLAUDE_MD"
        else
            write_arnold_rules "$TARGET_CLAUDE_MD" "append"
            print_success "Appended Arnold rules to $TARGET_CLAUDE_MD"
        fi
    else
        # No existing CLAUDE.md — create new one with markers
        mkdir -p .claude
        write_arnold_rules ".claude/CLAUDE.md" "create"
        print_success "Created .claude/CLAUDE.md"
    fi
else
    print_warning "Could not find CLAUDE.md template — you may need to create it manually"
fi

# Done
echo ""
echo -e "${GREEN}${BOLD}Arnold v${ARNOLD_VERSION} is installed.${NC}"
echo ""
echo "  Next steps:"
echo "    1. Open Claude Code in this project"
echo "    2. Run /arnold:init      — scaffold docs from your project"
echo "    3. Run /arnold:plan      — flesh out feature specs"
echo "    4. Build your code"
echo "    5. Run /arnold:check     — compare docs to code, find drift"
echo "    6. Run /arnold:update    — sync docs after code changes"
echo ""
echo "    Run /arnold:help anytime for the full command reference."
echo ""
echo "  To uninstall:"
echo "    curl -fsSL https://raw.githubusercontent.com/${ARNOLD_REPO}/${ARNOLD_BRANCH}/install.sh | bash -s -- --uninstall"
echo ""
echo -e "  ${CYAN}Hold on to your docs.${NC} 🦕"
echo ""

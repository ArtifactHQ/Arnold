#!/usr/bin/env bash
set -euo pipefail

# ══════════════════════════════════════════════
# Arnold — Install Script
# ══════════════════════════════════════════════
# Copies Arnold slash commands and CLAUDE.md
# into the current project directory.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/ArtifactHQ/Arnold-Lite/main/install.sh | bash
#
# Uninstall:
#   curl -fsSL https://raw.githubusercontent.com/ArtifactHQ/Arnold-Lite/main/install.sh | bash -s -- --uninstall
#
# Or run from a cloned repo:
#   ./install.sh
#   ./install.sh --uninstall
# ══════════════════════════════════════════════

ARNOLD_VERSION="0.1.0"
ARNOLD_REPO="ArtifactHQ/Arnold-Lite"
ARNOLD_BRANCH="main"
ARNOLD_RAW_BASE="https://raw.githubusercontent.com/${ARNOLD_REPO}/${ARNOLD_BRANCH}"

# Markers used to delimit Arnold content in CLAUDE.md
ARNOLD_START_MARKER="# ── Arnold Rules ──────────────────────────────"
ARNOLD_END_MARKER="# ── End Arnold Rules ──────────────────────────"

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

# Cleanup on error
cleanup() {
    if [ -d "/tmp/arnold-install" ]; then
        rm -rf /tmp/arnold-install
    fi
}
trap cleanup EXIT

# ── Parse Arguments ───────────────────────────

UNINSTALL=false
for arg in "$@"; do
    case "$arg" in
        --uninstall|-u)
            UNINSTALL=true
            ;;
    esac
done

# ── Uninstall ─────────────────────────────────

if [ "$UNINSTALL" = true ]; then
    print_banner
    echo -e "${YELLOW}Uninstalling Arnold...${NC}"
    echo ""

    # Remove command files
    if [ -d ".claude/commands/arnold" ]; then
        # Check for user-added files beyond Arnold's defaults
        ARNOLD_COMMANDS=("init.md" "plan.md" "check.md" "update.md" "status.md")
        EXTRA_FILES=()
        for f in .claude/commands/arnold/*.md; do
            [ -f "$f" ] || continue
            fname="$(basename "$f")"
            is_arnold=false
            for ac in "${ARNOLD_COMMANDS[@]}"; do
                if [ "$fname" = "$ac" ]; then
                    is_arnold=true
                    break
                fi
            done
            if [ "$is_arnold" = false ]; then
                EXTRA_FILES+=("$fname")
            fi
        done

        if [ ${#EXTRA_FILES[@]} -gt 0 ]; then
            print_warning "Found extra files in .claude/commands/arnold/ that Arnold didn't create:"
            for ef in "${EXTRA_FILES[@]}"; do
                echo "    - $ef"
            done
            print_warning "These will also be removed. Press Ctrl+C to abort, or wait 5 seconds..."
            sleep 5
        fi

        rm -rf .claude/commands/arnold
        print_success "Removed .claude/commands/arnold/"
    else
        print_info "No Arnold commands found"
    fi

    # Remove Arnold rules from CLAUDE.md (check both locations)
    for claude_md in "./CLAUDE.md" ".claude/CLAUDE.md"; do
        if [ -f "$claude_md" ] && grep -q "$ARNOLD_START_MARKER" "$claude_md" 2>/dev/null; then
            # Remove everything between start and end markers (inclusive)
            if grep -q "$ARNOLD_END_MARKER" "$claude_md" 2>/dev/null; then
                sed -i.bak "/$ARNOLD_START_MARKER/,/$ARNOLD_END_MARKER/d" "$claude_md"
                rm -f "${claude_md}.bak"
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

# Check if we're in a project directory
if [ ! -d ".git" ] && [ ! -f "package.json" ] && [ ! -f "requirements.txt" ] && [ ! -f "Cargo.toml" ] && [ ! -f "go.mod" ] && [ ! -f "Makefile" ]; then
    print_warning "This doesn't look like a project directory."
    echo "  Arnold works best when installed in a project root."
    echo ""
    # Handle both interactive and piped (curl | bash) usage
    if [ -t 0 ]; then
        read -p "  Install here anyway? (y/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "  No worries. cd into your project and try again."
            exit 0
        fi
    else
        print_info "Running in non-interactive mode — installing anyway"
    fi
fi

# Create .claude/commands/arnold/ directory (namespace for Arnold commands)
if [ -d ".claude/commands/arnold" ]; then
    print_info "Updating existing Arnold commands..."
else
    mkdir -p .claude/commands/arnold
    print_success "Created .claude/commands/arnold/"
fi

# Download command files
COMMANDS=("init" "plan" "check" "update" "status")

print_info "Downloading Arnold commands..."

# Ensure temp directory exists for all paths
mkdir -p /tmp/arnold-install

# Check if we're running from a cloned repo (verify it's actually Arnold's source)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
if [ -d "${SCRIPT_DIR}/commands/arnold" ] && [ -f "${SCRIPT_DIR}/commands/arnold/init.md" ] && grep -q "arnold:init" "${SCRIPT_DIR}/commands/arnold/init.md" 2>/dev/null; then
    # Local install from cloned repo
    for cmd in "${COMMANDS[@]}"; do
        if [ -f "${SCRIPT_DIR}/commands/arnold/${cmd}.md" ]; then
            cp "${SCRIPT_DIR}/commands/arnold/${cmd}.md" ".claude/commands/arnold/${cmd}.md"
            print_success "  /arnold:${cmd}"
        else
            print_error "  /arnold:${cmd} — file not found in ${SCRIPT_DIR}/commands/arnold/"
        fi
    done
else
    # Remote install from GitHub
    DOWNLOAD_FAILURES=0
    for cmd in "${COMMANDS[@]}"; do
        if curl -fsSL "${ARNOLD_RAW_BASE}/commands/arnold/${cmd}.md" -o "/tmp/arnold-install/${cmd}.md" 2>/dev/null && [ -s "/tmp/arnold-install/${cmd}.md" ]; then
            cp "/tmp/arnold-install/${cmd}.md" ".claude/commands/arnold/${cmd}.md"
            print_success "  /arnold:${cmd}"
        else
            print_error "  /arnold:${cmd} — failed to download"
            DOWNLOAD_FAILURES=$((DOWNLOAD_FAILURES + 1))
        fi
    done

    if [ "${DOWNLOAD_FAILURES}" -gt 0 ]; then
        echo ""
        print_error "Some commands failed to download. Please check your network connection and try again."
        exit 1
    fi
fi

# Handle CLAUDE.md
CLAUDE_MD_SOURCE=""
if [ -f "${SCRIPT_DIR}/CLAUDE.md" ] && grep -q "Arnold" "${SCRIPT_DIR}/CLAUDE.md" 2>/dev/null; then
    CLAUDE_MD_SOURCE="${SCRIPT_DIR}/CLAUDE.md"
elif curl -fsSL "${ARNOLD_RAW_BASE}/CLAUDE.md" -o "/tmp/arnold-install/CLAUDE.md" 2>/dev/null && [ -s "/tmp/arnold-install/CLAUDE.md" ]; then
    CLAUDE_MD_SOURCE="/tmp/arnold-install/CLAUDE.md"
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
        # Check if Arnold rules are already present (use our specific marker, not just "Arnold")
        if grep -q "$ARNOLD_START_MARKER" "$TARGET_CLAUDE_MD" 2>/dev/null; then
            # Replace existing Arnold rules (update in place)
            if grep -q "$ARNOLD_END_MARKER" "$TARGET_CLAUDE_MD" 2>/dev/null; then
                sed -i.bak "/$ARNOLD_START_MARKER/,/$ARNOLD_END_MARKER/d" "$TARGET_CLAUDE_MD"
                rm -f "${TARGET_CLAUDE_MD}.bak"
            else
                print_warning "Arnold start marker found in $TARGET_CLAUDE_MD but end marker is missing."
                print_warning "Please remove the old Arnold rules manually, then re-run install."
                exit 1
            fi
            # Re-append updated rules
            echo "" >> "$TARGET_CLAUDE_MD"
            echo "$ARNOLD_START_MARKER" >> "$TARGET_CLAUDE_MD"
            echo "" >> "$TARGET_CLAUDE_MD"
            cat "${CLAUDE_MD_SOURCE}" >> "$TARGET_CLAUDE_MD"
            echo "" >> "$TARGET_CLAUDE_MD"
            echo "$ARNOLD_END_MARKER" >> "$TARGET_CLAUDE_MD"
            print_success "Updated Arnold rules in $TARGET_CLAUDE_MD"
        else
            # Append new Arnold rules with markers
            echo "" >> "$TARGET_CLAUDE_MD"
            echo "$ARNOLD_START_MARKER" >> "$TARGET_CLAUDE_MD"
            echo "" >> "$TARGET_CLAUDE_MD"
            cat "${CLAUDE_MD_SOURCE}" >> "$TARGET_CLAUDE_MD"
            echo "" >> "$TARGET_CLAUDE_MD"
            echo "$ARNOLD_END_MARKER" >> "$TARGET_CLAUDE_MD"
            print_success "Appended Arnold rules to $TARGET_CLAUDE_MD"
        fi
    else
        # No existing CLAUDE.md — create new one with markers
        mkdir -p .claude
        echo "$ARNOLD_START_MARKER" > .claude/CLAUDE.md
        echo "" >> .claude/CLAUDE.md
        cat "${CLAUDE_MD_SOURCE}" >> .claude/CLAUDE.md
        echo "" >> .claude/CLAUDE.md
        echo "$ARNOLD_END_MARKER" >> .claude/CLAUDE.md
        print_success "Created .claude/CLAUDE.md"
    fi
else
    print_warning "Could not find CLAUDE.md template — you may need to create it manually"
fi

# Done
echo ""
echo -e "${GREEN}${BOLD}Arnold is installed.${NC}"
echo ""
echo "  Next steps:"
echo "    1. Open Claude Code in this project"
echo "    2. Run /arnold:init to scaffold your docs"
echo "    3. Run /arnold:plan to flesh out feature specs"
echo "    4. Build your code"
echo "    5. Run /arnold:check to see if docs and code are aligned"
echo "    6. Run /arnold:update to sync docs after code changes"
echo ""
echo "  To uninstall:"
echo "    curl -fsSL https://raw.githubusercontent.com/${ARNOLD_REPO}/${ARNOLD_BRANCH}/install.sh | bash -s -- --uninstall"
echo ""
echo -e "  ${CYAN}Hold on to your docs.${NC} 🦕"
echo ""

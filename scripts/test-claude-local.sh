#!/usr/bin/env bash
# Install dist/claude-plugin/ into a local Claude Code session for testing.
# Use this BEFORE submitting to the Anthropic marketplace to confirm the
# plugin actually works end-to-end.
#
# Usage:
#   ./scripts/test-claude-local.sh install    # symlink dist/ into ~/.claude/plugins/local/arnold
#   ./scripts/test-claude-local.sh uninstall  # remove the symlink
#   ./scripts/test-claude-local.sh status     # show current state
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DIST_DIR="${REPO_ROOT}/dist/claude-plugin"
LOCAL_PLUGINS_DIR="${HOME}/.claude/plugins/local"
LINK_PATH="${LOCAL_PLUGINS_DIR}/arnold"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

cmd="${1:-status}"

case "$cmd" in
    install)
        if [ ! -d "${DIST_DIR}" ]; then
            echo -e "${RED}✗${NC} ${DIST_DIR} does not exist."
            echo "  Run: make build"
            exit 1
        fi

        # Preflight: validate before wiring up
        echo -e "${CYAN}→${NC} Running preflight (build + validate + verify)..."
        (cd "${REPO_ROOT}" && make preflight) > /tmp/arnold-preflight.log 2>&1 || {
            echo -e "${RED}✗${NC} Preflight failed. See /tmp/arnold-preflight.log"
            exit 1
        }
        echo -e "${GREEN}✓${NC} Preflight passed"

        mkdir -p "${LOCAL_PLUGINS_DIR}"
        if [ -L "${LINK_PATH}" ] || [ -e "${LINK_PATH}" ]; then
            echo -e "${YELLOW}⚠${NC} ${LINK_PATH} already exists — removing"
            rm -rf "${LINK_PATH}"
        fi
        ln -s "${DIST_DIR}" "${LINK_PATH}"
        echo -e "${GREEN}✓${NC} Symlinked ${LINK_PATH} -> ${DIST_DIR}"
        echo ""
        echo "  Next steps in Claude Code:"
        echo "    1. Restart Claude Code (or run /reload-plugins if supported)"
        echo "    2. Run /plugin marketplace add local"
        echo "    3. Run /plugin install arnold@local"
        echo "    4. Try /arnold:init or /arnold:status"
        echo ""
        echo "  Uninstall: ${SCRIPT_DIR}/test-claude-local.sh uninstall"
        ;;

    uninstall)
        if [ -L "${LINK_PATH}" ]; then
            rm "${LINK_PATH}"
            echo -e "${GREEN}✓${NC} Removed ${LINK_PATH}"
        elif [ -e "${LINK_PATH}" ]; then
            echo -e "${YELLOW}⚠${NC} ${LINK_PATH} exists but is not a symlink — leaving alone"
            echo "  Remove manually if appropriate: rm -rf ${LINK_PATH}"
            exit 1
        else
            echo -e "${CYAN}→${NC} No Arnold dev install found at ${LINK_PATH}"
        fi
        echo ""
        echo "  Also uninstall from Claude Code:"
        echo "    /plugin uninstall arnold@local"
        ;;

    status)
        if [ -L "${LINK_PATH}" ]; then
            target=$(readlink "${LINK_PATH}")
            echo -e "${GREEN}✓${NC} Installed: ${LINK_PATH} -> ${target}"
            if [ "${target}" = "${DIST_DIR}" ]; then
                echo "  Matches current repo's dist/claude-plugin/"
            else
                echo -e "  ${YELLOW}⚠${NC} Symlink targets a different path than this repo — may be stale"
            fi
        elif [ -e "${LINK_PATH}" ]; then
            echo -e "${YELLOW}⚠${NC} ${LINK_PATH} exists but is not a symlink"
        else
            echo -e "${CYAN}→${NC} Not installed. Run: $0 install"
        fi
        ;;

    *)
        echo "Usage: $0 {install|uninstall|status}"
        exit 1
        ;;
esac

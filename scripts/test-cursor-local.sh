#!/usr/bin/env bash
# Install dist/cursor-plugin/ into a local Cursor session for smoke-testing
# the Cursor build output end-to-end before cutting a release.
#
# Cursor supports local plugin testing via ~/.cursor/plugins/local/ per
# Phase 0 S0.2 findings. Symlink the built artifact and Cursor will pick it up.
#
# Usage:
#   ./scripts/test-cursor-local.sh install
#   ./scripts/test-cursor-local.sh uninstall
#   ./scripts/test-cursor-local.sh status
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DIST_DIR="${REPO_ROOT}/dist/cursor-plugin"
LOCAL_PLUGINS_DIR="${HOME}/.cursor/plugins/local"
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
        echo "  Next steps in Cursor:"
        echo "    1. Restart Cursor (or reload plugins from Cursor settings)"
        echo "    2. Open a project and try /arnold-init in the chat input"
        echo "       (hyphen, not colon — Cursor doesn't allow colons in command names)"
        echo "    3. Confirm rules are loaded: ask 'What are Arnold's rules?'"
        echo ""
        echo "  Uninstall: ${SCRIPT_DIR}/test-cursor-local.sh uninstall"
        ;;

    uninstall)
        if [ -L "${LINK_PATH}" ]; then
            rm "${LINK_PATH}"
            echo -e "${GREEN}✓${NC} Removed ${LINK_PATH}"
        elif [ -e "${LINK_PATH}" ]; then
            echo -e "${YELLOW}⚠${NC} ${LINK_PATH} exists but is not a symlink — leaving alone"
            exit 1
        else
            echo -e "${CYAN}→${NC} No Arnold dev install found at ${LINK_PATH}"
        fi
        ;;

    status)
        if [ -L "${LINK_PATH}" ]; then
            target=$(readlink "${LINK_PATH}")
            echo -e "${GREEN}✓${NC} Installed: ${LINK_PATH} -> ${target}"
            if [ "${target}" = "${DIST_DIR}" ]; then
                echo "  Matches current repo's dist/cursor-plugin/"
            else
                echo -e "  ${YELLOW}⚠${NC} Symlink targets a different path — may be stale"
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

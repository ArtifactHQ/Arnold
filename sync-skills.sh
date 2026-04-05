#!/usr/bin/env bash
set -euo pipefail

# ══════════════════════════════════════════════
# Arnold — Sync commands/ → skills/
# ══════════════════════════════════════════════
# Generates skills/*/SKILL.md from commands/arnold/*.md
# Run this after editing any command file to keep
# both distributions in sync.
#
# Usage:
#   ./sync-skills.sh
# ══════════════════════════════════════════════

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMANDS_DIR="${SCRIPT_DIR}/commands/arnold"
SKILLS_DIR="${SCRIPT_DIR}/skills"

# Commands that need a <context> block for auto-scanning docs/
CONTEXT_COMMANDS=("status" "diff" "recap" "spec")

needs_context() {
    local cmd="$1"
    for ctx_cmd in "${CONTEXT_COMMANDS[@]}"; do
        if [ "$cmd" = "$ctx_cmd" ]; then
            return 0
        fi
    done
    return 1
}

synced=0

for cmd_file in "${COMMANDS_DIR}"/*.md; do
    [ -f "$cmd_file" ] || continue
    filename=$(basename "$cmd_file")
    cmd_name="${filename%.md}"
    skill_dir="${SKILLS_DIR}/${cmd_name}"
    skill_file="${skill_dir}/SKILL.md"

    # Ensure the skill directory exists (created on demand for new commands)
    mkdir -p "$skill_dir"

    # Read the existing frontmatter from the command file
    # Commands already have frontmatter (--- blocks), so we use it directly
    if head -1 "$cmd_file" | grep -q "^---$"; then
        # Command has frontmatter — copy as-is
        cp "$cmd_file" "$skill_file"
    else
        # Command has no frontmatter — add skill frontmatter
        {
            echo "---"
            echo "name: arnold:${cmd_name}"
            echo "description: \"Arnold ${cmd_name} command\""
            echo "---"
            echo ""
            cat "$cmd_file"
        } > "$skill_file"
    fi

    # Add context block for commands that need it (if not already present)
    if needs_context "$cmd_name" && ! grep -q "<context>" "$skill_file"; then
        cat >> "$skill_file" << 'CONTEXT_EOF'

<context>
<!-- Auto-injected by sync-skills.sh -->
Scan the docs/ folder structure before executing this command.
Read docs/overview.md and docs/status.md for project context.
</context>
CONTEXT_EOF
    fi

    synced=$((synced + 1))
done

echo "Synced ${synced} commands → skills/"
echo "Done. Skills are up to date with commands."

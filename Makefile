# Arnold build system — see build/README.md for rationale.
# All build outputs land in dist/ which is gitignored.

PYTHON ?= python3
BUILD := $(PYTHON) build/build.py

.PHONY: all build claude cursor codex antigravity verify validate preflight clean help

help:
	@echo "Arnold build targets:"
	@echo "  make build        Build all four plugin/skill artifacts to dist/"
	@echo "  make claude       Build Claude Code plugin only  (dist/claude-plugin/)"
	@echo "  make cursor       Build Cursor plugin only       (dist/cursor-plugin/)"
	@echo "  make codex        Build Codex skills only         (dist/codex-skills/)"
	@echo "  make antigravity  Build Antigravity skills only  (dist/antigravity-skills/)"
	@echo "  make verify       Build twice and diff hashes for determinism"
	@echo "  make validate     Schema / frontmatter checks on dist/ (pre-submission)"
	@echo "  make preflight    Clean + build + validate + verify — full pre-submission gate"
	@echo "  make clean        Remove dist/"

build all:
	$(BUILD) all

claude:
	$(BUILD) claude

cursor:
	$(BUILD) cursor

codex:
	$(BUILD) codex

antigravity:
	$(BUILD) antigravity

verify:
	$(BUILD) verify

validate:
	$(BUILD) validate

preflight: clean build validate verify
	@echo ""
	@echo "✓ preflight passed — dist/ is ready to submit"

clean:
	rm -rf dist

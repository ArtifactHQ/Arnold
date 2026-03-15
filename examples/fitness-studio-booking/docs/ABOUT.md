# About This Documentation

This project uses [Arnold](https://github.com/ArtifactHQ/Arnold-Lite) for documentation-first development.

## For New Team Members

The `docs/` folder is the source of truth for what this project should be and how it should behave. Read `overview.md` first, then browse feature folders.

## Quick Start

If you have Arnold installed, these commands are available:

- `/arnold:status` — see where the project stands
- `/arnold:check` — compare docs to code, find drift
- `/arnold:help` — full command reference

If you don't have Arnold, you can still read and edit docs manually — they're just markdown.

## Structure

    docs/
    ├── overview.md           Project vision and goals
    ├── status.md             Current state of each feature
    ├── ABOUT.md              This file
    ├── [feature]/            One folder per feature
    │   ├── overview.md       What it does, core rules
    │   └── [flow].md         Step-by-step user flows
    ├── decisions/            Why we chose what we chose
    └── unknowns.md           Open questions and bets

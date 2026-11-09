#!/usr/bin/env bash
# Renders docs/img/tui.svg from the real TUI on a seeded demo backlog, so the
# README screenshot never shows a screen the code no longer draws.
# usage: scripts/screenshot-tui.sh   (or `make screenshot`)
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COLS=150
ROWS=26
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK" "$ROOT/node_modules"' EXIT

cd "$ROOT"
# screenshot_dump seeds two epics and nine tasks, then presses `j` three times so the detail pane has content.
RADIN_SCREENSHOT_RAW="$WORK/screen" cargo test -q --test tui_pty screenshot_dump -- --ignored >/dev/null

# Pinned and removed after the run, like `make diagrams`: radin tracks no JS dependency.
npm i --no-save --no-package-lock @xterm/headless@5.5.0 >/dev/null
node scripts/tui-svg.mjs "$WORK/screen" docs/img/tui.svg "$COLS" "$ROWS"

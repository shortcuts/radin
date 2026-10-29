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

make -s -C "$ROOT" lib/radin-tui tests/helpers/pty-run

mkdir "$WORK/demo"
cd "$WORK/demo"
git init -q
bk() { bash "$ROOT/lib/radin-backlog.sh" "$@"; }
# add <category> <title> <deps> <body>: prints the task id.
add() { printf '%s\n' "$4" | bk add "$1" "$2" ${3:+--deps "$3"} 2>/dev/null; }

printf 'Move the API from session cookies to short-lived JWTs without logging anyone out.\n' | bk epic-add auth-rework >/dev/null
printf 'Make the nightly import finish in minutes instead of hours.\n' | bk epic-add import-speed >/dev/null

a=$(add feat "Issue JWT access and refresh tokens" "" "Add /auth/token. Access token 15 min, refresh 7 days.")
b=$(add refactor "Replace session middleware with a token check" "$a" "Swap the cookie lookup for a verified JWT claim.")
c=$(add fix "Reject expired refresh tokens with 401" "$a" "An expired refresh token returns 500 today.")
d=$(add chore "Document the new login flow" "$b" "Update docs/auth.md.")
e=$(add refactor "Batch inserts in the CSV importer" "" "One INSERT per row takes 40 min on 1M rows.")
f=$(add fix "Stream the import instead of loading it in memory" "$e" "The importer runs out of memory on files over 2 GB.")
g=$(add feat "Resume an interrupted import from its last row" "$f" "Store the row offset after each batch.")
h=$(add fix "Trim trailing whitespace in exported CSV headers" "" "Headers carry a trailing space.")
i=$(add chore "Bump the HTTP client to the latest minor" "" "No API change expected.")

for t in $a $b $c $d; do bk epic-move "$t" auth-rework >/dev/null; done
for t in $e $f $g; do bk epic-move "$t" import-speed >/dev/null; done

prio() { bk set-priority "$1" "$2" >/dev/null; }
prio "$a" 13 && prio "$b" 8 && prio "$c" 8 && prio "$d" 2
prio "$e" 13 && prio "$f" 8 && prio "$g" 5 && prio "$h" 5 && prio "$i" 1

# Three `j` presses select the first epic's first task, so the detail pane has content.
PTY_COLS=$COLS PTY_ROWS=$ROWS PTY_QUIET=0.4 \
	"$ROOT/tests/helpers/pty-run" "$WORK/screen" "j|j|j" "$ROOT/lib/radin-tui" >/dev/null 2>&1 || true

cd "$ROOT"
# Pinned and removed after the run, like `make diagrams`: radin tracks no JS dependency.
npm i --no-save --no-package-lock @xterm/headless@5.5.0 >/dev/null
node scripts/tui-svg.mjs "$WORK/screen" docs/img/tui.svg "$COLS" "$ROWS"

#!/usr/bin/env bash
# Single source of truth for radin's per-project namespace resolution.
# Installed to ~/.claude/.radin/lib/radin-namespace.sh by install.sh.
# Every radin agent/skill that reads or writes the backlog runs this
# script first and reads REPO_ROOT / NAMESPACE_DIR / BACKLOG_INDEX /
# BACKLOG_TASKS_DIR from its stdout.
#
# All state lives inside the current repo, at <repo-root>/.claude/.radin/.
# Outside a git repo, the current directory takes the repo root's place.
set -euo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
[ -n "$REPO_ROOT" ] || REPO_ROOT="$PWD"
NAMESPACE_DIR="$REPO_ROOT/.claude/.radin"
BACKLOG_TASKS_DIR="$NAMESPACE_DIR/backlog/tasks"
mkdir -p "$NAMESPACE_DIR/state" "$NAMESPACE_DIR/plans" "$NAMESPACE_DIR/reviews" "$BACKLOG_TASKS_DIR"
BACKLOG_INDEX="$NAMESPACE_DIR/backlog/index.jsonl"

# %q keeps the output source-able even when the repo path contains spaces.
printf 'REPO_ROOT=%q\n' "$REPO_ROOT"
printf 'NAMESPACE_DIR=%q\n' "$NAMESPACE_DIR"
printf 'BACKLOG_INDEX=%q\n' "$BACKLOG_INDEX"
printf 'BACKLOG_TASKS_DIR=%q\n' "$BACKLOG_TASKS_DIR"

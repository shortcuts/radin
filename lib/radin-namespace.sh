#!/usr/bin/env bash
# Single source of truth for radin's per-project namespace resolution.
# Installed to ~/.claude/radin-lib/radin-namespace.sh by install.sh.
# Every radin agent/skill that reads or writes ISSUES.md runs this script
# first and reads REPO_ROOT / NAMESPACE_DIR / ISSUES_FILE from its stdout.
set -euo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
if command -v md5 >/dev/null 2>&1; then
	HASH_CMD="md5"
else
	HASH_CMD="md5sum"
fi
if [ -n "$REPO_ROOT" ]; then
	SLUG="$(basename "$REPO_ROOT")-$(printf '%s' "$REPO_ROOT" | $HASH_CMD | cut -c1-8)"
else
	SLUG="no-repo-$(printf '%s' "$PWD" | $HASH_CMD | cut -c1-8)"
fi
NAMESPACE_DIR="$HOME/.claude/.radin/projects/$SLUG"
mkdir -p "$NAMESPACE_DIR/state" "$NAMESPACE_DIR/plans" "$NAMESPACE_DIR/reviews"
ISSUES_FILE="$NAMESPACE_DIR/ISSUES.md"

REGISTRY="$HOME/.claude/.radin/registry.json"
[ -f "$REGISTRY" ] || echo '{}' >"$REGISTRY"
TMP="$REGISTRY.tmp.$$" # same dir as $REGISTRY -- required for atomic mv
if command -v jq >/dev/null 2>&1; then
	jq --arg k "$SLUG" --arg p "$REPO_ROOT" --arg t "$(date -u +%FT%TZ)" \
		'.[$k] = {path: $p, updated_at: $t}' "$REGISTRY" >"$TMP" && mv "$TMP" "$REGISTRY"
elif command -v python3 >/dev/null 2>&1; then
	python3 -c "
import json
r = json.load(open('$REGISTRY'))
r['$SLUG'] = {'path': '$REPO_ROOT', 'updated_at': __import__('datetime').datetime.utcnow().isoformat()+'Z'}
json.dump(r, open('$TMP', 'w'), indent=2)
" && mv "$TMP" "$REGISTRY"
else
	echo "note: no jq/python3 found, skipping registry.json index update (non-critical)" >&2
fi
# registry.json is a best-effort index -- a skipped upsert never blocks
# ISSUES_FILE from being written correctly.

echo "REPO_ROOT=$REPO_ROOT"
echo "NAMESPACE_DIR=$NAMESPACE_DIR"
echo "ISSUES_FILE=$ISSUES_FILE"

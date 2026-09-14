#!/usr/bin/env bash
# Shared JSON field helpers for radin's JSONL stores (backlog index,
# BACKLOG_STEPS.json, completed.json). Sourced by radin-backlog.sh and
# radin-state.sh so the escaping/extraction logic lives in one place and
# can never drift between them. Not meant to run on its own.
# Must stay bash-3.2-compatible (macOS /bin/bash).

json_escape() {
	printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# Extracts field $1 (e.g. id|status|commit|category|title|file) from JSONL
# line $2, unescaped.
json_get() {
	printf '%s' "$2" | sed -E "s/.*\"$1\":\"((\\\\.|[^\"\\\\])*)\".*/\\1/" | sed -e 's/\\"/"/g' -e 's/\\\\/\\/g'
}

# Extracts non-string field $1 (integer or array of strings) from JSONL line
# $2, raw and unquoted. Empty when the key is absent: "nobody set this" must
# stay distinguishable from any value a caller could have set.
json_get_raw() {
	printf '%s' "$2" | sed -n -E "s/.*\"$1\":(-?[0-9]+|\\[[^]]*\\]).*/\\1/p"
}

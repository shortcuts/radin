#!/usr/bin/env bash
# Shared JSON field helpers for radin's JSONL stores (backlog index,
# BACKLOG_STEPS.json, completed.json). Sourced by radin-backlog.sh and
# radin-state.sh so the escaping/extraction logic lives in one place and
# can never drift between them. Not meant to run on its own.
# Must stay bash-3.2-compatible (macOS /bin/bash).

json_escape() {
	local v="${1//\\/\\\\}"
	printf '%s' "${v//\"/\\\"}"
}

# Extracts field $1 (e.g. id|status|commit|category|title|file) from JSONL
# line $2, unescaped. Empty when the key is absent, same as json_get_raw: a
# line written before a field existed reads as unknown, never as its own text.
json_get() {
	# No sed pipeline: a call forked two seds, and the loops read dozens of fields.
	# The leading .* keeps sed's rule that the last occurrence of the key wins.
	local re=".*\"$1\":\"(([\\].|[^\"\\])*)\""
	if [[ $2 =~ $re ]]; then
		local v="${BASH_REMATCH[1]}"
		v="${v//\\\"/\"}"
		printf '%s\n' "${v//\\\\/\\}"
	fi
}

# Extracts non-string field $1 (integer or array of strings) from JSONL line
# $2, raw and unquoted. Empty when the key is absent: "nobody set this" must
# stay distinguishable from any value a caller could have set.
json_get_raw() {
	local re=".*\"$1\":(-?[0-9]+|\[[^]]*\])"
	if [[ $2 =~ $re ]]; then printf '%s\n' "${BASH_REMATCH[1]}"; fi
}

#!/usr/bin/env bash
# radin telemetry: appends one JSON line per event to ~/.radin/telemetry/<scope>.jsonl.
# Installed to ~/.radin/lib/radin-telemetry.sh by install.sh; reached as `radin telemetry`.
# Must stay bash-3.2-compatible (macOS /bin/bash).
# A failed write warns and exits 0: a record never blocks the run that makes it.
#
#   radin-telemetry.sh record <scope> <kind> [key=value ...]
#   radin-telemetry.sh report-error <scope> <where> <message> [key=value ...]
set -euo pipefail
# Glob ranges below match ASCII only, whatever locale the caller runs in.
LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$HERE/radin-json.sh"

fail() {
	printf 'radin telemetry: %s\n' "$1" >&2
	printf 'usage: radin telemetry record <scope> <kind> [key=value ...]\n' >&2
	printf '       radin telemetry report-error <scope> <where> <message> [key=value ...]\n' >&2
	exit 2
}

valid_name() {
	case "$1" in
	'' | [!a-z]* | *[!a-z0-9-]*) return 1 ;;
	esac
}

# Sets EVIDENCE to a JSON object from the key=value arguments, in order.
evidence_of() {
	local pair key sep=""
	EVIDENCE=""
	for pair in "$@"; do
		case "$pair" in *=*) ;; *) fail "not a key=value pair: $pair" ;; esac
		key="${pair%%=*}"
		case "$key" in '' | *[!A-Za-z0-9_.-]*) fail "invalid key: $key" ;; esac
		EVIDENCE="$EVIDENCE$sep\"$key\":\"$(json_escape "${pair#*=}" | tr '\n\r\t' '   ')\""
		sep=,
	done
	EVIDENCE="{$EVIDENCE}"
}

# shortcut: a line above PIPE_BUF could interleave with a parallel append, add flock when records carry large evidence.
append() { # $1 scope, $2 kind, $3 evidence object
	local dir="$HOME/.radin/telemetry" file="$HOME/.radin/telemetry/$1.jsonl" ts repo line
	ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	repo="$(git rev-parse --show-toplevel 2>/dev/null || printf '%s' "$PWD")"
	line="{\"ts\":\"$ts\",\"repo\":\"$(json_escape "$repo")\",\"scope\":\"$1\",\"kind\":\"$2\",\"evidence\":$3}"
	if ! { mkdir -p "$dir" && printf '%s\n' "$line" >>"$file"; } 2>/dev/null; then
		printf 'radin telemetry: warning: could not write %s\n' "$file" >&2
	fi
}

case "${1:-}" in
record)
	[ $# -ge 3 ] || fail "record needs <scope> <kind>"
	scope="$2" kind="$3"
	shift 3
	;;
report-error)
	[ $# -ge 4 ] || fail "report-error needs <scope> <where> <message>"
	scope="$2" kind=error
	set -- "where=$3" "message=$4" "${@:5}"
	;;
*) fail "unknown verb: ${1:-(none)}" ;;
esac

valid_name "$scope" || fail "invalid scope: $scope"
valid_name "$kind" || fail "invalid kind: $kind"
evidence_of "$@"
append "$scope" "$kind" "$EVIDENCE"

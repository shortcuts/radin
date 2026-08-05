#!/usr/bin/env bash
# Deterministic operations on radin-execute's per-session state files
# (BACKLOG_STEPS.json, completed.json), so the orchestrator never hand-edits
# JSON in its own prose. Installed to ~/.claude/.radin/lib/radin-state.sh by
# install.sh.
#
# Both files are JSONL (one compact JSON object per line) -- same convention
# as the backlog index (radin-backlog.sh) -- never a bracketed/comma-joined
# JSON array, so editing one line never risks another.
#
# Usage:
#   radin-state.sh set-status <steps-file> <id> <pending|failed|blocked> [note]
#   radin-state.sh remove <steps-file> <id>               # delete a completed entry's line
#   radin-state.sh completed-add <completed-file> <id> <commit-hash>
#   radin-state.sh completed-get <completed-file> <id>   # prints commit hash, exit 1 if absent
#   radin-state.sh dirty-check <repo-root>                # git status --porcelain, excluding .claude/.radin
#
# Must stay bash-3.2-compatible (macOS /bin/bash).
set -euo pipefail

die() {
	printf 'radin-state: %s\n' "$*" >&2
	exit 1
}

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/radin-json.sh"

cmd="${1:-}"
case "$cmd" in
set-status)
	file="${2:-}"
	id="${3:-}"
	status="${4:-}"
	note="${5:-}"
	[ -n "$file" ] && [ -n "$id" ] && [ -n "$status" ] || die "usage: set-status <steps-file> <id> <pending|failed|blocked> [note]"
	[ -f "$file" ] || die "no state file: $file"
	case "$status" in
	pending | failed | blocked) ;;
	*) die "status must be pending|failed|blocked, got: $status" ;;
	esac
	found=0
	esc_note="$(json_escape "$note")"
	while IFS= read -r line || [ -n "$line" ]; do
		[ -n "$line" ] || continue
		if [ "$(json_get id "$line")" = "$id" ]; then
			order="$(printf '%s' "$line" | sed -E 's/.*"order":([0-9]+).*/\1/')"
			depends_on="$(printf '%s' "$line" | sed -E 's/.*"depends_on":(\[[^]]*\]).*/\1/')"
			printf '{"id":"%s","order":%s,"status":"%s","depends_on":%s,"note":"%s"}\n' \
				"$id" "$order" "$status" "$depends_on" "$esc_note"
			found=1
		else
			printf '%s\n' "$line"
		fi
	done <"$file" >"$file.tmp"
	mv "$file.tmp" "$file"
	[ "$found" -eq 1 ] || die "no entry with id: $id"
	;;

remove)
	file="${2:-}"
	id="${3:-}"
	[ -n "$file" ] && [ -n "$id" ] || die "usage: remove <steps-file> <id>"
	[ -f "$file" ] || die "no state file: $file"
	grep -v -F "\"id\":\"$id\"" "$file" >"$file.tmp" || true
	mv "$file.tmp" "$file"
	;;

completed-add)
	file="${2:-}"
	id="${3:-}"
	hash="${4:-}"
	[ -n "$file" ] && [ -n "$id" ] && [ -n "$hash" ] || die "usage: completed-add <completed-file> <id> <commit-hash>"
	printf '{"id":"%s","commit":"%s"}\n' "$(json_escape "$id")" "$(json_escape "$hash")" >>"$file"
	;;

completed-get)
	file="${2:-}"
	id="${3:-}"
	[ -n "$file" ] && [ -n "$id" ] || die "usage: completed-get <completed-file> <id>"
	[ -f "$file" ] || exit 1
	while IFS= read -r line || [ -n "$line" ]; do
		[ -n "$line" ] || continue
		if [ "$(json_get id "$line")" = "$id" ]; then
			json_get commit "$line"
			exit 0
		fi
	done <"$file"
	exit 1
	;;

dirty-check)
	repo_root="${2:-}"
	[ -n "$repo_root" ] || die "usage: dirty-check <repo-root>"
	git -C "$repo_root" status --porcelain -- . ':(exclude).claude/.radin'
	;;

*)
	die "unknown command: ${cmd:-<none>} (set-status|remove|completed-add|completed-get|dirty-check)"
	;;
esac

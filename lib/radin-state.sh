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
#   radin-state.sh steps-init <steps-file>                # write the file from "id<TAB>order<TAB>depends-on-csv" lines on stdin
#   radin-state.sh next-pending <steps-file>              # print lowest-order pending entry as "id<TAB>order<TAB>depends-on-csv", exit 1 if none
#   radin-state.sh set-status <steps-file> <id> <pending|failed|blocked> [note]
#   radin-state.sh remove <steps-file> <id>               # delete a completed entry's line
#   radin-state.sh deps-check <steps-file> <completed-file> <id>  # print "dep<TAB>hash" per dependency, exit 1 naming the first unresolved one
#   radin-state.sh completed-add <completed-file> <id> <commit-hash>
#   radin-state.sh completed-get <completed-file> <id>   # prints commit hash, exit 1 if absent
#   radin-state.sh task-done <namespace-dir> <id> <commit-hash>  # completed-add + backlog remove + steps remove, in crash-safe order
#   radin-state.sh dirty-check <repo-root>                # git status --porcelain, excluding .claude/.radin
#   radin-state.sh stash <repo-root> <message>            # stash everything except .claude/.radin, print the stash ref
#
# Must stay bash-3.2-compatible (macOS /bin/bash).
set -euo pipefail

die() {
	printf 'radin-state: %s\n' "$*" >&2
	exit 1
}

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$LIB_DIR/radin-json.sh"

# Prints line $1's depends_on as a comma-separated id list (empty for []).
deps_csv() {
	printf '%s' "$1" | sed -E 's/.*"depends_on":\[([^]]*)\].*/\1/' | tr -d '" '
}

cmd="${1:-}"
case "$cmd" in
steps-init)
	file="${2:-}"
	[ -n "$file" ] || die "usage: steps-init <steps-file>  (lines of id<TAB>order<TAB>depends-on-csv on stdin)"
	n=0
	: >"$file.tmp"
	while IFS=$'\t' read -r id order deps || [ -n "${id:-}" ]; do
		[ -n "$id" ] || continue
		case "$order" in
		'' | *[!0-9]*)
			rm -f "$file.tmp"
			die "bad order for '$id': ${order:-<empty>}"
			;;
		esac
		deps_json="[]"
		deps="$(printf '%s' "${deps:-}" | tr -d ' ')"
		[ -z "$deps" ] || deps_json="[$(printf '%s' "$deps" | sed -E 's/([^,]+)/"\1"/g')]"
		printf '{"id":"%s","order":%s,"status":"pending","depends_on":%s,"note":""}\n' \
			"$(json_escape "$id")" "$order" "$deps_json" >>"$file.tmp"
		n=$((n + 1))
	done
	[ "$n" -gt 0 ] || {
		rm -f "$file.tmp"
		die "no entries on stdin"
	}
	mv "$file.tmp" "$file"
	printf 'steps-init: wrote %d entries to %s\n' "$n" "$file"
	;;

next-pending)
	file="${2:-}"
	[ -n "$file" ] || die "usage: next-pending <steps-file>"
	[ -f "$file" ] || exit 1
	best_line=""
	best_order=""
	while IFS= read -r line || [ -n "$line" ]; do
		[ -n "$line" ] || continue
		[ "$(json_get status "$line")" = "pending" ] || continue
		order="$(printf '%s' "$line" | sed -E 's/.*"order":([0-9]+).*/\1/')"
		if [ -z "$best_order" ] || [ "$order" -lt "$best_order" ]; then
			best_order="$order"
			best_line="$line"
		fi
	done <"$file"
	[ -n "$best_line" ] || exit 1
	printf '%s\t%s\t%s\n' "$(json_get id "$best_line")" "$best_order" "$(deps_csv "$best_line")"
	;;

deps-check)
	steps="${2:-}"
	completed="${3:-}"
	id="${4:-}"
	[ -n "$steps" ] && [ -n "$completed" ] && [ -n "$id" ] || die "usage: deps-check <steps-file> <completed-file> <id>"
	[ -f "$steps" ] || die "no state file: $steps"
	entry=""
	while IFS= read -r line || [ -n "$line" ]; do
		[ -n "$line" ] || continue
		[ "$(json_get id "$line")" = "$id" ] && entry="$line"
	done <"$steps"
	[ -n "$entry" ] || die "no entry with id: $id"
	deps="$(deps_csv "$entry")"
	[ -n "$deps" ] || exit 0
	old_ifs="$IFS"
	IFS=','
	# Splitting the csv into positional params is the point here.
	# shellcheck disable=SC2086
	set -- $deps
	IFS="$old_ifs"
	for dep in "$@"; do
		[ -n "$dep" ] || continue
		if hash="$(bash "$LIB_DIR/radin-state.sh" completed-get "$completed" "$dep")"; then
			printf '%s\t%s\n' "$dep" "$hash"
		else
			dep_status="missing from $steps"
			while IFS= read -r line || [ -n "$line" ]; do
				[ -n "$line" ] || continue
				[ "$(json_get id "$line")" = "$dep" ] && dep_status="$(json_get status "$line")"
			done <"$steps"
			die "task '$id' waiting on dependency '$dep', which is $dep_status"
		fi
	done
	;;

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

task-done)
	ns="${2:-}"
	id="${3:-}"
	hash="${4:-}"
	[ -n "$ns" ] && [ -n "$id" ] && [ -n "$hash" ] || die "usage: task-done <namespace-dir> <id> <commit-hash>"
	[ -d "$ns" ] || die "no namespace dir: $ns"
	repo_root="${ns%/.claude/.radin}"
	completed="$ns/state/completed.json"
	steps="$ns/state/BACKLOG_STEPS.json"
	# Order matters: record success first, so a crash mid-way leaves a state
	# radin-backlog.sh reconcile can repair. Each step is skipped when a
	# retry already did it, so re-running after a crash is safe.
	if ! bash "$LIB_DIR/radin-state.sh" completed-get "$completed" "$id" >/dev/null 2>&1; then
		bash "$LIB_DIR/radin-state.sh" completed-add "$completed" "$id" "$hash"
	fi
	if grep -qF "\"id\":\"$id\"" "$ns/backlog/index.jsonl" 2>/dev/null; then
		(cd "$repo_root" && bash "$LIB_DIR/radin-backlog.sh" remove "$id" >/dev/null)
	fi
	if [ -f "$steps" ]; then
		bash "$LIB_DIR/radin-state.sh" remove "$steps" "$id"
	fi
	printf 'task-done: %s recorded at %s; backlog and steps entries removed\n' "$id" "$hash"
	;;

dirty-check)
	repo_root="${2:-}"
	[ -n "$repo_root" ] || die "usage: dirty-check <repo-root>"
	git -C "$repo_root" status --porcelain -- . ':(exclude).claude/.radin'
	;;

stash)
	repo_root="${2:-}"
	msg="${3:-}"
	[ -n "$repo_root" ] && [ -n "$msg" ] || die "usage: stash <repo-root> <message>"
	before="$(git -C "$repo_root" stash list | grep -c . || true)"
	git -C "$repo_root" stash push -u -m "$msg" -- . ':(exclude).claude/.radin' >/dev/null
	after="$(git -C "$repo_root" stash list | grep -c . || true)"
	[ "$after" -gt "$before" ] || die "nothing to stash"
	printf 'stash@{0}\n'
	;;

*)
	die "unknown command: ${cmd:-<none>} (steps-init|next-pending|set-status|remove|deps-check|completed-add|completed-get|task-done|dirty-check|stash)"
	;;
esac

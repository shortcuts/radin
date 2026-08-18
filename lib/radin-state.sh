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
#   radin-state.sh start <steps-file> <id>                # mark in_progress, bump attempts; exit 2 (entry set blocked) past MAX_ATTEMPTS
#   radin-state.sh stuck <steps-file>                     # print "id<TAB>attempts<TAB>note" per in_progress entry, exit 1 if none
#   radin-state.sh triage <namespace-dir> <id>            # print recovery facts for a task a dead session left in_progress
#   radin-state.sh set-status <steps-file> <id> <pending|in_progress|failed|blocked> [note]
#   radin-state.sh remove <steps-file> <id>               # delete a completed entry's line
#   radin-state.sh deps-check <steps-file> <completed-file> <id>  # print "dep<TAB>hash" per dependency, exit 1 naming the first unresolved one
#   radin-state.sh completed-add <completed-file> <id> <commit-hash>
#   radin-state.sh completed-get <completed-file> <id>   # prints commit hash, exit 1 if absent
#   radin-state.sh task-done <namespace-dir> <id> <commit-hash>  # completed-add + backlog remove + steps remove, in crash-safe order
#   radin-state.sh task-dir <repo-root> <id>              # print the task's worktree if it exists, else <repo-root>
#   radin-state.sh prepare <namespace-dir> <id>           # create/reuse the task's tree and branch per session.json, print the dir to work in
#   radin-state.sh dirty-check <dir>                      # git status --porcelain, excluding .claude/.radin
#   radin-state.sh stash <repo-root> <message>            # stash everything except .claude/.radin, print the stash ref
#   radin-state.sh session-set <namespace-dir> <worktree-mode> <branch-mode>  # persist Phase 0.5 answers
#   radin-state.sh session-get <namespace-dir>            # print "worktree<TAB>yes" / "branch<TAB>no", exit 1 if unanswered
#   radin-state.sh journal-tail <namespace-dir> [n]        # last n journal events (default 20)
#
# Every mutation also appends one event to <state-dir>/journal.jsonl. The
# journal is append-only forensics: it survives context compaction and a
# killed session, and nothing reads it for control flow.
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

# A task dispatched this many times without a terminal status is not
# crash-looping any further -- it gets blocked for the user instead.
MAX_ATTEMPTS=3

# Prints line $1's numeric field $2 (order|attempts), 0 when absent.
num_field() {
	v="$(printf '%s' "$1" | sed -nE "s/.*\"$2\":([0-9]+).*/\1/p")"
	printf '%s' "${v:-0}"
}

journal() {
	state_dir="$1"
	event="$2"
	id="$3"
	detail="${4:-}"
	[ -d "$state_dir" ] || return 0
	printf '{"ts":"%s","event":"%s","id":"%s","detail":"%s"}\n' \
		"$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(json_escape "$event")" \
		"$(json_escape "$id")" "$(json_escape "$detail")" >>"$state_dir/journal.jsonl"
}

# Rewrites entry $2 in steps-file $1 with status $3, attempts $4, note $5.
write_entry() {
	file="$1"
	id="$2"
	status="$3"
	attempts="$4"
	esc_note="$(json_escape "$5")"
	found=0
	while IFS= read -r line || [ -n "$line" ]; do
		[ -n "$line" ] || continue
		if [ "$(json_get id "$line")" = "$id" ]; then
			order="$(num_field "$line" order)"
			depends_on="$(printf '%s' "$line" | sed -E 's/.*"depends_on":(\[[^]]*\]).*/\1/')"
			printf '{"id":"%s","order":%s,"status":"%s","depends_on":%s,"attempts":%s,"note":"%s"}\n' \
				"$(json_escape "$id")" "$order" "$status" "$depends_on" "$attempts" "$esc_note"
			found=1
		else
			printf '%s\n' "$line"
		fi
	done <"$file" >"$file.tmp"
	mv "$file.tmp" "$file"
	[ "$found" -eq 1 ] || die "no entry with id: $id"
	journal "$(dirname "$file")" "$status" "$id" "$5"
}

# Prints entry $2's line from steps-file $1, empty when absent.
entry_line() {
	while IFS= read -r line || [ -n "$line" ]; do
		[ -n "$line" ] || continue
		if [ "$(json_get id "$line")" = "$2" ]; then
			printf '%s' "$line"
		fi
	done <"$1"
	return 0
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
		printf '{"id":"%s","order":%s,"status":"pending","depends_on":%s,"attempts":0,"note":""}\n' \
			"$(json_escape "$id")" "$order" "$deps_json" >>"$file.tmp"
		n=$((n + 1))
	done
	[ "$n" -gt 0 ] || {
		rm -f "$file.tmp"
		die "no entries on stdin"
	}
	mv "$file.tmp" "$file"
	journal "$(dirname "$file")" "steps-init" "" "$n entries"
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
	entry="$(entry_line "$steps" "$id")"
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
			dep_line="$(entry_line "$steps" "$dep")"
			[ -z "$dep_line" ] || dep_status="$(json_get status "$dep_line")"
			die "task '$id' waiting on dependency '$dep', which is $dep_status"
		fi
	done
	;;

set-status)
	file="${2:-}"
	id="${3:-}"
	status="${4:-}"
	note="${5:-}"
	[ -n "$file" ] && [ -n "$id" ] && [ -n "$status" ] || die "usage: set-status <steps-file> <id> <pending|in_progress|failed|blocked> [note]"
	[ -f "$file" ] || die "no state file: $file"
	case "$status" in
	pending | in_progress | failed | blocked) ;;
	*) die "status must be pending|in_progress|failed|blocked, got: $status" ;;
	esac
	entry="$(entry_line "$file" "$id")"
	[ -n "$entry" ] || die "no entry with id: $id"
	write_entry "$file" "$id" "$status" "$(num_field "$entry" attempts)" "$note"
	;;

start)
	file="${2:-}"
	id="${3:-}"
	[ -n "$file" ] && [ -n "$id" ] || die "usage: start <steps-file> <id>"
	[ -f "$file" ] || die "no state file: $file"
	entry="$(entry_line "$file" "$id")"
	[ -n "$entry" ] || die "no entry with id: $id"
	attempts="$(num_field "$entry" attempts)"
	attempts=$((attempts + 1))
	if [ "$attempts" -gt "$MAX_ATTEMPTS" ]; then
		write_entry "$file" "$id" "blocked" "$((attempts - 1))" "dispatched $MAX_ATTEMPTS times without a terminal status -- needs a human look before another retry"
		printf 'start: %s hit MAX_ATTEMPTS=%d, marked blocked\n' "$id" "$MAX_ATTEMPTS" >&2
		exit 2
	fi
	write_entry "$file" "$id" "in_progress" "$attempts" ""
	printf 'attempts\t%s\n' "$attempts"
	;;

stuck)
	file="${2:-}"
	[ -n "$file" ] || die "usage: stuck <steps-file>"
	[ -f "$file" ] || exit 1
	n=0
	while IFS= read -r line || [ -n "$line" ]; do
		[ -n "$line" ] || continue
		[ "$(json_get status "$line")" = "in_progress" ] || continue
		printf '%s\t%s\t%s\n' "$(json_get id "$line")" "$(num_field "$line" attempts)" "$(json_get note "$line")"
		n=$((n + 1))
	done <"$file"
	[ "$n" -gt 0 ] || exit 1
	;;

triage)
	ns="${2:-}"
	id="${3:-}"
	[ -n "$ns" ] && [ -n "$id" ] || die "usage: triage <namespace-dir> <id>"
	[ -d "$ns" ] || die "no namespace dir: $ns"
	repo_root="${ns%/.claude/.radin}"
	steps="$ns/state/BACKLOG_STEPS.json"
	entry=""
	[ -f "$steps" ] && entry="$(entry_line "$steps" "$id")"
	printf 'attempts\t%s\n' "$(num_field "${entry:-}" attempts)"
	if hash="$(bash "$LIB_DIR/radin-state.sh" completed-get "$ns/state/completed.json" "$id" 2>/dev/null)"; then
		printf 'completed\t%s\n' "$hash"
	else
		printf 'completed\tnone\n'
	fi
	branch="radin/$id"
	wt="$(bash "$LIB_DIR/radin-state.sh" task-dir "$repo_root" "$id")"
	if [ "$wt" = "$repo_root" ]; then
		printf 'worktree\tnone\n'
	else
		printf 'worktree\t%s\n' "$wt"
	fi
	if git -C "$repo_root" rev-parse --verify --quiet "$branch" >/dev/null 2>&1; then
		printf 'branch\t%s\n' "$branch"
		git -C "$repo_root" log --oneline --no-decorate "$branch" --not HEAD 2>/dev/null |
			sed -n '1,20p' | sed 's/^/branch_commit\t/'
	else
		printf 'branch\tnone\n'
	fi
	dirty="$(git -C "$wt" status --porcelain -- . ':(exclude).claude/.radin' 2>/dev/null | grep -c . || true)"
	printf 'dirty_files\t%s\n' "$dirty"
	;;

remove)
	file="${2:-}"
	id="${3:-}"
	[ -n "$file" ] && [ -n "$id" ] || die "usage: remove <steps-file> <id>"
	[ -f "$file" ] || die "no state file: $file"
	grep -v -F "\"id\":\"$id\"" "$file" >"$file.tmp" || true
	mv "$file.tmp" "$file"
	journal "$(dirname "$file")" "removed" "$id" ""
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
	journal "$ns/state" "done" "$id" "$hash"
	printf 'task-done: %s recorded at %s; backlog and steps entries removed\n' "$id" "$hash"
	;;

prepare)
	# The one place the recorded worktree/branch answers turn into git
	# commands. A sub-agent only cds to the path this prints, so a "no" the
	# model would rather ignore never reaches a git invocation.
	ns="${2:-}"
	id="${3:-}"
	[ -n "$ns" ] && [ -n "$id" ] || die "usage: prepare <namespace-dir> <id>"
	session="$(bash "$LIB_DIR/radin-state.sh" session-get "$ns" 2>/dev/null)" ||
		die "no recorded worktree/branch preference in $ns/state/session.json -- run session-set first"
	worktree="$(printf '%s\n' "$session" | sed -n 's/^worktree\t//p')"
	branch_mode="$(printf '%s\n' "$session" | sed -n 's/^branch\t//p')"
	repo_root="${ns%/.claude/.radin}"
	branch="radin/$id"
	wt="$repo_root-$id"
	if [ "$worktree" = "yes" ]; then
		if [ -d "$wt" ]; then
			: # a dead attempt's tree -- reuse it rather than fail on `worktree add`
		elif git -C "$repo_root" rev-parse --verify --quiet "$branch" >/dev/null 2>&1; then
			git -C "$repo_root" worktree add "$wt" "$branch" >&2
		else
			git -C "$repo_root" worktree add "$wt" -b "$branch" >&2
		fi
		journal "$ns/state" "prepare" "$id" "worktree=$wt branch=$branch"
		printf '%s\n' "$wt"
	else
		if [ "$branch_mode" = "yes" ]; then
			if git -C "$repo_root" rev-parse --verify --quiet "$branch" >/dev/null 2>&1; then
				git -C "$repo_root" checkout "$branch" >&2
			else
				git -C "$repo_root" checkout -b "$branch" >&2
			fi
			journal "$ns/state" "prepare" "$id" "branch=$branch"
		else
			journal "$ns/state" "prepare" "$id" "current checkout, current branch"
		fi
		printf '%s\n' "$repo_root"
	fi
	;;

task-dir)
	repo_root="${2:-}"
	id="${3:-}"
	[ -n "$repo_root" ] && [ -n "$id" ] || die "usage: task-dir <repo-root> <id>"
	# Derived, never recorded: the execution prompt pins the worktree to this
	# path, so the tree a task's sub-agent worked in is findable from its id.
	if [ -d "$repo_root-$id" ]; then
		printf '%s\n' "$repo_root-$id"
	else
		printf '%s\n' "$repo_root"
	fi
	;;

dirty-check)
	dir="${2:-}"
	[ -n "$dir" ] || die "usage: dirty-check <dir>"
	git -C "$dir" status --porcelain -- . ':(exclude).claude/.radin'
	;;

stash)
	repo_root="${2:-}"
	msg="${3:-}"
	[ -n "$repo_root" ] && [ -n "$msg" ] || die "usage: stash <dir> <message>"
	before="$(git -C "$repo_root" stash list | grep -c . || true)"
	git -C "$repo_root" stash push -u -m "$msg" -- . ':(exclude).claude/.radin' >/dev/null
	after="$(git -C "$repo_root" stash list | grep -c . || true)"
	[ "$after" -gt "$before" ] || die "nothing to stash"
	journal "$repo_root/.claude/.radin/state" "stash" "" "$msg"
	printf 'stash@{0}\n'
	;;

session-set)
	ns="${2:-}"
	worktree="${3:-}"
	branch="${4:-}"
	[ -n "$ns" ] && [ -n "$worktree" ] && [ -n "$branch" ] || die "usage: session-set <namespace-dir> <yes|no> <yes|no>"
	[ -d "$ns/state" ] || die "no state dir: $ns/state"
	for mode in "$worktree" "$branch"; do
		case "$mode" in
		yes | no) ;;
		*) die "modes must be yes|no, got: $mode" ;;
		esac
	done
	printf '{"worktree":"%s","branch":"%s"}\n' "$worktree" "$branch" >"$ns/state/session.json"
	journal "$ns/state" "session" "" "worktree=$worktree branch=$branch"
	;;

session-get)
	ns="${2:-}"
	[ -n "$ns" ] || die "usage: session-get <namespace-dir>"
	file="$ns/state/session.json"
	[ -s "$file" ] || exit 1
	line="$(cat "$file")"
	printf 'worktree\t%s\nbranch\t%s\n' "$(json_get worktree "$line")" "$(json_get branch "$line")"
	;;

journal-tail)
	ns="${2:-}"
	n="${3:-20}"
	[ -n "$ns" ] || die "usage: journal-tail <namespace-dir> [n]"
	file="$ns/state/journal.jsonl"
	[ -s "$file" ] || exit 1
	tail -n "$n" "$file"
	;;

*)
	die "unknown command: ${cmd:-<none>} (steps-init|next-pending|start|stuck|triage|set-status|remove|deps-check|completed-add|completed-get|task-done|task-dir|dirty-check|stash|session-set|session-get|journal-tail)"
	;;
esac

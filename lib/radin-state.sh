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
#   radin-state.sh steps-init <steps-file> [<backlog-index>]  # write the file from "id<TAB>order<TAB>depends-on-csv<TAB>pending|deferred" lines on stdin
#                                                         # with an index, each entry's depends_on comes from its index line; the stdin csv is used only where the index has none
#                                                         # the fourth field is optional and defaults to pending; also writes state/baseline.json
#   radin-state.sh next-pending <steps-file>              # print lowest-order pending entry as "id<TAB>order<TAB>depends-on-csv", exit 1 if none
#   radin-state.sh task-next <namespace-dir>              # next-pending + deps-check + block-and-skip, in one call; exit 1 when nothing is left
#   radin-state.sh plan-wave <namespace-dir>              # print "plan<TAB><id>" per pending task that still needs a plan, lowest order first; exit 1 when none
#   radin-state.sh start <steps-file> <id>                # mark in_progress, bump attempts; exit 2 (entry set blocked) past MAX_ATTEMPTS
#   radin-state.sh stuck <steps-file>                     # print "id<TAB>attempts<TAB>note" per in_progress entry, exit 1 if none
#   radin-state.sh triage <namespace-dir> <id>            # print recovery facts for a task a dead session left in_progress
#   radin-state.sh recover <namespace-dir> <id>           # act on those facts; exit 3 prints commits only the model can judge
#   radin-state.sh recover-reject <namespace-dir> <id>    # those commits do not satisfy the task: block the entry naming them
#   radin-state.sh set-status <steps-file> <id> <pending|in_progress|failed|blocked> [note]
#   radin-state.sh remove <steps-file> <id>               # delete a completed entry's line
#   radin-state.sh deps-check <steps-file> <completed-file> <id>  # print "dep<TAB>hash" per dependency, exit 1 naming the first unresolved one
#   radin-state.sh completed-add <completed-file> <id> <commit-hash> [title]
#   radin-state.sh completed-get <completed-file> <id>   # prints commit hash, exit 1 if absent
#   radin-state.sh completed-list <completed-file>       # print "id<TAB>commit" per completion, exit 1 if none
#   radin-state.sh task-done <namespace-dir> <id> <commit-hash>  # completed-add + backlog remove + steps remove, in crash-safe order; exit 3 when the hash does not validate
#   radin-state.sh task-fail <namespace-dir> <id> <reason>        # exit 3 the first time (send the Debug prompt), mark failed the second
#   radin-state.sh task-fail <namespace-dir> <id> --no-status <last line>  # no debug pass, straight to failed
#   radin-state.sh task-diagnosis <namespace-dir> <id>   # stdin becomes a **Root cause:** line on the task file, status untouched
#   radin-state.sh dirty-recover <namespace-dir> <id> <status-word>  # stash + fail a sub-agent's dirty tree; exit 1 when it is clean
#   radin-state.sh report <namespace-dir> [<dropped-skill line>...]  # print the finished end-of-session report
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
	printf '%s' "$1" | sed -nE 's/.*"depends_on":\[([^]]*)\].*/\1/p' | tr -d '" '
}

# A task dispatched this many times without a terminal status is not
# crash-looping any further -- it gets blocked for the user instead.
MAX_ATTEMPTS=3

# Prints task $2's title from the backlog index under repo root $1, empty when
# the entry is already gone (a completed task's entry is deleted).
task_title() {
	(cd "$1" 2>/dev/null && bash "$LIB_DIR/radin-backlog.sh" find "$2" 2>/dev/null | head -n1 | cut -f3) || true
}

# Prints line $1's numeric field $2 (order|attempts|debugged), 0 when absent.
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
# $6 is the debugged flag; empty keeps whatever the entry already carries, so
# every other caller preserves it without knowing about it.
write_entry() {
	file="$1"
	id="$2"
	status="$3"
	attempts="$4"
	esc_note="$(json_escape "$5")"
	dbg="${6:-}"
	found=0
	while IFS= read -r line || [ -n "$line" ]; do
		[ -n "$line" ] || continue
		if [ "$(json_get id "$line")" = "$id" ]; then
			order="$(num_field "$line" order)"
			depends_on="$(printf '%s' "$line" | sed -E 's/.*"depends_on":(\[[^]]*\]).*/\1/')"
			[ -n "$dbg" ] || dbg="$(num_field "$line" debugged)"
			printf '{"id":"%s","order":%s,"status":"%s","depends_on":%s,"attempts":%s,"debugged":%s,"note":"%s"}\n' \
				"$(json_escape "$id")" "$order" "$status" "$depends_on" "$attempts" "$dbg" "$esc_note"
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
	[ -n "$file" ] || die "usage: steps-init <steps-file> [<backlog-index>]  (lines of id<TAB>order<TAB>depends-on-csv<TAB>pending|deferred on stdin)"
	index="${3:-}"
	[ -z "$index" ] || [ -f "$index" ] || die "no backlog index: $index"
	n=0
	: >"$file.tmp"
	TAB=$'\t'
	# Split by hand rather than with IFS=$'\t' read: tab is an IFS whitespace
	# character, so `read` collapses the run of tabs an empty deps field
	# leaves and the fourth field lands in the third variable.
	while IFS= read -r raw || [ -n "${raw:-}" ]; do
		[ -n "$raw" ] || continue
		padded="$raw$TAB$TAB$TAB"
		id="${padded%%"$TAB"*}"
		rest="${padded#*"$TAB"}"
		order="${rest%%"$TAB"*}"
		rest="${rest#*"$TAB"}"
		deps="${rest%%"$TAB"*}"
		rest="${rest#*"$TAB"}"
		entry_status="${rest%%"$TAB"*}"
		case "$order" in
		'' | *[!0-9]*)
			rm -f "$file.tmp"
			die "bad order for '$id': ${order:-<empty>}"
			;;
		esac
		entry_status="${entry_status:-pending}"
		case "$entry_status" in
		pending | deferred) ;;
		*)
			rm -f "$file.tmp"
			die "bad status for '$id': $entry_status (pending|deferred)"
			;;
		esac
		deps_json="[]"
		if [ -n "$index" ]; then
			iline="$(grep -F "\"id\":\"$id\"" "$index" | head -n1 || true)"
			idx_deps="$(deps_csv "$iline")"
			[ -z "$idx_deps" ] || deps="$idx_deps"
		fi
		deps="$(printf '%s' "${deps:-}" | tr -d ' ')"
		[ -z "$deps" ] || deps_json="[$(printf '%s' "$deps" | sed -E 's/([^,]+)/"\1"/g')]"
		printf '{"id":"%s","order":%s,"status":"%s","depends_on":%s,"attempts":0,"debugged":0,"note":""}\n' \
			"$(json_escape "$id")" "$order" "$entry_status" "$deps_json" >>"$file.tmp"
		n=$((n + 1))
	done
	[ "$n" -gt 0 ] || {
		rm -f "$file.tmp"
		die "no entries on stdin"
	}
	mv "$file.tmp" "$file"
	# The session baseline, so `report` can scope "this session" without the
	# orchestrator carrying counts across phases.
	state_dir="$(dirname "$file")"
	if [ -d "$state_dir" ]; then
		repo_root="${state_dir%/state}"
		repo_root="${repo_root%/.claude/.radin}"
		backlog_count="$( (cd "$repo_root" 2>/dev/null && bash "$LIB_DIR/radin-backlog.sh" count 2>/dev/null) || printf '0')"
		completed_count="$(grep -c . "$state_dir/completed.json" 2>/dev/null || true)"
		printf '{"backlog_count":%s,"completed_count":%s}\n' \
			"${backlog_count:-0}" "${completed_count:-0}" >"$state_dir/baseline.json"
	fi
	journal "$state_dir" "steps-init" "" "$n entries"
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
	title="${5:-}"
	[ -n "$file" ] && [ -n "$id" ] && [ -n "$hash" ] || die "usage: completed-add <completed-file> <id> <commit-hash> [title]"
	# The title is stored because completion deletes the backlog entry, so the
	# final report has nowhere else to read it from. completed-list still
	# prints two fields: radin tui parses that output.
	printf '{"id":"%s","commit":"%s","title":"%s"}\n' \
		"$(json_escape "$id")" "$(json_escape "$hash")" "$(json_escape "$title")" >>"$file"
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

completed-list)
	file="${2:-}"
	[ -n "$file" ] || die "usage: completed-list <completed-file>"
	[ -s "$file" ] || exit 1
	while IFS= read -r line || [ -n "$line" ]; do
		[ -n "$line" ] || continue
		printf '%s\t%s\n' "$(json_get id "$line")" "$(json_get commit "$line")"
	done <"$file"
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
	# The hash is free text off a sub-agent's STATUS: line, so validate it
	# before any bookkeeping believes it. Exit 3, not the generic die, so the
	# caller can route it as a failure instead of a CLI misuse.
	dir="$(bash "$LIB_DIR/radin-state.sh" task-dir "$repo_root" "$id")"
	if ! git -C "$dir" rev-parse --verify --quiet "$hash^{commit}" >/dev/null 2>&1; then
		printf 'task-done: %s is not a commit in %s\n' "$hash" "$dir" >&2
		exit 3
	fi
	ref="HEAD"
	if git -C "$dir" rev-parse --verify --quiet "radin/$id" >/dev/null 2>&1; then
		ref="radin/$id"
	fi
	if ! git -C "$dir" merge-base --is-ancestor "$hash" "$ref" >/dev/null 2>&1; then
		printf 'task-done: %s is not reachable from %s in %s\n' "$hash" "$ref" "$dir" >&2
		exit 3
	fi
	# Resolved before the backlog entry goes away: nothing else records it.
	title="$(task_title "$repo_root" "$id")"
	# Order matters: record success first, so a crash mid-way leaves a state
	# radin-backlog.sh reconcile can repair. Each step is skipped when a
	# retry already did it, so re-running after a crash is safe.
	if ! bash "$LIB_DIR/radin-state.sh" completed-get "$completed" "$id" >/dev/null 2>&1; then
		bash "$LIB_DIR/radin-state.sh" completed-add "$completed" "$id" "$hash" "$title"
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

task-next)
	# next-pending + deps-check + the block-and-skip route, so the picker is
	# one call and the orchestrator filters nothing.
	ns="${2:-}"
	[ -n "$ns" ] || die "usage: task-next <namespace-dir>"
	[ -d "$ns" ] || die "no namespace dir: $ns"
	steps="$ns/state/BACKLOG_STEPS.json"
	completed="$ns/state/completed.json"
	errfile="$(mktemp)"
	trap 'rm -f "$errfile"' EXIT
	while :; do
		pick="$(bash "$LIB_DIR/radin-state.sh" next-pending "$steps")" || exit 1
		pid="$(printf '%s' "$pick" | cut -f1)"
		order="$(printf '%s' "$pick" | cut -f2)"
		if deps="$(bash "$LIB_DIR/radin-state.sh" deps-check "$steps" "$completed" "$pid" 2>"$errfile")"; then
			printf 'id\t%s\norder\t%s\n' "$pid" "$order"
			[ -z "$deps" ] || printf '%s\n' "$deps" | sed 's/^/dep\t/'
			exit 0
		fi
		msg="$(sed -e 's/^radin-state: //' "$errfile" | sed -n '1p')"
		bash "$LIB_DIR/radin-state.sh" set-status "$steps" "$pid" blocked "$msg"
		printf 'blocked\t%s\t%s\n' "$pid" "$msg"
		# Every iteration moves one entry out of pending, so this terminates.
	done
	;;

plan-wave)
	# Every pending task that still needs a plan, in one call: the router
	# dispatches one planning sub-agent per printed line, in one message, and
	# joins nothing itself. No dependency gate on purpose -- planning is
	# read-only, and at this point no dependency has committed yet, so gating
	# would push every dependent task back into the per-task loop and defeat
	# the wave.
	ns="${2:-}"
	[ -n "$ns" ] || die "usage: plan-wave <namespace-dir>"
	[ -d "$ns" ] || die "no namespace dir: $ns"
	steps="$ns/state/BACKLOG_STEPS.json"
	[ -f "$steps" ] || exit 1
	repo_root="${ns%/.claude/.radin}"
	# One `list --planned` call is both membership tests at once: a 7th field
	# of `P` means planned, and an id missing from the output has left the
	# backlog (Step 4a's `field TASK_FILE` owns that drift case).
	unplanned="$( (cd "$repo_root" 2>/dev/null &&
		bash "$LIB_DIR/radin-backlog.sh" list --planned 2>/dev/null) |
		awk -F'\037' 'NF > 1 && $7 == "" { print $1 }')"
	out="$(while IFS= read -r line || [ -n "$line" ]; do
		[ -n "$line" ] || continue
		[ "$(json_get status "$line")" = "pending" ] || continue
		id="$(json_get id "$line")"
		printf '%s\n' "$unplanned" | grep -qxF "$id" || continue
		printf '%s\t%s\n' "$(num_field "$line" order)" "$id"
	done <"$steps" | sort -n | awk '{ print "plan\t" $2 }')"
	[ -n "$out" ] || exit 1
	printf '%s\n' "$out"
	;;

task-fail)
	ns="${2:-}"
	id="${3:-}"
	third="${4:-}"
	[ -n "$ns" ] && [ -n "$id" ] && [ -n "$third" ] ||
		die "usage: task-fail <namespace-dir> <id> <reason>  |  task-fail <namespace-dir> <id> --no-status <last line>"
	[ -d "$ns" ] || die "no namespace dir: $ns"
	repo_root="${ns%/.claude/.radin}"
	steps="$ns/state/BACKLOG_STEPS.json"
	entry="$(entry_line "$steps" "$id")"
	[ -n "$entry" ] || die "no entry with id: $id"
	order="$(num_field "$entry" order)"
	title="$(task_title "$repo_root" "$id")"
	[ -n "$title" ] || title="$id"
	if [ "$third" = "--no-status" ]; then
		# No debug pass ever: there is no failure reason to debug against.
		last="${5:-}"
		note="sub-agent returned no STATUS line, likely an interactive skill or a spawned background task; last words: $last"
		bash "$LIB_DIR/radin-state.sh" set-status "$steps" "$id" failed "$note"
		printf "❌ Task %s '%s' failed: %s. Continuing to next task.\n" \
			"$order" "$title" "sub-agent returned no STATUS line"
		exit 0
	fi
	reason="$third"
	if [ "$(num_field "$entry" debugged)" -eq 0 ]; then
		# One debug pass per task per session, and the flag is what enforces
		# it -- a counter the model holds cannot survive a resume.
		write_entry "$steps" "$id" "$(json_get status "$entry")" \
			"$(num_field "$entry" attempts)" "$(json_get note "$entry")" 1
		journal "$ns/state" "debug" "$id" "$reason"
		printf 'debug\t%s\n' "$reason"
		exit 3
	fi
	note="$reason"
	if grep -qF "\"event\":\"diagnosis\",\"id\":\"$id\"" "$ns/state/journal.jsonl" 2>/dev/null; then
		note="$reason (a diagnosis was recorded on the task file under **Root cause:**)"
	fi
	bash "$LIB_DIR/radin-state.sh" set-status "$steps" "$id" failed "$note"
	printf "❌ Task %s '%s' failed: %s. Continuing to next task.\n" "$order" "$title" "$reason"
	;;

task-diagnosis)
	ns="${2:-}"
	id="${3:-}"
	[ -n "$ns" ] && [ -n "$id" ] || die "usage: task-diagnosis <namespace-dir> <id>  (diagnosis text on stdin)"
	[ -d "$ns" ] || die "no namespace dir: $ns"
	repo_root="${ns%/.claude/.radin}"
	text="$(cat)"
	[ -n "$text" ] || die "diagnosis text is empty (pass it on stdin)"
	# The only place the **Root cause:** label is written. Status is left
	# alone: the entry is still in_progress, and the retry's `start` bumps
	# attempts, so MAX_ATTEMPTS still ends the loop.
	printf '**Root cause:** %s\n' "$text" |
		(cd "$repo_root" && bash "$LIB_DIR/radin-backlog.sh" append "$id" >/dev/null)
	journal "$ns/state" "diagnosis" "$id" "$text"
	printf 'task-diagnosis: recorded on %s\n' "$id"
	;;

dirty-recover)
	ns="${2:-}"
	id="${3:-}"
	status_word="${4:-}"
	[ -n "$ns" ] && [ -n "$id" ] && [ -n "$status_word" ] ||
		die "usage: dirty-recover <namespace-dir> <id> <status-word>"
	[ -d "$ns" ] || die "no namespace dir: $ns"
	repo_root="${ns%/.claude/.radin}"
	steps="$ns/state/BACKLOG_STEPS.json"
	dir="$(bash "$LIB_DIR/radin-state.sh" task-dir "$repo_root" "$id")"
	# In worktree mode the repo root is not the tree the sub-agent worked in,
	# so task-dir decides which one gets checked.
	[ -n "$(bash "$LIB_DIR/radin-state.sh" dirty-check "$dir")" ] || exit 1
	entry="$(entry_line "$steps" "$id")"
	order="$(num_field "${entry:-}" order)"
	title="$(task_title "$repo_root" "$id")"
	[ -n "$title" ] || title="$id"
	ref="$(bash "$LIB_DIR/radin-state.sh" stash "$dir" \
		"radin-execute: task $order '$title' left uncommitted (sub-agent reported $status_word)")"
	bash "$LIB_DIR/radin-state.sh" set-status "$steps" "$id" failed \
		"sub-agent left uncommitted changes in $dir, stashed as $ref. Run 'git -C $dir stash show -p $ref' to inspect, 'git -C $dir stash pop' to recover."
	journal "$ns/state" "stash" "$id" \
		"$ref in $dir -- task $order '$title' left uncommitted. Recover: git -C $dir stash pop"
	printf "⚠️ Task %s '%s': sub-agent reported %s but left a dirty tree. Stashed as %s, treated as failed.\n" \
		"$order" "$title" "$status_word" "$ref"
	;;

recover)
	ns="${2:-}"
	id="${3:-}"
	[ -n "$ns" ] && [ -n "$id" ] || die "usage: recover <namespace-dir> <id>"
	[ -d "$ns" ] || die "no namespace dir: $ns"
	repo_root="${ns%/.claude/.radin}"
	steps="$ns/state/BACKLOG_STEPS.json"
	facts="$(bash "$LIB_DIR/radin-state.sh" triage "$ns" "$id")"
	hash="$(printf '%s\n' "$facts" | sed -n 's/^completed	//p')"
	if [ -n "$hash" ] && [ "$hash" != "none" ]; then
		bash "$LIB_DIR/radin-state.sh" task-done "$ns" "$id" "$hash" >/dev/null
		printf 'recovered\t%s\tbookkeeping completed at %s\n' "$id" "$hash"
		exit 0
	fi
	if printf '%s\n' "$facts" | grep -q '^branch_commit	'; then
		# The one branch no verb can settle: only the model can say whether
		# these commits satisfy the task. It answers with task-done or
		# recover-reject.
		printf '%s\n' "$facts" | grep -E '^(branch|worktree|branch_commit)	'
		exit 3
	fi
	dir="$(bash "$LIB_DIR/radin-state.sh" task-dir "$repo_root" "$id")"
	if [ "$(printf '%s\n' "$facts" | sed -n 's/^dirty_files	//p')" = "0" ]; then
		bash "$LIB_DIR/radin-state.sh" set-status "$steps" "$id" pending ""
		printf 'recovered\t%s\tnothing left behind, back to pending\n' "$id"
		exit 0
	fi
	ref="$(bash "$LIB_DIR/radin-state.sh" stash "$dir" "radin-execute: crash recovery for task $id")"
	bash "$LIB_DIR/radin-state.sh" set-status "$steps" "$id" pending \
		"tree stashed as $ref in $dir before retry"
	journal "$ns/state" "stash" "$id" \
		"$ref in $dir -- crash recovery for task $id. Recover: git -C $dir stash pop"
	printf 'recovered\t%s\tstashed %s, back to pending\n' "$id" "$ref"
	;;

recover-reject)
	ns="${2:-}"
	id="${3:-}"
	[ -n "$ns" ] && [ -n "$id" ] || die "usage: recover-reject <namespace-dir> <id>"
	[ -d "$ns" ] || die "no namespace dir: $ns"
	repo_root="${ns%/.claude/.radin}"
	steps="$ns/state/BACKLOG_STEPS.json"
	dir="$(bash "$LIB_DIR/radin-state.sh" task-dir "$repo_root" "$id")"
	note="a dead session left commits on radin/$id that do not satisfy the task -- inspect them before retrying"
	if [ "$dir" != "$repo_root" ]; then
		note="a dead session left commits on radin/$id (worktree $dir) that do not satisfy the task -- inspect them before retrying"
	fi
	bash "$LIB_DIR/radin-state.sh" set-status "$steps" "$id" blocked "$note"
	printf 'blocked\t%s\t%s\n' "$id" "$note"
	;;

report)
	ns="${2:-}"
	[ -n "$ns" ] || die "usage: report <namespace-dir> [<dropped-skill line>...]"
	[ -d "$ns" ] || die "no namespace dir: $ns"
	shift 2
	repo_root="${ns%/.claude/.radin}"
	state_dir="$ns/state"
	steps="$state_dir/BACKLOG_STEPS.json"
	completed="$state_dir/completed.json"
	worktree_mode="no"
	branch_mode="no"
	if session="$(bash "$LIB_DIR/radin-state.sh" session-get "$ns" 2>/dev/null)"; then
		worktree_mode="$(printf '%s\n' "$session" | sed -n 's/^worktree	//p')"
		branch_mode="$(printf '%s\n' "$session" | sed -n 's/^branch	//p')"
	fi
	base_completed=0
	base_backlog=""
	if [ -s "$state_dir/baseline.json" ]; then
		baseline="$(cat "$state_dir/baseline.json")"
		base_completed="$(num_field "$baseline" completed_count)"
		base_backlog="$(num_field "$baseline" backlog_count)"
	fi

	# Stashes of this session: every stash event since the last steps-init.
	# Reporting only -- no control flow reads the journal.
	stash_block=""
	if [ -s "$state_dir/journal.jsonl" ]; then
		from="$(grep -n '"event":"steps-init"' "$state_dir/journal.jsonl" | tail -n1 | cut -d: -f1)"
		stash_block="$(tail -n "+${from:-1}" "$state_dir/journal.jsonl" |
			sed -nE 's/.*"event":"stash","id":"[^"]+","detail":"(.*)"\}$/- \1/p')"
	fi

	# Residual changes: never committed, parked instead. The user's call.
	residual="no residual changes"
	if [ -n "$(git -C "$repo_root" status --porcelain -- . ':(exclude).claude/.radin' 2>/dev/null)" ]; then
		ref="$(bash "$LIB_DIR/radin-state.sh" stash "$repo_root" "radin-execute: session end, untracked to any task")"
		residual="residual changes stashed as $ref"
		stash_block="${stash_block:+$stash_block$'\n'}- $ref in $repo_root -- session end, untracked to any task. Recover: git -C $repo_root stash pop"
	fi

	succeeded=""
	n_ok=0
	if [ -s "$completed" ]; then
		while IFS= read -r line || [ -n "$line" ]; do
			[ -n "$line" ] || continue
			n_ok=$((n_ok + 1))
			[ "$n_ok" -gt "$base_completed" ] || continue
			cid="$(json_get id "$line")"
			chash="$(json_get commit "$line")"
			ctitle="$(json_get title "$line")"
			[ -n "$ctitle" ] || ctitle="$cid"
			if [ "$worktree_mode" = "yes" ] || [ "$branch_mode" = "yes" ]; then
				where=""
				[ ! -d "$repo_root-$cid" ] || where=" in $repo_root-$cid"
				succeeded="$(printf '%s\n- %s — %s on radin/%s%s. Merge: git merge radin/%s' \
					"$succeeded" "$ctitle" "$chash" "$cid" "$where" "$cid")"
			else
				succeeded="$(printf '%s\n- %s — %s' "$succeeded" "$ctitle" "$chash")"
			fi
		done <"$completed"
	fi
	n_ok=$((n_ok - base_completed))
	[ "$n_ok" -ge 0 ] || n_ok=0

	failed=""
	blocked=""
	deferred=""
	n_failed=0
	n_blocked=0
	if [ -f "$steps" ]; then
		while IFS= read -r line || [ -n "$line" ]; do
			[ -n "$line" ] || continue
			eid="$(json_get id "$line")"
			etitle="$(task_title "$repo_root" "$eid")"
			[ -n "$etitle" ] || etitle="$eid"
			case "$(json_get status "$line")" in
			failed)
				n_failed=$((n_failed + 1))
				failed="$(printf '%s\n- %s — %s' "$failed" "$etitle" "$(json_get note "$line")")"
				;;
			blocked)
				n_blocked=$((n_blocked + 1))
				blocked="$(printf '%s\n- %s — %s' "$blocked" "$etitle" "$(json_get note "$line")")"
				;;
			deferred)
				deferred="$(printf '%s\n- %s' "$deferred" "$etitle")"
				;;
			esac
		done <"$steps"
	fi

	printf '✅ Session complete: %d succeeded, %d failed, %d awaiting your decision.\n' \
		"$n_ok" "$n_failed" "$n_blocked"
	if [ -n "$base_backlog" ]; then
		now="$( (cd "$repo_root" 2>/dev/null && bash "$LIB_DIR/radin-backlog.sh" count 2>/dev/null) || printf '0')"
		added=$((now - base_backlog + n_ok))
		[ "$added" -ge 0 ] || added=0
		printf 'Net-new backlog entries this session: %d. Nothing verified these commits yet -- /radin-review is that pass.\n' "$added"
	fi
	printf '%s.\n' "$residual"
	[ -z "$succeeded" ] || printf '\nSucceeded:%s\n' "$succeeded"
	[ -z "$failed" ] || printf '\nFailed (left in the backlog for retry):%s\n' "$failed"
	[ -z "$blocked" ] || printf '\nNeeds your decision (left in the backlog, nothing implemented):%s\n' "$blocked"
	[ -z "$deferred" ] || printf '\nDeferred at your request (left in the backlog):%s\n' "$deferred"
	[ -z "$stash_block" ] || printf '\nStashes created this session:\n%s\n' "$stash_block"
	if [ "$#" -gt 0 ]; then
		printf '\nSkills dropped as unrunnable by a sub-agent (run them yourself):\n'
		for dropped in "$@"; do
			printf -- '- %s\n' "$dropped"
		done
	fi
	;;

*)
	die "unknown command: ${cmd:-<none>} (steps-init|next-pending|task-next|plan-wave|start|stuck|triage|recover|recover-reject|set-status|remove|deps-check|completed-add|completed-get|completed-list|task-done|task-fail|task-diagnosis|dirty-recover|report|task-dir|prepare|dirty-check|stash|session-set|session-get|journal-tail)"
	;;
esac

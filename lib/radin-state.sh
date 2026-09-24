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
# Every verb resolves the namespace from the current directory, a linked
# worktree included (lib/radin-namespace.sh), so no caller passes a path.
#
# Usage:
#   radin-state.sh steps-init                   # write BACKLOG_STEPS.json from "id<TAB>order<TAB>depends-on-csv<TAB>pending|deferred" lines on stdin
#                                               # each entry's depends_on comes from its index line; the stdin csv is used only where the index has none
#                                               # the fourth field is optional and defaults to pending; also writes state/baseline.json
#   radin-state.sh task-next [--plan-first] [<id>]  # pick, gate, claim and write the prompt in one call; exit 1 when nothing is left
#   radin-state.sh task-report <id> <the sub-agent's STATUS: line>  # verify the tree, record the outcome, then a final "next<TAB>continue|debug|clarify FACT|clarify DECISION" line
#   radin-state.sh task-report <id> --no-status <last line>         # the same, for a sub-agent that ended with no STATUS: line
#   radin-state.sh task-diagnosis <id>          # stdin becomes a **Root cause:** line on the task file, status untouched
#   radin-state.sh task-done <id> <commit-hash> # record completion, remove backlog and steps entries, in crash-safe order; exit 3 when the hash does not validate
#   radin-state.sh set-status <id> <pending|in_progress|failed|blocked> [note]
#   radin-state.sh stuck                        # print "id<TAB>attempts<TAB>note" per in_progress entry, exit 1 if none
#   radin-state.sh recover <id>                 # recover a task a dead session left in_progress; exit 3 prints commits only the model can judge
#   radin-state.sh recover-reject <id>          # those commits do not satisfy the task: block the entry naming them
#   radin-state.sh report                       # print the finished end-of-session report
#   radin-state.sh session-set <yes|no> <yes|no>  # persist the worktree and branch answers
#   radin-state.sh session-get                  # print "worktree<TAB>yes" / "branch<TAB>no", exit 1 if unanswered
#   radin-state.sh prepare <id>                 # create/reuse the task's tree and branch per session.json, print the dir to work in
#                                               # also records the branch and tree it chose in state/prepared/<id>.json
#   radin-state.sh dirty-check                  # git status --porcelain of the current directory, excluding .claude/.radin
#   radin-state.sh trace <id|commit|branch>     # print "task|commit|branch|worktree|plan|facts|status<TAB>value" per matching task; exit 1 no match, 2 ambiguous
#   radin-state.sh completed-show <id>          # print "id|commit|title|branch|worktree|plan|ts<TAB>value" lines, exit 1 if absent
#   radin-state.sh completed-list               # print "id<TAB>commit" per completion, exit 1 if none (the TUI's Done view)
#   radin-state.sh deps-check <id>              # print "dep<TAB>hash" per dependency, exit 1 naming the first unresolved one (radin-prompt.sh)
#   radin-state.sh task-dir <id>                # print the task's worktree if it exists, else the repo root (radin-prompt.sh)
#   radin-state.sh journal-tail [n]             # last n journal events (default 20)
#
# Every mutation also appends one event to <state-dir>/journal.jsonl. The
# journal is append-only forensics: it survives context compaction and a
# killed session, and nothing reads it for control flow; `trace` reads it
# for reporting.
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
# shellcheck disable=SC1091
. "$LIB_DIR/radin-namespace.sh"
ns="$NAMESPACE_DIR"
# shellcheck disable=SC2153  # set by radin-namespace.sh
repo_root="$REPO_ROOT"
steps="$ns/state/BACKLOG_STEPS.json"
completed="$ns/state/completed.json"

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

# Prints task $2's plan pointers from the backlog index under repo root $1,
# joined by commas in pointer order; empty when the entry has none or is gone.
task_plans() {
	(cd "$1" 2>/dev/null && bash "$LIB_DIR/radin-backlog.sh" meta "$2" 2>/dev/null |
		sed -n 's/^plan	//p' | paste -sd, -) || true
}

# Prints key $3 of the record `prepare` wrote for task $2 under namespace dir
# $1, empty when nothing was recorded (a task prepared before this existed).
prepared_field() {
	file="$1/state/prepared/$2.json"
	[ -s "$file" ] || return 0
	json_get "$3" "$(cat "$file")"
}

# Prints the last status word namespace dir $1's journal recorded for task $2,
# empty when it recorded none. Reporting only: no caller branches on it.
trace_status() {
	f="$1/state/journal.jsonl"
	[ -s "$f" ] || return 0
	{ grep -F "\"id\":\"$(json_escape "$2")\"" "$f" || true; } |
		sed -nE 's/.*"event":"(pending|in_progress|failed|blocked)".*/\1/p' |
		tail -n1
}

# Prints the seven fixed TAB lines `trace` reports for one task: id $2, commit
# $3, branch $4, worktree $5, plan $6, status $7, with `facts` resolved from
# namespace dir $1. An unknown value prints as an empty one, so the block is
# always seven lines and `task` is always the first.
trace_block() {
	facts="$1/state/facts/$2.md"
	[ -f "$facts" ] || facts=""
	printf 'task\t%s\ncommit\t%s\nbranch\t%s\nworktree\t%s\nplan\t%s\nfacts\t%s\nstatus\t%s\n' \
		"$2" "$3" "$4" "$5" "$6" "$facts" "$7"
}

# Prints line $1's numeric field $2 (order|attempts|debugged), 0 when absent.
num_field() {
	local v
	v="$(printf '%s' "$1" | sed -nE "s/.*\"$2\":([0-9]+).*/\1/p")"
	printf '%s' "${v:-0}"
}

journal() {
	[ -d "$1" ] || return 0
	printf '{"ts":"%s","event":"%s","id":"%s","detail":"%s"}\n' \
		"$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(json_escape "$2")" \
		"$(json_escape "$3")" "$(json_escape "${4:-}")" >>"$1/journal.jsonl"
}

# Rewrites entry $2 in steps-file $1 with status $3, attempts $4, note $5.
# $6 is the debugged flag; empty keeps whatever the entry already carries, so
# every other caller preserves it without knowing about it.
write_entry() {
	local file="$1" id="$2" status="$3" attempts="$4" dbg="${6:-}" found=0
	local esc_note line order depends_on
	esc_note="$(json_escape "$5")"
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
	local line
	while IFS= read -r line || [ -n "$line" ]; do
		[ -n "$line" ] || continue
		if [ "$(json_get id "$line")" = "$2" ]; then
			printf '%s' "$line"
		fi
	done <"$1"
	return 0
}

# Sets task $1's status $2 with note $3, keeping its attempts.
set_status() {
	local entry
	entry="$(entry_line "$steps" "$1")"
	[ -n "$entry" ] || die "no entry with id: $1"
	write_entry "$steps" "$1" "$2" "$(num_field "$entry" attempts)" "${3:-}"
}

# Prints the lowest-order pending entry as "id<TAB>order", returns 1 if none.
next_pending() {
	local line order best_line="" best_order=""
	[ -f "$steps" ] || return 1
	while IFS= read -r line || [ -n "$line" ]; do
		[ -n "$line" ] || continue
		[ "$(json_get status "$line")" = "pending" ] || continue
		order="$(num_field "$line" order)"
		if [ -z "$best_order" ] || [ "$order" -lt "$best_order" ]; then
			best_order="$order"
			best_line="$line"
		fi
	done <"$steps"
	[ -n "$best_line" ] || return 1
	printf '%s\t%s\n' "$(json_get id "$best_line")" "$best_order"
}

# Claims task $1: in_progress, attempts bumped. Returns 2, with the entry
# marked blocked, once it passes MAX_ATTEMPTS.
claim() {
	local entry attempts
	entry="$(entry_line "$steps" "$1")"
	[ -n "$entry" ] || die "no entry with id: $1"
	attempts=$(($(num_field "$entry" attempts) + 1))
	if [ "$attempts" -gt "$MAX_ATTEMPTS" ]; then
		write_entry "$steps" "$1" "blocked" "$((attempts - 1))" "dispatched $MAX_ATTEMPTS times without a terminal status (MAX_ATTEMPTS) -- needs a human look before another retry"
		return 2
	fi
	write_entry "$steps" "$1" "in_progress" "$attempts" ""
}

# Prints task $1's recorded commit hash, returns 1 if it has none.
completed_get() {
	local line
	[ -f "$completed" ] || return 1
	while IFS= read -r line || [ -n "$line" ]; do
		[ -n "$line" ] || continue
		if [ "$(json_get id "$line")" = "$1" ]; then
			json_get commit "$line"
			return 0
		fi
	done <"$completed"
	return 1
}

# Prints the tree task $1's sub-agent worked in: its worktree if one exists,
# else the repo root. Derived, never recorded: the execution prompt pins the
# worktree to this path.
task_dir() {
	if [ -d "$repo_root-$1" ]; then
		printf '%s\n' "$repo_root-$1"
	else
		printf '%s\n' "$repo_root"
	fi
}

dirty_files() {
	git -C "$1" status --porcelain -- . ':(exclude).claude/.radin'
}

# Stashes everything in tree $1 except .claude/.radin under message $2, prints
# the stash ref.
stash_tree() {
	local before after
	before="$(git -C "$1" stash list | grep -c . || true)"
	git -C "$1" stash push -u -m "$2" -- . ':(exclude).claude/.radin' >/dev/null
	after="$(git -C "$1" stash list | grep -c . || true)"
	[ "$after" -gt "$before" ] || die "nothing to stash"
	printf 'stash@{0}\n'
}

# Prints task $1's order and title, TAB-separated, the id standing in for a
# title the backlog no longer has.
order_title() {
	local entry title
	entry="$(entry_line "$steps" "$1")"
	title="$(task_title "$repo_root" "$1")"
	printf '%s\t%s' "$(num_field "${entry:-}" order)" "${title:-$1}"
}

# The FAILED route for task $1 with reason $2. Returns 3 the first time, the
# caller's signal to send the debug prompt; marks the task failed after that.
task_fail() {
	local entry ot note
	entry="$(entry_line "$steps" "$1")"
	[ -n "$entry" ] || die "no entry with id: $1"
	ot="$(order_title "$1")"
	if [ "$(num_field "$entry" debugged)" -eq 0 ]; then
		# One debug pass per task per session, and the flag is what enforces
		# it -- a counter the model holds cannot survive a resume.
		write_entry "$steps" "$1" "$(json_get status "$entry")" \
			"$(num_field "$entry" attempts)" "$(json_get note "$entry")" 1
		journal "$ns/state" "debug" "$1" "$2"
		return 3
	fi
	note="$2"
	if grep -qF "\"event\":\"diagnosis\",\"id\":\"$1\"" "$ns/state/journal.jsonl" 2>/dev/null; then
		note="$2 (a diagnosis was recorded on the task file under **Root cause:**)"
	fi
	write_entry "$steps" "$1" failed "$(num_field "$entry" attempts)" "$note"
	printf "❌ Task %s '%s' failed: %s. Continuing to next task.\n" "${ot%%	*}" "${ot#*	}" "$2"
}

# Stashes and fails task $1 when its tree is dirty, whatever status word $2
# the sub-agent reported. Returns 1 when the tree is clean.
dirty_recover() {
	local dir ot order title ref entry
	dir="$(task_dir "$1")"
	[ -n "$(dirty_files "$dir")" ] || return 1
	ot="$(order_title "$1")"
	order="${ot%%	*}"
	title="${ot#*	}"
	ref="$(stash_tree "$dir" "radin-execute: task $order '$title' left uncommitted (sub-agent reported $2)")"
	entry="$(entry_line "$steps" "$1")"
	write_entry "$steps" "$1" failed "$(num_field "$entry" attempts)" \
		"sub-agent left uncommitted changes in $dir, stashed as $ref. Run 'git -C $dir stash show -p $ref' to inspect, 'git -C $dir stash pop' to recover."
	journal "$ns/state" "stash" "$1" \
		"$ref in $dir -- task $order '$title' left uncommitted. Recover: git -C $dir stash pop"
	printf "⚠️ Task %s '%s': sub-agent reported %s but left a dirty tree. Stashed as %s, treated as failed.\n" \
		"$order" "$title" "$2" "$ref"
}

# Prints "dep<TAB>hash" per dependency of task $1. Returns 1, naming the first
# unresolved one on stderr.
deps_check() {
	local entry deps dep hash dep_line dep_status old_ifs
	entry="$(entry_line "$steps" "$1")"
	[ -n "$entry" ] || die "no entry with id: $1"
	deps="$(deps_csv "$entry")"
	[ -n "$deps" ] || return 0
	old_ifs="$IFS"
	IFS=','
	# Splitting the csv into positional params is the point here.
	# shellcheck disable=SC2086
	set -- "$1" $deps
	IFS="$old_ifs"
	local id="$1"
	shift
	for dep in "$@"; do
		[ -n "$dep" ] || continue
		if hash="$(completed_get "$dep")"; then
			printf '%s\t%s\n' "$dep" "$hash"
		else
			dep_status="missing from $steps"
			dep_line="$(entry_line "$steps" "$dep")"
			[ -z "$dep_line" ] || dep_status="$(json_get status "$dep_line")"
			printf "task '%s' waiting on dependency '%s', which is %s\n" "$id" "$dep" "$dep_status" >&2
			return 1
		fi
	done
}

cmd="${1:-}"
case "$cmd" in
steps-init)
	file="$steps"
	index="$BACKLOG_INDEX"
	[ -f "$index" ] || index=""
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
	state_dir="$ns/state"
	if [ -d "$state_dir" ]; then
		backlog_count="$( (cd "$repo_root" 2>/dev/null && bash "$LIB_DIR/radin-backlog.sh" count 2>/dev/null) || printf '0')"
		completed_count="$(grep -c . "$state_dir/completed.json" 2>/dev/null || true)"
		printf '{"backlog_count":%s,"completed_count":%s}\n' \
			"${backlog_count:-0}" "${completed_count:-0}" >"$state_dir/baseline.json"
	fi
	journal "$state_dir" "steps-init" "" "$n entries"
	printf 'steps-init: wrote %d entries to %s\n' "$n" "$file"
	;;

deps-check)
	id="${2:-}"
	[ -n "$id" ] || die "usage: deps-check <id>"
	[ -f "$steps" ] || die "no state file: $steps"
	deps_check "$id" 2>"$ns/state/.deps-err" || die "$(cat "$ns/state/.deps-err")"
	;;

set-status)
	file="$steps"
	id="${2:-}"
	status="${3:-}"
	note="${4:-}"
	[ -n "$id" ] && [ -n "$status" ] || die "usage: set-status <id> <pending|in_progress|failed|blocked> [note]"
	[ -f "$file" ] || die "no state file: $file"
	case "$status" in
	pending | in_progress | failed | blocked) ;;
	*) die "status must be pending|in_progress|failed|blocked, got: $status" ;;
	esac
	entry="$(entry_line "$file" "$id")"
	[ -n "$entry" ] || die "no entry with id: $id"
	write_entry "$file" "$id" "$status" "$(num_field "$entry" attempts)" "$note"
	;;

stuck)
	file="$steps"
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

completed-show)
	file="$completed"
	id="${2:-}"
	[ -n "$id" ] || die "usage: completed-show <id>"
	[ -f "$file" ] || exit 1
	while IFS= read -r line || [ -n "$line" ]; do
		[ -n "$line" ] || continue
		if [ "$(json_get id "$line")" = "$id" ]; then
			# A line written before provenance existed has no branch, worktree,
			# plan or ts key: json_get prints nothing, which reads as unknown.
			for key in id commit title branch worktree plan ts; do
				printf '%s\t%s\n' "$key" "$(json_get "$key" "$line")"
			done
			exit 0
		fi
	done <"$file"
	exit 1
	;;

completed-list)
	file="$completed"
	[ -s "$file" ] || exit 1
	while IFS= read -r line || [ -n "$line" ]; do
		[ -n "$line" ] || continue
		printf '%s\t%s\n' "$(json_get id "$line")" "$(json_get commit "$line")"
	done <"$file"
	;;

trace)
	# Which direction the lookup runs is decided by probing each store for a
	# match -- the convention `radin scope` uses for its own argument, not a
	# regex on the token's shape. A completion line answers a done task in
	# full; a failed or blocked one has no such line, so `prepared/<id>.json`
	# answers its tree and the journal answers its status.
	arg="${2:-}"
	[ -n "$arg" ] || die "usage: trace <id|commit|branch>"
	candidates=0
	id_read=""
	commit_read=""
	branch_read=""
	seen=""

	done_line=""
	if [ -s "$completed" ]; then
		while IFS= read -r line || [ -n "$line" ]; do
			[ -n "$line" ] || continue
			if [ "$(json_get id "$line")" = "$arg" ]; then
				done_line="$line"
				break
			fi
		done <"$completed"
	fi
	if [ -n "$done_line" ]; then
		id_read="$(trace_block "$ns" "$arg" "$(json_get commit "$done_line")" \
			"$(json_get branch "$done_line")" "$(json_get worktree "$done_line")" \
			"$(json_get plan "$done_line")" "done")"
	elif [ -s "$ns/state/prepared/$arg.json" ] ||
		grep -qF "\"id\":\"$(json_escape "$arg")\"" "$ns/state/journal.jsonl" 2>/dev/null; then
		# Dispatched but never completed: provenance from `prepare`'s record,
		# status from the journal, plan from the entry that still exists.
		id_read="$(trace_block "$ns" "$arg" "" \
			"$(prepared_field "$ns" "$arg" branch)" \
			"$(prepared_field "$ns" "$arg" worktree)" \
			"$(task_plans "$repo_root" "$arg")" "$(trace_status "$ns" "$arg")")"
	fi
	if [ -n "$id_read" ]; then
		id_read="$id_read
"
		candidates=$((candidates + 1))
	fi

	# `task-done` records whatever hash the sub-agent's STATUS: line carried,
	# so the store holds short and full hashes interchangeably: either side may
	# be the prefix. Seven characters is the floor, so a stub matches nothing.
	case "$arg" in
	???????*)
		if [ -s "$completed" ]; then
			while IFS= read -r line || [ -n "$line" ]; do
				[ -n "$line" ] || continue
				c="$(json_get commit "$line")"
				case "$c" in
				???????*) ;;
				*) continue ;;
				esac
				match=0
				case "$c" in "$arg"*) match=1 ;; esac
				case "$arg" in "$c"*) match=1 ;; esac
				[ "$match" -eq 1 ] || continue
				block="$(trace_block "$ns" "$(json_get id "$line")" "$c" \
					"$(json_get branch "$line")" "$(json_get worktree "$line")" \
					"$(json_get plan "$line")" "done")"
				commit_read="$commit_read$block
"
			done <"$completed"
		fi
		;;
	esac
	if [ -n "$commit_read" ]; then candidates=$((candidates + 1)); fi

	if [ -s "$completed" ]; then
		while IFS= read -r line || [ -n "$line" ]; do
			[ -n "$line" ] || continue
			[ "$(json_get branch "$line")" = "$arg" ] || continue
			id="$(json_get id "$line")"
			seen="$seen $id"
			block="$(trace_block "$ns" "$id" "$(json_get commit "$line")" \
				"$arg" "$(json_get worktree "$line")" \
				"$(json_get plan "$line")" "done")"
			branch_read="$branch_read$block
"
		done <"$completed"
	fi
	for f in "$ns"/state/prepared/*.json; do
		[ -e "$f" ] || continue
		id="$(basename "$f" .json)"
		case " $seen " in *" $id "*) continue ;; esac
		[ "$(prepared_field "$ns" "$id" branch)" = "$arg" ] || continue
		block="$(trace_block "$ns" "$id" "" "$arg" \
			"$(prepared_field "$ns" "$id" worktree)" \
			"$(task_plans "$repo_root" "$id")" "$(trace_status "$ns" "$id")")"
		branch_read="$branch_read$block
"
	done
	if [ -n "$branch_read" ]; then candidates=$((candidates + 1)); fi

	if [ "$candidates" -eq 1 ]; then
		printf '%s' "$id_read$commit_read$branch_read"
		exit 0
	fi
	if [ "$candidates" -gt 1 ]; then
		printf 'radin-state: "%s" is ambiguous, %d candidate readings:\n' "$arg" "$candidates" >&2
		for c in "$id_read" "$commit_read" "$branch_read"; do
			if [ -n "$c" ]; then printf '%s---\n' "$c" >&2; fi
		done
		exit 2
	fi
	die "\"$arg\" is not a traced task, commit or branch in $ns"
	;;

task-done)
	id="${2:-}"
	hash="${3:-}"
	[ -n "$id" ] && [ -n "$hash" ] || die "usage: task-done <id> <commit-hash>"
	# The hash is free text off a sub-agent's STATUS: line, so validate it
	# before any bookkeeping believes it. Exit 3, not the generic die, so the
	# caller can route it as a failure instead of a CLI misuse.
	dir="$(task_dir "$id")"
	if ! git -C "$dir" rev-parse --verify --quiet "$hash^{commit}" >/dev/null 2>&1; then
		printf 'task-done: %s is not a commit in %s\n' "$hash" "$dir" >&2
		exit 3
	fi
	# The branch comes from `prepare`'s record, the only place that read it
	# from git. With no record there is no branch to name, so HEAD of the
	# task's own dir is what is left.
	prov_branch="$(prepared_field "$ns" "$id" branch)"
	prov_worktree="$(prepared_field "$ns" "$id" worktree)"
	ref="HEAD"
	if [ -n "$prov_branch" ] &&
		git -C "$dir" rev-parse --verify --quiet "$prov_branch^{commit}" >/dev/null 2>&1; then
		ref="$prov_branch"
	fi
	if ! git -C "$dir" merge-base --is-ancestor "$hash" "$ref" >/dev/null 2>&1; then
		printf 'task-done: %s is not reachable from %s in %s\n' "$hash" "$ref" "$dir" >&2
		exit 3
	fi
	# Resolved before the backlog entry goes away: nothing else records them.
	title="$(task_title "$repo_root" "$id")"
	plans="$(task_plans "$repo_root" "$id")"
	# Order matters: record success first, so a crash mid-way leaves a state
	# radin-backlog.sh reconcile can repair. Each step is skipped when a
	# retry already did it, so re-running after a crash is safe.
	if ! completed_get "$id" >/dev/null; then
		# `ts` is generated here, never passed, so no caller can record a
		# wrong one.
		printf '{"id":"%s","commit":"%s","title":"%s","branch":"%s","worktree":"%s","plan":"%s","ts":"%s"}\n' \
			"$(json_escape "$id")" "$(json_escape "$hash")" "$(json_escape "$title")" \
			"$(json_escape "$prov_branch")" "$(json_escape "$prov_worktree")" \
			"$(json_escape "$plans")" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$completed"
	fi
	if grep -qF "\"id\":\"$id\"" "$ns/backlog/index.jsonl" 2>/dev/null; then
		(cd "$repo_root" && bash "$LIB_DIR/radin-backlog.sh" remove "$id" >/dev/null)
	fi
	if [ -f "$steps" ]; then
		grep -v -F "\"id\":\"$id\"" "$steps" >"$steps.tmp" || true
		mv "$steps.tmp" "$steps"
	fi
	journal "$ns/state" "done" "$id" "$hash"
	printf 'task-done: %s recorded at %s; backlog and steps entries removed\n' "$id" "$hash"
	;;

prepare)
	# The one place the recorded worktree/branch answers turn into git
	# commands. A sub-agent only cds to the path this prints, so a "no" the
	# model would rather ignore never reaches a git invocation.
	id="${2:-}"
	[ -n "$id" ] || die "usage: prepare <id>"
	session="$(bash "$LIB_DIR/radin-state.sh" session-get 2>/dev/null)" ||
		die "no recorded worktree/branch preference in $ns/state/session.json -- run session-set first"
	worktree="$(printf '%s\n' "$session" | sed -n 's/^worktree\t//p')"
	branch_mode="$(printf '%s\n' "$session" | sed -n 's/^branch\t//p')"
	branch="radin/$id"
	wt="$repo_root-$id"
	wt_record=""
	if [ "$worktree" = "yes" ]; then
		if [ -d "$wt" ]; then
			: # a dead attempt's tree -- reuse it rather than fail on `worktree add`
		elif git -C "$repo_root" rev-parse --verify --quiet "$branch" >/dev/null 2>&1; then
			git -C "$repo_root" worktree add "$wt" "$branch" >&2
		else
			git -C "$repo_root" worktree add "$wt" -b "$branch" >&2
		fi
		journal "$ns/state" "prepare" "$id" "worktree=$wt branch=$branch"
		dir="$wt"
		wt_record="$wt"
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
		dir="$repo_root"
	fi
	# The branch is read here, after the git commands and nowhere else: a
	# `branch: no` run lands on whatever the user had checked out, and no
	# derivation from the id can see that. A detached HEAD records the literal
	# `HEAD` git prints -- a fact, not an error.
	mkdir -p "$ns/state/prepared"
	real_branch="$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
	printf '{"branch":"%s","worktree":"%s"}\n' \
		"$(json_escape "$real_branch")" "$(json_escape "$wt_record")" \
		>"$ns/state/prepared/$id.json"
	printf '%s\n' "$dir"
	;;

task-dir)
	[ -n "${2:-}" ] || die "usage: task-dir <id>"
	task_dir "$2"
	;;

dirty-check)
	dirty_files .
	;;

session-set)
	worktree="${2:-}"
	branch="${3:-}"
	[ -n "$worktree" ] && [ -n "$branch" ] || die "usage: session-set <yes|no> <yes|no>"
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
	file="$ns/state/session.json"
	[ -s "$file" ] || exit 1
	line="$(cat "$file")"
	printf 'worktree\t%s\nbranch\t%s\n' "$(json_get worktree "$line")" "$(json_get branch "$line")"
	;;

journal-tail)
	n="${2:-20}"
	file="$ns/state/journal.jsonl"
	[ -s "$file" ] || exit 1
	tail -n "$n" "$file"
	;;

task-next)
	# Everything between two dispatches, so the router makes one call per task
	# and composes nothing: pick, dependency gate, drift check, claim, prompt.
	# A named id skips the pick -- the debug and clarify retry of a task
	# already in flight.
	plan_first=0
	want=""
	for arg in "${@:2}"; do
		case "$arg" in
		--plan-first) plan_first=1 ;;
		*) want="$arg" ;;
		esac
	done
	errfile="$(mktemp)"
	trap 'rm -f "$errfile"' EXIT
	# Prints the blocked line; a named id has no next task to fall through to.
	skip() {
		printf 'blocked\t%s\t%s\n' "$pid" "$1"
		[ -z "$want" ] || exit 1
	}
	field() {
		(cd "$repo_root" && bash "$LIB_DIR/radin-backlog.sh" field "$pid" "$1" 2>"$errfile")
	}
	while :; do
		if [ -n "$want" ]; then
			pid="$want"
			entry="$(entry_line "$steps" "$pid")"
			[ -n "$entry" ] || die "no entry with id: $pid"
			order="$(num_field "$entry" order)"
		else
			pick="$(next_pending)" || exit 1
			pid="$(printf '%s' "$pick" | cut -f1)"
			order="$(printf '%s' "$pick" | cut -f2)"
		fi
		if ! deps_check "$pid" >/dev/null 2>"$errfile"; then
			msg="$(sed -n '1p' "$errfile")"
			set_status "$pid" blocked "$msg"
			skip "$msg"
			continue
		fi
		if ! field TASK_FILE >/dev/null; then
			msg="backlog entry is gone: $(sed -e 's/^radin-backlog: //' "$errfile" | sed -n '1p')"
			set_status "$pid" blocked "$msg"
			skip "$msg"
			continue
		fi
		kind=execution
		# Planning claims nothing: the task is still pending when its plan
		# lands, so the next call hands out its execution prompt.
		if [ "$plan_first" -eq 1 ] && ! field PLAN_PATHS >/dev/null; then
			kind=planning
		fi
		if [ "$kind" = execution ] && ! claim "$pid"; then
			skip "dispatched $MAX_ATTEMPTS times without a terminal status (MAX_ATTEMPTS), marked blocked"
			continue
		fi
		if [ "$kind" = execution ] && dropped="$(field SKILLS_DROPPED)"; then
			title="$(task_title "$repo_root" "$pid")"
			printf '%s\n' "$dropped" | while IFS= read -r inst; do
				[ -z "$inst" ] || journal "$ns/state" "skill-dropped" "$pid" "${title:-$pid} — $inst"
			done
		fi
		prompt="$(cd "$repo_root" && bash "$LIB_DIR/radin-prompt.sh" "$kind" "$pid")"
		printf 'id\t%s\norder\t%s\nkind\t%s\n%s\n' "$pid" "$order" "$kind" "$prompt"
		exit 0
		# Every skipped iteration moves one entry out of pending, so this terminates.
	done
	;;

task-diagnosis)
	id="${2:-}"
	[ -n "$id" ] || die "usage: task-diagnosis <id>  (diagnosis text on stdin)"
	text="$(cat)"
	[ -n "$text" ] || die "diagnosis text is empty (pass it on stdin)"
	# The only place the **Root cause:** label is written. Status is left
	# alone: the entry is still in_progress, and the retry's claim bumps
	# attempts, so MAX_ATTEMPTS still ends the loop.
	printf '**Root cause:** %s\n' "$text" |
		(cd "$repo_root" && bash "$LIB_DIR/radin-backlog.sh" append "$id" >/dev/null)
	journal "$ns/state" "diagnosis" "$id" "$text"
	printf 'task-diagnosis: recorded on %s\n' "$id"
	;;

task-report)
	# One call for everything that happens after a dispatch reports, because
	# the router picking between the dirty-tree stash, task-done and the failure route by
	# hand was four exit-code routes in its prose and one chance to write the
	# wrong file. Every outcome ends in one `next` line.
	id="${2:-}"
	third="${3:-}"
	[ -n "$id" ] && [ -n "$third" ] ||
		die "usage: task-report <id> <STATUS line>  |  task-report <id> --no-status <last line>"
	entry="$(entry_line "$steps" "$id")"
	[ -n "$entry" ] || die "no entry with id: $id"
	if [ "$third" = "--no-status" ]; then
		# No debug pass ever: there is no failure reason to debug against.
		ot="$(order_title "$id")"
		write_entry "$steps" "$id" failed "$(num_field "$entry" attempts)" \
			"sub-agent returned no STATUS line, likely an interactive skill or a spawned background task; last words: ${4:-}"
		printf "❌ Task %s '%s' failed: %s. Continuing to next task.\n" \
			"${ot%%	*}" "${ot#*	}" "sub-agent returned no STATUS line"
		printf 'next\tcontinue\n'
		exit 0
	fi
	line="$third"
	tag=""
	case "$line" in
	*"BLOCKED (FACT)"*)
		word="BLOCKED"
		tag="FACT"
		;;
	*"BLOCKED (DECISION)"*)
		word="BLOCKED"
		tag="DECISION"
		;;
	*SUCCESS*) word="SUCCESS" ;;
	*FAILED*) word="FAILED" ;;
	*) die "no SUCCESS/FAILED/BLOCKED in that line: $line -- pass --no-status when the sub-agent produced none" ;;
	esac
	# The tree comes first whatever the line claimed: a dirty tree fails the
	# task and nothing else runs.
	if dirty="$(dirty_recover "$id" "$word")"; then
		printf '%s\n' "$dirty"
		printf 'next\tcontinue\n'
		exit 0
	fi
	# Everything after the em dash (or the ASCII fallback) is the detail the
	# sub-agent wrote; the whole line stands in when it used neither.
	detail="$line"
	case "$line" in
	*"—"*) detail="${line#*—}" ;;
	*" -- "*) detail="${line#* -- }" ;;
	esac
	detail="${detail# }"
	if [ "$word" = "BLOCKED" ]; then
		printf 'next\tclarify %s\n' "$tag"
		exit 0
	fi
	if [ "$word" = "SUCCESS" ]; then
		hash="$(printf '%s\n' "$detail" | grep -oE '[0-9a-f]{7,40}' | head -1 || true)"
		if [ -n "$hash" ]; then
			if done_out="$(bash "$LIB_DIR/radin-state.sh" task-done "$id" "$hash" 2>&1)"; then
				printf '%s\n' "$done_out"
				printf 'next\tcontinue\n'
				exit 0
			fi
			# Exit 3: the hash does not validate, so the SUCCESS is
			# unsupported and this is a failure with the CLI's own message.
			word="FAILED"
			detail="reported SUCCESS at $hash, which does not validate: $done_out"
		else
			word="FAILED"
			detail="reported SUCCESS with no commit hash in the line"
		fi
	fi
	if fail_out="$(task_fail "$id" "$detail")"; then
		printf '%s\n' "$fail_out"
		printf 'next\tcontinue\n'
		exit 0
	fi
	# Return 3 from task_fail: this task still has its one debug pass.
	printf 'next\tdebug\n'
	;;

recover)
	id="${2:-}"
	[ -n "$id" ] || die "usage: recover <id>"
	if hash="$(completed_get "$id")"; then
		bash "$LIB_DIR/radin-state.sh" task-done "$id" "$hash" >/dev/null
		printf 'recovered\t%s\tbookkeeping completed at %s\n' "$id" "$hash"
		exit 0
	fi
	dir="$(task_dir "$id")"
	# Only `prepare` reads a task's branch from git; with no record there is
	# nothing to name, and no derivation from the id could see a run that
	# answered `branch: no`.
	branch="$(prepared_field "$ns" "$id" branch)"
	if [ -n "$branch" ] && git -C "$repo_root" rev-parse --verify --quiet "$branch" >/dev/null 2>&1; then
		commits="$(git -C "$repo_root" log --oneline --no-decorate "$branch" --not HEAD 2>/dev/null | sed -n '1,20p')"
		if [ -n "$commits" ]; then
			# The one branch no verb can settle: only the model can say
			# whether these commits satisfy the task. It answers with
			# task-done or recover-reject.
			if [ "$dir" = "$repo_root" ]; then
				printf 'worktree\tnone\n'
			else
				printf 'worktree\t%s\n' "$dir"
			fi
			printf 'branch\t%s\n' "$branch"
			printf '%s\n' "$commits" | sed 's/^/branch_commit\t/'
			exit 3
		fi
	fi
	if [ -z "$(dirty_files "$dir")" ]; then
		set_status "$id" pending ""
		printf 'recovered\t%s\tnothing left behind, back to pending\n' "$id"
		exit 0
	fi
	ref="$(stash_tree "$dir" "radin-execute: crash recovery for task $id")"
	set_status "$id" pending "tree stashed as $ref in $dir before retry"
	journal "$ns/state" "stash" "$id" \
		"$ref in $dir -- crash recovery for task $id. Recover: git -C $dir stash pop"
	printf 'recovered\t%s\tstashed %s, back to pending\n' "$id" "$ref"
	;;

recover-reject)
	id="${2:-}"
	[ -n "$id" ] || die "usage: recover-reject <id>"
	dir="$(task_dir "$id")"
	note="a dead session left commits on radin/$id that do not satisfy the task -- inspect them before retrying"
	if [ "$dir" != "$repo_root" ]; then
		note="a dead session left commits on radin/$id (worktree $dir) that do not satisfy the task -- inspect them before retrying"
	fi
	set_status "$id" blocked "$note"
	printf 'blocked\t%s\t%s\n' "$id" "$note"
	;;

report)
	state_dir="$ns/state"
	worktree_mode="no"
	branch_mode="no"
	if session="$(bash "$LIB_DIR/radin-state.sh" session-get 2>/dev/null)"; then
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
	dropped_block=""
	if [ -s "$state_dir/journal.jsonl" ]; then
		from="$(grep -n '"event":"steps-init"' "$state_dir/journal.jsonl" | tail -n1 | cut -d: -f1)"
		stash_block="$(tail -n "+${from:-1}" "$state_dir/journal.jsonl" |
			sed -nE 's/.*"event":"stash","id":"[^"]+","detail":"(.*)"\}$/- \1/p')"
		# A retried task journals its drops again, hence the dedupe.
		dropped_block="$(tail -n "+${from:-1}" "$state_dir/journal.jsonl" |
			sed -nE 's/.*"event":"skill-dropped","id":"[^"]+","detail":"(.*)"\}$/- \1/p' | awk '!seen[$0]++')"
	fi

	# Residual changes: never committed, parked instead. The user's call.
	residual="no residual changes"
	if [ -n "$(git -C "$repo_root" status --porcelain -- . ':(exclude).claude/.radin' 2>/dev/null)" ]; then
		ref="$(stash_tree "$repo_root" "radin-execute: session end, untracked to any task")"
		journal "$state_dir" "stash" "" "radin-execute: session end, untracked to any task"
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
	[ -z "$dropped_block" ] || printf '\nSkills dropped as unrunnable by a sub-agent (run them yourself):\n%s\n' "$dropped_block"
	;;

*)
	die "unknown command: ${cmd:-<none>} (steps-init|task-next|task-report|task-diagnosis|task-done|set-status|stuck|recover|recover-reject|report|session-set|session-get|prepare|dirty-check|trace|completed-show|completed-list|deps-check|task-dir|journal-tail)"
	;;
esac

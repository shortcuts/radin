#!/usr/bin/env bash
# Deterministic backlog operations, so agents/skills don't hand-edit backlog
# storage. Installed to ~/.claude/.radin/lib/radin-backlog.sh by install.sh.
#
# Storage: $BACKLOG_INDEX is a JSONL file (one compact JSON object per line,
# one per task: {"id":...,"category":...,"title":...,"file":...}).
# Each line's `file` field, relative to the backlog directory, is the
# authoritative location of that task's body (description prose, and any
# **Plan:** pointer lines radin-plan appends): `add` decides it, every other
# verb reads it back. Splitting each task into its own file means inserting a
# **Plan:** line into one task can never shift another task's content — unlike
# the old single-file BACKLOG.md, nothing here is ever addressed by line
# number.
#
# Usage:
#   radin-backlog.sh env [--export]             # print REPO_ROOT/NAMESPACE_DIR/BACKLOG_INDEX/BACKLOG_TASKS_DIR (--export: source-able with export)
#   radin-backlog.sh show [category]             # print backlog as markdown, or one ## section
#   radin-backlog.sh list                        # print "id<TAB>category<TAB>title<TAB>file" for every task
#   radin-backlog.sh find <id-or-title>          # print matching "id<TAB>category<TAB>title<TAB>file" line(s)
#   radin-backlog.sh count                       # print the number of entries (0 without an index)
#   radin-backlog.sh add <category> <title> [--epic <epic-id>] [--skill <name>]...  # create task, body read from stdin, prints its id
#   radin-backlog.sh add-plan <id-or-title> <path>  # append "**Plan:** <path>" to the task's file
#   radin-backlog.sh append <id-or-title>        # append text from stdin to the task's file
#   radin-backlog.sh path <id-or-title>          # print the task file's absolute path
#   radin-backlog.sh set-category <id-or-title> <category>  # move a task to another category
#   radin-backlog.sh retitle <id-or-title> <title>  # change a task's title (its id never changes)
#   radin-backlog.sh meta <id-or-title>          # print "plan<TAB><path>" / "skill<TAB><instruction>" lines from the task's file
#   radin-backlog.sh remove <id-or-title>        # delete task file + index entry (exact single match required)
#   radin-backlog.sh reconcile <completed-file>  # drop backlog entries whose id is already in completed.json
#   radin-backlog.sh epics                       # print every epic id, one per line
#   radin-backlog.sh epic-add <epic-id>          # create the epic dir + DESCRIPTION.md (body from stdin when piped)
#   radin-backlog.sh epic-move <id-or-title> <epic-id|--none>  # move a task into/out of an epic
#   radin-backlog.sh epic-remove <epic-id>       # delete an epic that has no child tasks left
#
# An epic is a directory under tasks/ holding DESCRIPTION.md (the root context
# every child task inherits) plus one file per child task. Membership is
# carried only by the index line's `file` field (`tasks/<epic-id>/<id>.md`),
# so an epic gets no index line of its own and no category: a consumer that
# forgot to filter epics out of `list` would dispatch one as a task.
# One nesting level: no epics inside epics.
#
# Categories: feat | fix | chore | refactor (canonical section order, used by `show`).
# `find` matches an exact id first, then exact title, then case-insensitive
# substring on title; multiple lines out means ambiguity the caller must resolve.
# Must stay bash-3.2-compatible (macOS /bin/bash).
set -euo pipefail

die() {
	printf 'radin-backlog: %s\n' "$*" >&2
	exit 1
}

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$LIB_DIR/radin-json.sh"
eval "$(bash "$LIB_DIR/radin-namespace.sh")"

require_index() {
	[ -s "$BACKLOG_INDEX" ] || die "no backlog at $BACKLOG_INDEX"
}

# TSV is the agent-facing output format, so a tab/CR/LF in a title corrupts
# every consumer's field split.
require_plain_title() {
	[ "$(printf '%s' "$1" | tr -d '\t\r\n')" = "$1" ] ||
		die "title must not contain a tab, carriage return or newline: $1"
}

slugify() {
	printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'
}

# Prints "id<TAB>category<TAB>title<TAB>file" for JSONL line $1.
fmt_line() {
	local line="$1" id category title file
	id="$(json_get id "$line")"
	category="$(json_get category "$line")"
	title="$(json_get title "$line")"
	file="$(json_get file "$line")"
	printf '%s\t%s\t%s\t%s\n' "$id" "$category" "$title" "$file"
}

# Absolute path of the task file whose index-relative location is $1.
task_path() {
	printf '%s/%s\n' "${BACKLOG_INDEX%/*}" "$1"
}

# Same, from an "id<TAB>category<TAB>title<TAB>file" line out of fmt_line.
span_path() {
	task_path "$(printf '%s' "$1" | cut -f4)"
}

# The epic a `file` field belongs to, or empty at the flat tasks/ level.
file_epic() {
	case "$1" in
	tasks/*/*)
		local rest="${1#tasks/}"
		printf '%s\n' "${rest%%/*}"
		;;
	esac
}

require_epic_id() {
	[ "$(slugify "$1")" = "$1" ] || die "epic id must be a slug (lowercase, dashes), got: $1"
	[ -d "$BACKLOG_TASKS_DIR/$1" ] || die "no such epic: $1"
}

# True when any epic (or the flat level) already holds a task file for id $1.
# Task ids stay globally unique: depends_on, `radin state prepare` and the
# radin/<id> branch name all key off the bare id, never off the epic path.
id_taken() {
	local f
	for f in "$BACKLOG_TASKS_DIR/$1.md" "$BACKLOG_TASKS_DIR"/*/"$1.md"; do
		[ -e "$f" ] && return 0
	done
	return 1
}

# Drop an epic directory once its last child task is gone, so `epics` never
# reports a husk left behind by `remove`.
prune_empty_epic() {
	local epic="$1" f
	[ -n "$epic" ] && [ -d "$BACKLOG_TASKS_DIR/$epic" ] || return 0
	for f in "$BACKLOG_TASKS_DIR/$epic"/*.md; do
		case "$f" in
		*/DESCRIPTION.md | "$BACKLOG_TASKS_DIR/$epic/*.md") continue ;;
		esac
		[ -e "$f" ] && return 0
	done
	rm -f "$BACKLOG_TASKS_DIR/$epic/DESCRIPTION.md"
	rmdir "$BACKLOG_TASKS_DIR/$epic" 2>/dev/null || true
}

# Delete a task by id: its body file and its index line.
# Rewrite the index line for id $1, replacing its category with $2, its title
# with $3 and/or its `file` with $4 (empty means keep). The id passes through
# untouched -- callers key off the id for the task's lifetime.
set_index_fields() {
	local id="$1" newcat="$2" newtitle="$3" newfile="${4:-}" line out=""
	while IFS= read -r line || [ -n "$line" ]; do
		[ -n "$line" ] || continue
		if [ "$(json_get id "$line")" = "$id" ]; then
			[ -n "$newcat" ] || newcat="$(json_get category "$line")"
			[ -n "$newtitle" ] || newtitle="$(json_get title "$line")"
			[ -n "$newfile" ] || newfile="$(json_get file "$line")"
			line="$(printf '{"id":"%s","category":"%s","title":"%s","file":"%s"}' \
				"$id" "$newcat" "$(json_escape "$newtitle")" "$newfile")"
		fi
		out="$out$line
"
	done <"$BACKLOG_INDEX"
	printf '%s' "$out" >"$BACKLOG_INDEX"
}

remove_by_id() {
	local line rel=""
	line="$(grep -F "\"id\":\"$1\"" "$BACKLOG_INDEX" || true)"
	if [ -n "$line" ]; then
		rel="$(json_get file "$line")"
		rm -f "$(task_path "$rel")"
		prune_empty_epic "$(file_epic "$rel")"
	fi
	grep -v -F "\"id\":\"$1\"" "$BACKLOG_INDEX" >"$BACKLOG_INDEX.tmp" || true
	mv "$BACKLOG_INDEX.tmp" "$BACKLOG_INDEX"
}

# Matching JSONL lines for query $1: exact id, else exact title, else
# case-insensitive substring on title.
matches() {
	local q="$1" line id title lt lq found
	found=0
	while IFS= read -r line; do
		[ -n "$line" ] || continue
		id="$(json_get id "$line")"
		if [ "$id" = "$q" ]; then
			fmt_line "$line"
			found=1
		fi
	done <"$BACKLOG_INDEX"
	[ "$found" -eq 1 ] && return 0

	found=0
	while IFS= read -r line; do
		[ -n "$line" ] || continue
		title="$(json_get title "$line")"
		if [ "$title" = "$q" ]; then
			fmt_line "$line"
			found=1
		fi
	done <"$BACKLOG_INDEX"
	[ "$found" -eq 1 ] && return 0

	lq="$(printf '%s' "$q" | tr '[:upper:]' '[:lower:]')"
	while IFS= read -r line; do
		[ -n "$line" ] || continue
		title="$(json_get title "$line")"
		lt="$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]')"
		case "$lt" in *"$lq"*) fmt_line "$line" ;; esac
	done <"$BACKLOG_INDEX"
	return 0
}

# One exact-single-match line for query $1, or die with what was found.
single_match() {
	local found n
	found="$(matches "$1")"
	[ -n "$found" ] || die "no entry matches: $1"
	n="$(printf '%s\n' "$found" | grep -c '.')"
	[ "$n" -eq 1 ] || die "matches $n entries: $1
$found"
	printf '%s\n' "$found"
}

cmd="${1:-}"
case "$cmd" in
env)
	if [ "${2:-}" = "--export" ]; then
		bash "$LIB_DIR/radin-namespace.sh" | sed 's/^/export /'
	else
		bash "$LIB_DIR/radin-namespace.sh"
	fi
	;;

show)
	require_index
	printf '# Backlog\n'
	cats="feat fix chore refactor"
	[ -z "${2:-}" ] || cats="$2"
	for cat in $cats; do
		section=""
		while IFS= read -r line; do
			[ -n "$line" ] || continue
			[ "$(json_get category "$line")" = "$cat" ] && section="$section$line
"
		done <"$BACKLOG_INDEX"
		[ -n "$section" ] || continue
		printf '\n## %s\n' "$cat"
		printf '%s' "$section" | while IFS= read -r line; do
			[ -n "$line" ] || continue
			rel="$(json_get file "$line")"
			[ -z "$(file_epic "$rel")" ] || continue
			printf '\n### %s\n' "$(json_get title "$line")"
			cat "$(task_path "$rel")"
		done
		# An epic's shared context is printed once, above its children, so a
		# human reading `show` sees the hierarchy the `file` paths encode.
		cat_epics="$(printf '%s' "$section" | while IFS= read -r line; do
			[ -n "$line" ] || continue
			file_epic "$(json_get file "$line")"
		done | sort -u)"
		for epic in $cat_epics; do
			printf '\n### epic: %s\n' "$epic"
			[ ! -s "$BACKLOG_TASKS_DIR/$epic/DESCRIPTION.md" ] ||
				cat "$BACKLOG_TASKS_DIR/$epic/DESCRIPTION.md"
			printf '%s' "$section" | while IFS= read -r line; do
				[ -n "$line" ] || continue
				rel="$(json_get file "$line")"
				[ "$(file_epic "$rel")" = "$epic" ] || continue
				printf '\n#### %s\n' "$(json_get title "$line")"
				cat "$(task_path "$rel")"
			done
		done
	done
	;;

list)
	require_index
	while IFS= read -r line; do
		[ -n "$line" ] || continue
		fmt_line "$line"
	done <"$BACKLOG_INDEX"
	;;

find)
	[ -n "${2:-}" ] || die "usage: find <id-or-title>"
	require_index
	out="$(matches "$2")"
	[ -n "$out" ] || die "no entry matches: $2"
	printf '%s\n' "$out"
	;;

add)
	category="${2:-}"
	title="${3:-}"
	[ -n "$title" ] || die "usage: add <category> <title> [--epic <epic-id>] [--skill <name>]...  (body on stdin)"
	case "$category" in
	feat | fix | chore | refactor) ;;
	*) die "category must be feat|fix|chore|refactor, got: $category" ;;
	esac
	shift 3
	skills=""
	epic=""
	while [ $# -gt 0 ]; do
		case "$1" in
		--skill)
			[ -n "${2:-}" ] || die "--skill needs a name"
			skills="$skills$2
"
			shift 2
			;;
		--epic)
			[ -n "${2:-}" ] || die "--epic needs an epic id"
			epic="$2"
			require_epic_id "$epic"
			shift 2
			;;
		*) die "unknown add option: $1" ;;
		esac
	done
	require_plain_title "$title"
	BODY="$(cat)"
	[ -n "$BODY" ] || die "entry body is empty (pass it on stdin)"
	id="$(slugify "$title")"
	[ -n "$id" ] || die "title produced an empty id: $title"
	base="$id"
	n=2
	while id_taken "$id"; do
		id="$base-$n"
		n=$((n + 1))
	done
	# `add` is the one verb that decides a task's location instead of reading
	# it: the `file` field it writes here is what lets every other verb read.
	if [ -n "$epic" ]; then
		rel="tasks/$epic/$id.md"
	else
		rel="tasks/$id.md"
	fi
	task_file="$(task_path "$rel")"
	printf '%s\n' "$BODY" >"$task_file"
	printf '%s' "$skills" | while IFS= read -r s; do
		[ -n "$s" ] || continue
		printf '**Skill:** Invoke %s to tackle this task.\n' "$s" >>"$task_file"
	done
	printf '{"id":"%s","category":"%s","title":"%s","file":"%s"}\n' \
		"$id" "$category" "$(json_escape "$title")" "$rel" >>"$BACKLOG_INDEX"
	printf 'added "%s" (id: %s) under %s in %s\n' "$title" "$id" "$category" "$BACKLOG_INDEX"
	;;

count)
	if [ -s "$BACKLOG_INDEX" ]; then
		grep -c . "$BACKLOG_INDEX" || true
	else
		printf '0\n'
	fi
	;;

meta)
	[ -n "${2:-}" ] || die "usage: meta <id-or-title>"
	require_index
	span="$(single_match "$2")"
	while IFS= read -r line || [ -n "$line" ]; do
		case "$line" in
		'**Plan:** '*) printf 'plan\t%s\n' "${line#"**Plan:** "}" ;;
		'**Skill:** '*) printf 'skill\t%s\n' "${line#"**Skill:** "}" ;;
		esac
	done <"$(span_path "$span")"
	;;

append)
	[ -n "${2:-}" ] || die "usage: append <id-or-title>  (text on stdin)"
	require_index
	span="$(single_match "$2")"
	BODY="$(cat)"
	[ -n "$BODY" ] || die "append text is empty (pass it on stdin)"
	printf '\n%s\n' "$BODY" >>"$(span_path "$span")"
	printf 'appended to "%s"\n' "$(printf '%s' "$span" | cut -f3)"
	;;

add-plan)
	query="${2:-}"
	plan_path="${3:-}"
	[ -n "$plan_path" ] || die "usage: add-plan <id-or-title> <plan-path>"
	require_index
	span="$(single_match "$query")"
	printf '**Plan:** %s\n' "$plan_path" >>"$(span_path "$span")"
	printf 'plan pointer added to "%s"\n' "$(printf '%s' "$span" | cut -f3)"
	;;

path)
	[ -n "${2:-}" ] || die "usage: path <id-or-title>"
	require_index
	span="$(single_match "$2")"
	span_path "$span"
	;;

set-category)
	query="${2:-}"
	newcat="${3:-}"
	[ -n "$newcat" ] || die "usage: set-category <id-or-title> <feat|fix|chore|refactor>"
	case "$newcat" in
	feat | fix | chore | refactor) ;;
	*) die "category must be feat|fix|chore|refactor, got: $newcat" ;;
	esac
	require_index
	span="$(single_match "$query")"
	id="$(printf '%s' "$span" | cut -f1)"
	set_index_fields "$id" "$newcat" ""
	printf 'moved "%s" to %s\n' "$(printf '%s' "$span" | cut -f3)" "$newcat"
	;;

retitle)
	query="${2:-}"
	newtitle="${3:-}"
	[ -n "$newtitle" ] || die "usage: retitle <id-or-title> <new-title>"
	require_plain_title "$newtitle"
	require_index
	span="$(single_match "$query")"
	id="$(printf '%s' "$span" | cut -f1)"
	set_index_fields "$id" "" "$newtitle"
	printf 'retitled %s to "%s"\n' "$id" "$newtitle"
	;;

remove)
	query="${2:-}"
	[ -n "$query" ] || die "usage: remove <id-or-title>"
	require_index
	span="$(single_match "$query")"
	id="$(printf '%s' "$span" | cut -f1)"
	title="$(printf '%s' "$span" | cut -f3)"
	remove_by_id "$id"
	printf 'removed "%s" (id: %s)\n' "$title" "$id"
	;;

reconcile)
	# A task's success is recorded in completed.json (radin-state.sh
	# completed-add) BEFORE its backlog entry is removed. If the run dies
	# between those two steps the completed entry stays in the backlog and
	# looks unstarted next session. Reconcile closes that gap: drop every
	# backlog entry whose id already sits in completed.json.
	# ponytail: id-keyed match. A brand-new task that reuses a removed
	# task's slug (same title) would be dropped too; clear completed.json
	# between sessions if that ever bites.
	completed_file="${2:-}"
	[ -n "$completed_file" ] || die "usage: reconcile <completed-file>"
	require_index
	[ -f "$completed_file" ] || {
		printf 'reconcile: no completed file, nothing to do\n'
		exit 0
	}
	removed=""
	while IFS= read -r cline || [ -n "$cline" ]; do
		[ -n "$cline" ] || continue
		cid="$(json_get id "$cline")"
		[ -n "$cid" ] || continue
		if grep -qF "\"id\":\"$cid\"" "$BACKLOG_INDEX"; then
			remove_by_id "$cid"
			removed="$removed $cid"
		fi
	done <"$completed_file"
	[ -n "$removed" ] && printf 'reconcile: dropped already-completed entries:%s\n' "$removed" || printf 'reconcile: no stale completed entries\n'
	;;

epics)
	# A directory listing is the whole store: an epic index file would be a
	# second copy of what one `ls` already knows.
	for d in "$BACKLOG_TASKS_DIR"/*/; do
		[ -d "$d" ] || continue
		d="${d%/}"
		printf '%s\n' "${d##*/}"
	done
	;;

epic-add)
	epic="${2:-}"
	[ -n "$epic" ] || die "usage: epic-add <epic-id>  (description on stdin)"
	[ "$(slugify "$epic")" = "$epic" ] || die "epic id must be a slug (lowercase, dashes), got: $epic"
	[ ! -d "$BACKLOG_TASKS_DIR/$epic" ] || die "epic already exists: $epic"
	id_taken "$epic" && die "a task already uses that id: $epic"
	mkdir -p "$BACKLOG_TASKS_DIR/$epic"
	if [ -t 0 ]; then
		: >"$BACKLOG_TASKS_DIR/$epic/DESCRIPTION.md"
	else
		cat >"$BACKLOG_TASKS_DIR/$epic/DESCRIPTION.md"
	fi
	printf 'created epic %s\n' "$epic"
	;;

epic-move)
	query="${2:-}"
	target="${3:-}"
	[ -n "$target" ] || die "usage: epic-move <id-or-title> <epic-id|--none>"
	require_index
	span="$(single_match "$query")"
	id="$(printf '%s' "$span" | cut -f1)"
	old_rel="$(printf '%s' "$span" | cut -f4)"
	if [ "$target" = "--none" ]; then
		new_rel="tasks/$id.md"
	else
		require_epic_id "$target"
		new_rel="tasks/$target/$id.md"
	fi
	[ "$old_rel" != "$new_rel" ] || die "already there: $old_rel"
	mv "$(task_path "$old_rel")" "$(task_path "$new_rel")"
	set_index_fields "$id" "" "" "$new_rel"
	prune_empty_epic "$(file_epic "$old_rel")"
	printf 'moved %s to %s\n' "$id" "$new_rel"
	;;

epic-remove)
	epic="${2:-}"
	[ -n "$epic" ] || die "usage: epic-remove <epic-id>"
	require_epic_id "$epic"
	# Never recursively delete tasks: the operator moves them out first.
	for f in "$BACKLOG_TASKS_DIR/$epic"/*.md; do
		case "$f" in
		*/DESCRIPTION.md | "$BACKLOG_TASKS_DIR/$epic/*.md") continue ;;
		esac
		[ -e "$f" ] && die "epic $epic still holds child tasks; epic-move them out first"
	done
	rm -f "$BACKLOG_TASKS_DIR/$epic/DESCRIPTION.md"
	rmdir "$BACKLOG_TASKS_DIR/$epic"
	printf 'removed epic %s\n' "$epic"
	;;

*)
	die "unknown command: ${cmd:-<none>} (env|show|list|count|find|add|add-plan|append|meta|path|set-category|retitle|remove|reconcile|epics|epic-add|epic-move|epic-remove)"
	;;
esac

#!/usr/bin/env bash
# Deterministic backlog operations, so agents/skills don't hand-edit backlog
# storage. Installed to ~/.claude/.radin/lib/radin-backlog.sh by install.sh.
#
# Storage: $BACKLOG_INDEX is a JSONL file (one compact JSON object per line,
# one per task: {"id":...,"category":...,"title":...,"file":...}).
# $BACKLOG_TASKS_DIR/<id>.md holds each task's body (description prose, and
# any **Plan:** pointer lines radin-plan appends). Splitting each task into
# its own file means inserting a **Plan:** line into one task can never
# shift another task's content — unlike the old single-file BACKLOG.md,
# nothing here is ever addressed by line number.
#
# Usage:
#   radin-backlog.sh env                        # print REPO_ROOT/NAMESPACE_DIR/BACKLOG_INDEX/BACKLOG_TASKS_DIR
#   radin-backlog.sh show [category]             # print backlog as markdown, or one ## section
#   radin-backlog.sh list                        # print "id<TAB>category<TAB>title<TAB>file" for every task
#   radin-backlog.sh find <id-or-title>          # print matching "id<TAB>category<TAB>title<TAB>file" line(s)
#   radin-backlog.sh add <category> <title>      # create task, body read from stdin, prints its id
#   radin-backlog.sh add-plan <id-or-title> <path>  # append "**Plan:** <path>" to the task's file
#   radin-backlog.sh remove <id-or-title>        # delete task file + index entry (exact single match required)
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
eval "$(bash "$LIB_DIR/radin-namespace.sh")"

require_index() {
	[ -s "$BACKLOG_INDEX" ] || die "no backlog at $BACKLOG_INDEX"
}

slugify() {
	printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'
}

json_escape() {
	printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# Extracts field $1 (id|category|title|file) from JSONL line $2, unescaped.
json_get() {
	printf '%s' "$2" | sed -E "s/.*\"$1\":\"((\\\\.|[^\"\\\\])*)\".*/\\1/" | sed -e 's/\\"/"/g' -e 's/\\\\/\\/g'
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
	bash "$LIB_DIR/radin-namespace.sh"
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
			id="$(json_get id "$line")"
			title="$(json_get title "$line")"
			printf '\n### %s\n' "$title"
			cat "$BACKLOG_TASKS_DIR/$id.md"
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
	[ -n "$title" ] || die "usage: add <category> <title>  (body on stdin)"
	case "$category" in
	feat | fix | chore | refactor) ;;
	*) die "category must be feat|fix|chore|refactor, got: $category" ;;
	esac
	BODY="$(cat)"
	[ -n "$BODY" ] || die "entry body is empty (pass it on stdin)"
	id="$(slugify "$title")"
	[ -n "$id" ] || die "title produced an empty id: $title"
	base="$id"
	n=2
	while [ -f "$BACKLOG_TASKS_DIR/$id.md" ]; do
		id="$base-$n"
		n=$((n + 1))
	done
	printf '%s\n' "$BODY" >"$BACKLOG_TASKS_DIR/$id.md"
	printf '{"id":"%s","category":"%s","title":"%s","file":"tasks/%s.md"}\n' \
		"$id" "$category" "$(json_escape "$title")" "$id" >>"$BACKLOG_INDEX"
	printf 'added "%s" (id: %s) under %s in %s\n' "$title" "$id" "$category" "$BACKLOG_INDEX"
	;;

add-plan)
	query="${2:-}"
	plan_path="${3:-}"
	[ -n "$plan_path" ] || die "usage: add-plan <id-or-title> <plan-path>"
	require_index
	span="$(single_match "$query")"
	id="$(printf '%s' "$span" | cut -f1)"
	printf '**Plan:** %s\n' "$plan_path" >>"$BACKLOG_TASKS_DIR/$id.md"
	printf 'plan pointer added to "%s"\n' "$(printf '%s' "$span" | cut -f3)"
	;;

remove)
	query="${2:-}"
	[ -n "$query" ] || die "usage: remove <id-or-title>"
	require_index
	span="$(single_match "$query")"
	id="$(printf '%s' "$span" | cut -f1)"
	title="$(printf '%s' "$span" | cut -f3)"
	rm -f "$BACKLOG_TASKS_DIR/$id.md"
	grep -v -F "\"id\":\"$id\"" "$BACKLOG_INDEX" >"$BACKLOG_INDEX.tmp" || true
	mv "$BACKLOG_INDEX.tmp" "$BACKLOG_INDEX"
	printf 'removed "%s" (id: %s)\n' "$title" "$id"
	;;

*)
	die "unknown command: ${cmd:-<none>} (env|show|list|find|add|add-plan|remove)"
	;;
esac

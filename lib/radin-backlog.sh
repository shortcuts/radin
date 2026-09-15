#!/usr/bin/env bash
# Deterministic backlog operations, so agents/skills don't hand-edit backlog
# storage. Installed to ~/.claude/.radin/lib/radin-backlog.sh by install.sh.
#
# Storage: $BACKLOG_INDEX is a JSONL file (one compact JSON object per line,
# one per task: {"id":...,"category":...,"title":...,"file":...}), plus the
# optional "priority":<int> and "depends_on":[<id>,...] keys a human sets.
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
#   radin-backlog.sh list                        # print "id<TAB>category<TAB>title<TAB>file<TAB>priority<TAB>depends-on-csv", priority-descending, unset priorities last
#   radin-backlog.sh find <id-or-title>          # print matching "id<TAB>category<TAB>title<TAB>file<TAB>priority<TAB>depends-on-csv" line(s)
#   radin-backlog.sh count                       # print the number of entries (0 without an index)
#   radin-backlog.sh add <category> <title> [--epic <epic-id>] [--skill <name>]... [--priority <n>] [--depends-on <csv>]  # create task, body read from stdin, prints its id
#   radin-backlog.sh add-plan <id-or-title> <path>  # append "**Plan:** <path>" to the task's file
#   radin-backlog.sh append <id-or-title>        # append text from stdin to the task's file
#   radin-backlog.sh path <id-or-title>          # print the task file's absolute path
#   radin-backlog.sh set-category <id-or-title> <category>  # move a task to another category
#   radin-backlog.sh retitle <id-or-title> <title>  # change a task's title (its id never changes)
#   radin-backlog.sh set-priority <id-or-title> <integer|--none>  # set/clear the priority (higher wins)
#   radin-backlog.sh set-deps <id-or-title> <csv-of-ids|--none>   # set/clear depends_on (rejects an unknown id and any cycle)
#   radin-backlog.sh meta <id-or-title>          # print "plan<TAB><path>" / "skill<TAB><instruction>" / "acceptance<TAB><criterion>" lines from the task's file
#   radin-backlog.sh planned                     # print the id of every task that already has a **Plan:** line
#   radin-backlog.sh remove <id-or-title>        # delete task file + index entry (exact single match required)
#   radin-backlog.sh reconcile <completed-file>  # drop backlog entries whose id is already in completed.json
#   radin-backlog.sh epics                       # print every epic id, one per line
#   radin-backlog.sh epic-add <epic-id>          # create the epic dir + DESCRIPTION.md (body from stdin when piped)
#   radin-backlog.sh epic-show <epic-id>         # print the epic's DESCRIPTION.md
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
# Priority is a human's call, so it is stored, not re-derived: higher is more
# important, gaps and duplicates are fine (inserting a task never forces a
# renumber), and an absent key means unset -- which must stay distinguishable
# from any number, because "did a human decide this?" is the question a
# prioritization pass has to answer. `depends_on` is human-authored ordering
# over task ids. Both live on the index line rather than in the task body, so
# sorting the backlog costs no file read per task.
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

# Space-separated task ids from a raw "depends_on" array; empty when unset.
deps_ids() {
	printf '%s' "$1" | tr -d '[]" ' | tr ',' ' '
}

# JSON array literal for the ids in "$@", or nothing when there are none: an
# empty depends_on and an absent one mean the same thing on the index line.
deps_array() {
	local out="" d
	for d in "$@"; do
		[ -z "$out" ] || out="$out,"
		out="$out\"$d\""
	done
	[ -z "$out" ] || printf '[%s]\n' "$out"
}

# Prints "id<TAB>category<TAB>title<TAB>file<TAB>priority<TAB>depends-on-csv"
# for JSONL line $1. The last two fields are empty when unset.
fmt_line() {
	local line="$1" id category title file priority deps
	id="$(json_get id "$line")"
	category="$(json_get category "$line")"
	title="$(json_get title "$line")"
	file="$(json_get file "$line")"
	priority="$(json_get_raw priority "$line")"
	deps="$(deps_ids "$(json_get_raw depends_on "$line")" | tr ' ' ',')"
	printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$category" "$title" "$file" "$priority" "$deps"
}

# fmt_line over a stream of raw index lines, so `find` keeps its TSV contract
# while `matches` hands callers the line itself.
fmt_lines() {
	local line
	while IFS= read -r line; do
		[ -n "$line" ] || continue
		fmt_line "$line"
	done
}

# Absolute path of the task file whose index-relative location is $1.
task_path() {
	printf '%s/%s\n' "${BACKLOG_INDEX%/*}" "$1"
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

# True when the index already carries id $1, at any epic depth. Task ids stay
# globally unique: depends_on, `radin state prepare` and the radin/<id> branch
# name all key off the bare id, never off the epic path.
id_taken() {
	grep -qF "\"id\":\"$1\"" "$BACKLOG_INDEX" 2>/dev/null
}

# The only definition of "this epic holds no child task": DESCRIPTION.md is
# the epic's own root context, not a child.
epic_is_empty() {
	[ -z "$(find "$BACKLOG_TASKS_DIR/$1" -maxdepth 1 -name '*.md' ! -name DESCRIPTION.md -print -quit 2>/dev/null)" ]
}

# Drop an epic directory once its last child task is gone, so `epics` never
# reports a husk left behind by `remove`.
prune_empty_epic() {
	local epic="$1"
	[ -n "$epic" ] && [ -d "$BACKLOG_TASKS_DIR/$epic" ] || return 0
	epic_is_empty "$epic" || return 0
	rm -f "$BACKLOG_TASKS_DIR/$epic/DESCRIPTION.md"
	rmdir "$BACKLOG_TASKS_DIR/$epic" 2>/dev/null || true
}

# One index line. An empty $5/$6 omits the key entirely, so every verb that
# rewrites a line keeps "unset" unset instead of defaulting it to a value.
compose_line() {
	local out
	out="$(printf '{"id":"%s","category":"%s","title":"%s","file":"%s"' \
		"$1" "$2" "$(json_escape "$3")" "$4")"
	[ -z "$5" ] || out="$out,\"priority\":$5"
	[ -z "$6" ] || out="$out,\"depends_on\":$6"
	printf '%s}\n' "$out"
}

# Index line $1 with key $2 set to $3 (empty $3 drops the key), printed back.
# Only place that unpacks a line into compose_line's six arguments.
line_set_field() {
	local line="$1" key="$2" value="$3" category title file prio deps
	category="$(json_get category "$line")"
	title="$(json_get title "$line")"
	file="$(json_get file "$line")"
	prio="$(json_get_raw priority "$line")"
	deps="$(json_get_raw depends_on "$line")"
	case "$key" in
	category) category="$value" ;;
	title) title="$value" ;;
	file) file="$value" ;;
	priority) prio="$value" ;;
	depends_on) deps="$value" ;;
	*) die "line_set_field: unknown key: $key" ;;
	esac
	compose_line "$(json_get id "$line")" "$category" "$title" "$file" "$prio" "$deps"
}

# Replace the index with $1 in one rename, so a caller that dies while it
# builds the new content leaves the old index untouched. The trap keeps that
# dead run from leaving `.tmp` debris in the consumer's backlog directory.
write_index() {
	trap 'rm -f "$BACKLOG_INDEX.tmp"' EXIT
	printf '%s' "$1" >"$BACKLOG_INDEX.tmp"
	mv "$BACKLOG_INDEX.tmp" "$BACKLOG_INDEX"
	trap - EXIT
}

# Rewrite one key of the index line for id $1: $2 names the key, $3 is its
# new value, and an empty $3 drops the key. A key the caller does not name is
# always kept, so no argument ever has to mean "leave this alone".
set_index_field() {
	local id="$1" key="$2" value="$3" line out=""
	while IFS= read -r line || [ -n "$line" ]; do
		[ -n "$line" ] || continue
		if [ "$(json_get id "$line")" = "$id" ]; then
			line="$(line_set_field "$line" "$key" "$value")"
		fi
		out="$out$line
"
	done <"$BACKLOG_INDEX"
	write_index "$out"
}

# Drop id $1 from every other entry's depends_on: a dangling reference stalls
# `radin state deps-check` exactly like a cycle does.
prune_dep() {
	local gone="$1" line raw dep kept out=""
	while IFS= read -r line || [ -n "$line" ]; do
		[ -n "$line" ] || continue
		raw="$(json_get_raw depends_on "$line")"
		case "$raw" in *"\"$gone\""*)
			kept=""
			for dep in $(deps_ids "$raw"); do
				[ "$dep" = "$gone" ] || kept="$kept $dep"
			done
			# shellcheck disable=SC2086
			line="$(line_set_field "$line" depends_on "$(deps_array $kept)")"
			;;
		esac
		out="$out$line
"
	done <"$BACKLOG_INDEX"
	write_index "$out"
}

remove_by_id() {
	local line rel="" kept
	line="$(grep -F "\"id\":\"$1\"" "$BACKLOG_INDEX" || true)"
	if [ -n "$line" ]; then
		rel="$(json_get file "$line")"
		rm -f "$(task_path "$rel")"
		prune_empty_epic "$(file_epic "$rel")"
	fi
	kept="$(grep -v -F "\"id\":\"$1\"" "$BACKLOG_INDEX" || true)"
	[ -z "$kept" ] || kept="$kept
"
	write_index "$kept"
	prune_dep "$1"
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
			printf '%s\n' "$line"
			found=1
		fi
	done <"$BACKLOG_INDEX"
	[ "$found" -eq 1 ] && return 0

	found=0
	while IFS= read -r line; do
		[ -n "$line" ] || continue
		title="$(json_get title "$line")"
		if [ "$title" = "$q" ]; then
			printf '%s\n' "$line"
			found=1
		fi
	done <"$BACKLOG_INDEX"
	[ "$found" -eq 1 ] && return 0

	lq="$(printf '%s' "$q" | tr '[:upper:]' '[:lower:]')"
	while IFS= read -r line; do
		[ -n "$line" ] || continue
		title="$(json_get title "$line")"
		lt="$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]')"
		case "$lt" in *"$lq"*) printf '%s\n' "$line" ;; esac
	done <"$BACKLOG_INDEX"
	return 0
}

# The one matching raw index line for query $1, or die with what was found.
single_match() {
	local found n
	found="$(matches "$1")"
	[ -n "$found" ] || die "no entry matches: $1"
	n="$(printf '%s\n' "$found" | grep -c '.')"
	[ "$n" -eq 1 ] || die "matches $n entries: $1
$(printf '%s\n' "$found" | fmt_lines)"
	printf '%s\n' "$found"
}

require_integer() {
	case "$1" in
	'' | - | *[!0-9-]* | ?*-*) die "priority must be an integer, got: $1" ;;
	esac
}

# Every id in "$@" must already exist. A missing index just has no known ids,
# so `add`'s first task still reports the unknown id rather than the index.
require_known_ids() {
	local d
	for d in "$@"; do
		grep -qF "\"id\":\"$d\"" "$BACKLOG_INDEX" 2>/dev/null ||
			die "no such task id: $d"
	done
}

# True when target $1 is reachable from the ids in "$@". The seen list is what
# stops a graph that already has a cycle from looping forever.
deps_reaches() {
	local target="$1" pending frontier seen="" cur line
	shift
	pending="$*"
	while [ -n "$pending" ]; do
		frontier="$pending"
		pending=""
		for cur in $frontier; do
			[ "$cur" != "$target" ] || return 0
			case " $seen " in *" $cur "*) continue ;; esac
			seen="$seen $cur"
			line="$(grep -F "\"id\":\"$cur\"" "$BACKLOG_INDEX" || true)"
			[ -n "$line" ] || continue
			pending="$pending $(deps_ids "$(json_get_raw depends_on "$line")")"
		done
	done
	return 1
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
		# One pass in `file` order: flat tasks first, then each epic's
		# children below its shared context, so a human reading `show`
		# sees the hierarchy the `file` paths encode.
		printf '%s' "$section" | while IFS= read -r line; do
			[ -n "$line" ] || continue
			printf '%s\t%s\n' "$(file_epic "$(json_get file "$line")")" "$line"
		done | sort -s -t"$(printf '\t')" -k1,1 | {
			cur=""
			while IFS= read -r keyed; do
				epic="${keyed%%$'\t'*}"
				line="${keyed#*$'\t'}"
				if [ "$epic" != "$cur" ]; then
					cur="$epic"
					printf '\n### epic: %s\n' "$epic"
					[ ! -s "$BACKLOG_TASKS_DIR/$epic/DESCRIPTION.md" ] ||
						cat "$BACKLOG_TASKS_DIR/$epic/DESCRIPTION.md"
				fi
				if [ -z "$epic" ]; then level='###'; else level='####'; fi
				printf '\n%s %s\n' "$level" "$(json_get title "$line")"
				cat "$(task_path "$(json_get file "$line")")"
			done
		}
	done
	;;

list)
	require_index
	# Priority descending with unset last is the ordering contract, not a
	# display choice: a consumer reads this order as the human's ranking.
	# -s keeps equal priorities in index order.
	ranked=""
	unranked=""
	while IFS= read -r line; do
		[ -n "$line" ] || continue
		prio="$(json_get_raw priority "$line")"
		if [ -n "$prio" ]; then
			ranked="$ranked$prio	$(fmt_line "$line")
"
		else
			unranked="$unranked$(fmt_line "$line")
"
		fi
	done <"$BACKLOG_INDEX"
	[ -z "$ranked" ] || printf '%s' "$ranked" | sort -s -k1,1nr | cut -f2-
	[ -z "$unranked" ] || printf '%s' "$unranked"
	;;

find)
	[ -n "${2:-}" ] || die "usage: find <id-or-title>"
	require_index
	out="$(matches "$2" | fmt_lines)"
	[ -n "$out" ] || die "no entry matches: $2"
	printf '%s\n' "$out"
	;;

add)
	category="${2:-}"
	title="${3:-}"
	[ -n "$title" ] || die "usage: add <category> <title> [--epic <epic-id>] [--skill <name>]... [--priority <n>] [--depends-on <csv>]  (body on stdin)"
	case "$category" in
	feat | fix | chore | refactor) ;;
	*) die "category must be feat|fix|chore|refactor, got: $category" ;;
	esac
	shift 3
	skills=""
	epic=""
	priority=""
	deps=""
	while [ $# -gt 0 ]; do
		case "$1" in
		--priority)
			[ -n "${2:-}" ] || die "--priority needs an integer"
			require_integer "$2"
			priority="$2"
			shift 2
			;;
		--depends-on)
			[ -n "${2:-}" ] || die "--depends-on needs a csv of task ids"
			deps="$(printf '%s' "$2" | tr ',' ' ')"
			# Checked before the task file is written, so a bad flag
			# leaves no orphan body behind.
			# shellcheck disable=SC2086
			require_known_ids $deps
			shift 2
			;;
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
	# shellcheck disable=SC2086
	dep_array="$(deps_array $deps)"
	compose_line "$id" "$category" "$title" "$rel" "$priority" "$dep_array" >>"$BACKLOG_INDEX"
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
	entry="$(single_match "$2")"
	in_acceptance=""
	while IFS= read -r line || [ -n "$line" ]; do
		if [ -n "$in_acceptance" ]; then
			case "$line" in
			'- '*)
				crit="${line#- }"
				case "$crit" in
				'[ ] '* | '[x] '* | '[X] '*)
					crit="${crit#????}"
					;;
				esac
				printf 'acceptance\t%s\n' "$crit"
				continue
				;;
			*) in_acceptance="" ;;
			esac
		fi
		case "$line" in
		'**Plan:** '*) printf 'plan\t%s\n' "${line#"**Plan:** "}" ;;
		'**Skill:** '*) printf 'skill\t%s\n' "${line#"**Skill:** "}" ;;
		'**Acceptance:**') in_acceptance=1 ;;
		esac
	done <"$(task_path "$(json_get file "$entry")")"
	;;

planned)
	require_index
	while IFS= read -r line; do
		[ -n "$line" ] || continue
		f="$(task_path "$(json_get file "$line")")"
		[ -f "$f" ] || continue
		grep -q '^\*\*Plan:\*\* ' "$f" || continue
		printf '%s\n' "$(json_get id "$line")"
	done <"$BACKLOG_INDEX"
	;;

append)
	[ -n "${2:-}" ] || die "usage: append <id-or-title>  (text on stdin)"
	require_index
	entry="$(single_match "$2")"
	BODY="$(cat)"
	[ -n "$BODY" ] || die "append text is empty (pass it on stdin)"
	printf '\n%s\n' "$BODY" >>"$(task_path "$(json_get file "$entry")")"
	printf 'appended to "%s"\n' "$(json_get title "$entry")"
	;;

add-plan)
	query="${2:-}"
	plan_path="${3:-}"
	[ -n "$plan_path" ] || die "usage: add-plan <id-or-title> <plan-path>"
	require_index
	entry="$(single_match "$query")"
	printf '**Plan:** %s\n' "$plan_path" >>"$(task_path "$(json_get file "$entry")")"
	printf 'plan pointer added to "%s"\n' "$(json_get title "$entry")"
	;;

path)
	[ -n "${2:-}" ] || die "usage: path <id-or-title>"
	require_index
	entry="$(single_match "$2")"
	task_path "$(json_get file "$entry")"
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
	entry="$(single_match "$query")"
	id="$(json_get id "$entry")"
	set_index_field "$id" category "$newcat"
	printf 'moved "%s" to %s\n' "$(json_get title "$entry")" "$newcat"
	;;

retitle)
	query="${2:-}"
	newtitle="${3:-}"
	[ -n "$newtitle" ] || die "usage: retitle <id-or-title> <new-title>"
	require_plain_title "$newtitle"
	require_index
	entry="$(single_match "$query")"
	id="$(json_get id "$entry")"
	set_index_field "$id" title "$newtitle"
	printf 'retitled %s to "%s"\n' "$id" "$newtitle"
	;;

set-priority)
	query="${2:-}"
	value="${3:-}"
	[ -n "$value" ] || die "usage: set-priority <id-or-title> <integer|--none>"
	[ "$value" = "--none" ] || require_integer "$value"
	require_index
	entry="$(single_match "$query")"
	id="$(json_get id "$entry")"
	newprio="$value"
	[ "$value" != "--none" ] || newprio=""
	set_index_field "$id" priority "$newprio"
	printf 'priority of %s set to %s\n' "$id" "$value"
	;;

set-deps)
	query="${2:-}"
	value="${3:-}"
	[ -n "$value" ] || die "usage: set-deps <id-or-title> <csv-of-ids|--none>"
	require_index
	entry="$(single_match "$query")"
	id="$(json_get id "$entry")"
	if [ "$value" = "--none" ]; then
		dep_array=""
	else
		deps="$(printf '%s' "$value" | tr ',' ' ')"
		# Validation lives here, not in a skill: an unknown id or a cycle
		# makes `radin state deps-check` wait forever instead of failing.
		# shellcheck disable=SC2086
		require_known_ids $deps
		# shellcheck disable=SC2086
		deps_reaches "$id" $deps &&
			die "depends_on would create a cycle through $id"
		# shellcheck disable=SC2086
		dep_array="$(deps_array $deps)"
	fi
	set_index_field "$id" depends_on "$dep_array"
	printf 'depends_on of %s set to %s\n' "$id" "$value"
	;;

remove)
	query="${2:-}"
	[ -n "$query" ] || die "usage: remove <id-or-title>"
	require_index
	entry="$(single_match "$query")"
	id="$(json_get id "$entry")"
	title="$(json_get title "$entry")"
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

epic-show)
	epic="${2:-}"
	[ -n "$epic" ] || die "usage: epic-show <epic-id>"
	require_epic_id "$epic"
	[ ! -s "$BACKLOG_TASKS_DIR/$epic/DESCRIPTION.md" ] ||
		cat "$BACKLOG_TASKS_DIR/$epic/DESCRIPTION.md"
	;;

epic-move)
	query="${2:-}"
	target="${3:-}"
	[ -n "$target" ] || die "usage: epic-move <id-or-title> <epic-id|--none>"
	require_index
	entry="$(single_match "$query")"
	id="$(json_get id "$entry")"
	old_rel="$(json_get file "$entry")"
	if [ "$target" = "--none" ]; then
		new_rel="tasks/$id.md"
	else
		require_epic_id "$target"
		new_rel="tasks/$target/$id.md"
	fi
	[ "$old_rel" != "$new_rel" ] || die "already there: $old_rel"
	mv "$(task_path "$old_rel")" "$(task_path "$new_rel")"
	set_index_field "$id" file "$new_rel"
	prune_empty_epic "$(file_epic "$old_rel")"
	printf 'moved %s to %s\n' "$id" "$new_rel"
	;;

epic-remove)
	epic="${2:-}"
	[ -n "$epic" ] || die "usage: epic-remove <epic-id>"
	require_epic_id "$epic"
	# Never recursively delete tasks: the operator moves them out first.
	epic_is_empty "$epic" ||
		die "epic $epic still holds child tasks; epic-move them out first"
	rm -f "$BACKLOG_TASKS_DIR/$epic/DESCRIPTION.md"
	rmdir "$BACKLOG_TASKS_DIR/$epic"
	printf 'removed epic %s\n' "$epic"
	;;

*)
	die "unknown command: ${cmd:-<none>} (env|show|list|count|find|add|add-plan|append|meta|planned|path|set-category|retitle|set-priority|set-deps|remove|reconcile|epics|epic-add|epic-show|epic-move|epic-remove)"
	;;
esac

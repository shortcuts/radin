#!/usr/bin/env bash
# Deterministic BACKLOG.md operations, so agents/skills don't hand-edit the
# file. Installed to ~/.claude/.radin/lib/radin-backlog.sh by install.sh.
#
# Usage:
#   radin-backlog.sh env                        # print REPO_ROOT/NAMESPACE_DIR/BACKLOG_FILE
#   radin-backlog.sh show [category]            # print backlog, or one ## section
#   radin-backlog.sh list                       # print "start<TAB>end<TAB>title" for every entry
#   radin-backlog.sh find <title>               # print "start<TAB>end<TAB>title" per matching entry
#   radin-backlog.sh add <category> <title>     # append entry, body read from stdin
#   radin-backlog.sh add-plan <title> <path>    # insert "**Plan:** <path>" at end of entry
#   radin-backlog.sh remove <title>             # delete entry (exact single match required)
#
# Categories: feat | fix | chore | refactor (canonical section order).
# `find` matches the exact title first, then falls back to case-insensitive
# substring; multiple lines out means ambiguity the caller must resolve.
# Must stay bash-3.2-compatible (macOS /bin/bash).
set -euo pipefail

die() {
	printf 'radin-backlog: %s\n' "$*" >&2
	exit 1
}

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
eval "$(bash "$LIB_DIR/radin-namespace.sh")"

# Prints "start<TAB>end<TAB>title" for every ### entry (end = last line
# before the next ##/### heading, or EOF).
spans() {
	awk '
		function flush(end) { if (s) printf "%d\t%d\t%s\n", s, end, t; s = 0 }
		/^### / { flush(NR - 1); s = NR; t = substr($0, 5) }
		/^## /  { flush(NR - 1) }
		END     { flush(NR) }
	' "$BACKLOG_FILE"
}

# Matching span lines for $1: exact title match, else case-insensitive substring.
matches() {
	spans | awk -F '\t' -v q="$1" '
		{ line[NR] = $0; title[NR] = $3 }
		title[NR] == q { exact[++ne] = NR }
		END {
			if (ne) { for (i = 1; i <= ne; i++) print line[exact[i]]; exit }
			lq = tolower(q)
			for (i = 1; i <= NR; i++) if (index(tolower(title[i]), lq)) print line[i]
		}
	'
}

# One exact-single-match span for $1, or die with what was found.
single_match() {
	local found n
	found="$(matches "$1")"
	[ -n "$found" ] || die "no entry matches title: $1"
	n="$(printf '%s\n' "$found" | wc -l | tr -d ' ')"
	[ "$n" -eq 1 ] || die "title matches $n entries: $1
$found"
	printf '%s\n' "$found"
}

require_backlog() {
	[ -s "$BACKLOG_FILE" ] || die "no backlog at $BACKLOG_FILE"
}

rewrite() {
	local tmp
	tmp="$(mktemp)"
	cat >"$tmp"
	mv "$tmp" "$BACKLOG_FILE"
}

cmd="${1:-}"
case "$cmd" in
env)
	bash "$LIB_DIR/radin-namespace.sh"
	;;

show)
	require_backlog
	if [ -n "${2:-}" ]; then
		awk -v sec="$2" '
			/^## / { on = (substr($0, 4) == sec) }
			on
		' "$BACKLOG_FILE"
	else
		cat "$BACKLOG_FILE"
	fi
	;;

list)
	require_backlog
	spans
	;;

find)
	[ -n "${2:-}" ] || die "usage: find <title>"
	require_backlog
	out="$(matches "$2")"
	[ -n "$out" ] || die "no entry matches title: $2"
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
	[ -s "$BACKLOG_FILE" ] || printf '# Backlog\n' >"$BACKLOG_FILE"
	BODY="$(cat)"
	[ -n "$BODY" ] || die "entry body is empty (pass it on stdin)"
	export BODY
	awk -v cat="$category" -v title="$title" '
		function emit() {
			if (newsec) printf "\n## %s\n", cat
			printf "\n### %s\n%s\n", title, ENVIRON["BODY"]
		}
		BEGIN { r["feat"] = 1; r["fix"] = 2; r["chore"] = 3; r["refactor"] = 4 }
		{
			line[NR] = $0
			if ($0 ~ /^## /) { secline[++ns] = NR; secname[ns] = substr($0, 4) }
		}
		END {
			insert_at = 0 # 0 = append at EOF
			newsec = 1
			for (i = 1; i <= ns; i++)
				if (secname[i] == cat) {
					newsec = 0
					insert_at = (i < ns) ? secline[i + 1] : 0
				}
			if (newsec)
				for (i = 1; i <= ns; i++)
					if (r[secname[i]] > r[cat]) { insert_at = secline[i]; break }
			for (n = 1; n <= NR; n++) {
				if (n == insert_at) { emit(); printf "\n" }
				print line[n]
			}
			if (!insert_at) emit()
		}
	' "$BACKLOG_FILE" | rewrite
	printf 'added "%s" under ## %s in %s\n' "$title" "$category" "$BACKLOG_FILE"
	;;

add-plan)
	title="${2:-}"
	plan_path="${3:-}"
	[ -n "$plan_path" ] || die "usage: add-plan <title> <plan-path>"
	require_backlog
	span="$(single_match "$title")"
	start="$(printf '%s' "$span" | cut -f1)"
	end="$(printf '%s' "$span" | cut -f2)"
	# Insert after the entry's last non-blank line, not after trailing blanks.
	end="$(awk -v s="$start" -v e="$end" 'NR >= s && NR <= e && NF { last = NR } END { print last }' "$BACKLOG_FILE")"
	PLAN_PATH="$plan_path" export PLAN_PATH
	awk -v end="$end" '
		{ print }
		NR == end { printf "**Plan:** %s\n", ENVIRON["PLAN_PATH"] }
	' "$BACKLOG_FILE" | rewrite
	printf 'plan pointer added to "%s"\n' "$title"
	;;

remove)
	title="${2:-}"
	[ -n "$title" ] || die "usage: remove <title>"
	require_backlog
	span="$(single_match "$title")"
	start="$(printf '%s' "$span" | cut -f1)"
	end="$(printf '%s' "$span" | cut -f2)"
	awk -v s="$start" -v e="$end" 'NR < s || NR > e' "$BACKLOG_FILE" | rewrite
	printf 'removed "%s" (lines %s-%s)\n' "$title" "$start" "$end"
	;;

*)
	die "unknown command: ${cmd:-<none>} (env|show|list|find|add|add-plan|remove)"
	;;
esac

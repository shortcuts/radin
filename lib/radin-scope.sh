#!/usr/bin/env bash
# Deterministic review-scope resolution for radin-review, so the skill
# doesn't probe git/gh by hand.
# Installed to ~/.claude/.radin/lib/radin-scope.sh by install.sh.
#
# Usage: radin-scope.sh [arg]
#        radin-scope.sh --in-scope [arg]   # classify "path:line" lines on stdin
#        radin-scope.sh --tasks [arg]      # completed task ids the scope covers
#
# No arg: the current branch's diff against its merge-base with main/master.
# With arg: a commit-ish, a PR reference (#123, 123, GitHub PR URL), a
# directory path, a range (`last commit`, `last <n> commits`, `<rev>..<rev>`),
# or a date phrase (`since yesterday`, `since last week`).
#
# Output (TAB-separated key/value lines):
#   type    commit|pr|dir|branch-diff|range
#   scope   <normalized scope>
#   command <the diff/read command to run>
#   passes  <the ponytail skill(s) this scope type calls for>
# --in-scope resolves the same scope, then prints one `in<TAB>path:line` /
# `out<TAB>path:line` line per stdin citation in input order, then one final
# `dropped<TAB><n>`. A citation is `in` when the scope introduced that line:
# under the directory for a dir scope, inside a diff hunk otherwise.
# --tasks resolves the same scope, then prints one completed task id per line
# for the commits it covers: deduplicated, in commit order, joined through
# `radin state trace` against `state/completed.json`. A `dir` scope has no
# commit list, so it prints nothing.
# Exit: 0 resolved (--in-scope and --tasks too, even when they print nothing);
# 1 unrecognized; 2 ambiguous (each candidate reading printed to stderr).
# Must stay bash-3.2-compatible (macOS /bin/bash).
set -euo pipefail

TAB="$(printf '\t')"

die() {
	printf 'radin-scope: %s\n' "$*" >&2
	exit 1
}

emit() {
	# The type-dependent ponytail passes are named here, not in the skill:
	# mapping type -> pass was the last thing radin-review computed from this
	# script's own output. thermo-nuclear is unconditional, so it stays named
	# in the skill -- there is no mapping to own.
	local passes
	case "$1" in
	dir) passes='/ponytail:ponytail-audit /ponytail:ponytail-debt' ;;
	*) passes='/ponytail:ponytail-review' ;;
	esac
	printf 'type\t%s\nscope\t%s\ncommand\t%s\npasses\t%s\n' "$1" "$2" "$3" "$passes"
}

pr_ok() {
	command -v gh >/dev/null 2>&1 || return 1
	# $2 is an optional "--repo owner/repo" pair, split on purpose.
	# shellcheck disable=SC2086
	gh pr view "$1" ${2:-} >/dev/null 2>&1
}

# --in-scope re-resolves through this same script rather than restructuring
# every `emit ... ; exit 0` into a capture, so there is one resolution path.
if [ "${1:-}" = "--in-scope" ]; then
	shift
	resolved="$(bash "$0" "${1:-}")" || exit $?
	stype="$(printf '%s\n' "$resolved" | sed -n "s/^type$TAB//p")"
	sscope="$(printf '%s\n' "$resolved" | sed -n "s/^scope$TAB//p")"
	scommand="$(printf '%s\n' "$resolved" | sed -n "s/^command$TAB//p")"
	if [ "$stype" = dir ]; then
		exec awk -v dir="${sscope%/}/" '
			$0 != "" { p = $0; sub(/^\.\//, "", p)
				if (index(p, dir) == 1) print "in\t" $0
				else { print "out\t" $0; d++ } }
			END { printf "dropped\t%d\n", d + 0 }'
	fi
	# ponytail: PR diffs keep default context, so a citation within 3 lines of
	# a hunk counts as in-scope; render gh pr diff through -U0 if the
	# over-keeping ever matters.
	case "$scommand" in 'git diff'*) scommand="$scommand --unified=0" ;; esac
	diff_file="$(mktemp)"
	cites_file="$(mktemp)"
	trap 'rm -f "$diff_file" "$cites_file"' EXIT
	cat >"$cites_file"
	# The command comes from this script's own `emit`, never from stdin.
	# shellcheck disable=SC2086
	eval $scommand >"$diff_file"
	awk '
		NR == FNR {
			if (substr($0, 1, 4) == "+++ ") { f = $2; sub(/^b\//, "", f); next }
			if (substr($0, 1, 3) == "@@ ") {
				r = $3; sub(/^\+/, "", r)
				n = index(r, ",")
				if (n) { s = substr(r, 1, n - 1) + 0; c = substr(r, n + 1) + 0 }
				else { s = r + 0; c = 1 }
				for (i = 0; i < c; i++) seen[f SUBSEP (s + i)] = 1
			}
			next
		}
		$0 != "" {
			p = $0; sub(/:[^:]*$/, "", p); sub(/^\.\//, "", p)
			l = $0; sub(/^.*:/, "", l); sub(/-.*$/, "", l)
			if ((p SUBSEP (l + 0)) in seen) print "in\t" $0
			else { print "out\t" $0; d++ }
		}
		END { printf "dropped\t%d\n", d + 0 }
	' "$diff_file" "$cites_file"
	exit 0
fi

# --tasks re-resolves through this same script for the same reason --in-scope
# does: one resolution path. The scope-type branching below is the whole point
# of the flag -- it is what the review skill used to do itself.
if [ "${1:-}" = "--tasks" ]; then
	shift
	resolved="$(bash "$0" "${1:-}")" || exit $?
	stype="$(printf '%s\n' "$resolved" | sed -n "s/^type$TAB//p")"
	sscope="$(printf '%s\n' "$resolved" | sed -n "s/^scope$TAB//p")"
	hashes=""
	case "$stype" in
	commit) hashes="$(git log -1 --format=%H "$sscope")" ;;
	# A `since <date>` window reaching the root commit has the empty tree as
	# its left side; `git log <empty-tree>..HEAD` lists the whole history, so
	# that case needs no fallback of its own.
	range | branch-diff) hashes="$(git log --format=%H "$sscope")" ;;
	pr)
		# "#123" or "#123 (owner/repo)"
		num="${sscope#\#}"
		num="${num%% *}"
		repo=""
		case "$sscope" in *'('*)
			repo="${sscope#*(}"
			repo="--repo ${repo%)*}"
			;;
		esac
		# shellcheck disable=SC2086
		hashes="$(gh pr view "$num" $repo --json commits --jq '.commits[].oid')"
		;;
	# A dir scope reviews the files as they stand: no commit list, no ids.
	dir) exit 0 ;;
	esac
	LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	# shellcheck disable=SC1091
	. "$LIB_DIR/radin-namespace.sh"
	seen=""
	# ponytail: one `trace` fork per commit; give `radin state trace` a batch
	# mode if a wide range ever makes that matter.
	for h in $hashes; do
		[ -n "$h" ] || continue
		# `trace` exits 1 for a commit no task completed and 2 when the hash
		# also reads as an id or branch; stdout is empty either way.
		traced="$(bash "$LIB_DIR/radin-state.sh" trace "$h" 2>/dev/null || true)"
		for id in $(printf '%s\n' "$traced" | sed -n "s/^task$TAB//p"); do
			case " $seen " in *" $id "*) continue ;; esac
			seen="$seen $id"
			printf '%s\n' "$id"
		done
	done
	exit 0
fi

arg="${1:-}"

if [ -z "$arg" ]; then
	git rev-parse --git-dir >/dev/null 2>&1 || die "not in a git repo and no scope argument given"
	base_branch=""
	git rev-parse --verify -q main >/dev/null 2>&1 && base_branch=main
	if [ -z "$base_branch" ]; then
		git rev-parse --verify -q master >/dev/null 2>&1 && base_branch=master
	fi
	[ -n "$base_branch" ] || die "no main or master branch to diff against"
	base="$(git merge-base "$base_branch" HEAD)"
	emit branch-diff "$base..HEAD" "git diff $base..HEAD"
	exit 0
fi

# Unambiguous-by-shape PR references: #123 and GitHub PR URLs.
case "$arg" in
'#'*)
	num="${arg#\#}"
	case "$num" in '' | *[!0-9]*) die "not a PR number: $arg" ;; esac
	pr_ok "$num" || {
		printf 'radin-scope: PR #%s does not resolve via gh\n' "$num" >&2
		exit 1
	}
	emit pr "#$num" "gh pr diff $num"
	exit 0
	;;
https://github.com/*/pull/*)
	rest="${arg#https://github.com/}"
	repo="${rest%%/pull/*}"
	num="${rest##*/pull/}"
	num="${num%%[!0-9]*}"
	[ -n "$num" ] || die "no PR number in URL: $arg"
	pr_ok "$num" "--repo $repo" || {
		printf 'radin-scope: %s does not resolve via gh\n' "$arg" >&2
		exit 1
	}
	emit pr "#$num ($repo)" "gh pr diff $num --repo $repo"
	exit 0
	;;
esac

# Two range shapes the script can validate without parsing English.
case "$arg" in
'last commit')
	git rev-parse --git-dir >/dev/null 2>&1 || die "not in a git repo: $arg"
	emit range "HEAD~1..HEAD" "git diff HEAD~1..HEAD"
	exit 0
	;;
'last '*' commits')
	n="${arg#last }"
	n="${n% commits}"
	case "$n" in '' | *[!0-9]*) die "not a commit count: $arg" ;; esac
	git rev-parse --git-dir >/dev/null 2>&1 || die "not in a git repo: $arg"
	git rev-parse --verify -q "HEAD~$n" >/dev/null 2>&1 ||
		die "history is shorter than $n commits"
	emit range "HEAD~$n..HEAD" "git diff HEAD~$n..HEAD"
	exit 0
	;;
*..*)
	git rev-parse --git-dir >/dev/null 2>&1 || die "not in a git repo: $arg"
	left="${arg%%..*}"
	right="${arg##*..}"
	right="${right#.}"
	for rev in "$left" "$right"; do
		[ -z "$rev" ] && continue
		git rev-parse --verify -q "$rev" >/dev/null 2>&1 ||
			die "not a revision: $rev"
	done
	emit range "$arg" "git diff $arg"
	exit 0
	;;
esac

# A bare token can read several ways -- collect every valid one.
candidates=0
pr_line=""
commit_line=""
dir_line=""

case "$arg" in
*[!0-9]*) ;;
*)
	if pr_ok "$arg"; then
		pr_line="$(emit pr "#$arg" "gh pr diff $arg")"
		candidates=$((candidates + 1))
	fi
	;;
esac

if git rev-parse --git-dir >/dev/null 2>&1; then
	obj_type="$(git cat-file -t "$arg" 2>/dev/null || true)"
	case "$obj_type" in
	commit | tag)
		commit_line="$(emit commit "$arg" "git diff $arg^..$arg")"
		candidates=$((candidates + 1))
		;;
	esac
fi

if [ -d "$arg" ]; then
	dir_line="$(emit dir "$arg" "read the files under $arg as they stand")"
	candidates=$((candidates + 1))
fi

if [ "$candidates" -eq 1 ]; then
	printf '%s\n' "$pr_line$commit_line$dir_line"
	exit 0
fi
if [ "$candidates" -gt 1 ]; then
	printf 'radin-scope: "%s" is ambiguous, %d candidate readings:\n' "$arg" "$candidates" >&2
	for c in "$pr_line" "$commit_line" "$dir_line"; do
		if [ -n "$c" ]; then printf '%s\n---\n' "$c" >&2; fi
	done
	exit 2
fi
# `since <phrase>` hands the phrase to approxidate, which accepts any garbage:
# the `since ` prefix is what keeps an unrecognized argument out of this branch.
if [ "$candidates" -eq 0 ] && [ "$arg" != "${arg#since }" ] &&
	git rev-parse --git-dir >/dev/null 2>&1; then
	# `git log -1 --reverse` returns the newest commit in the window: `-1`
	# applies before `--reverse`, so `tail -1` is what gets the oldest.
	oldest="$(git log --since="${arg#since }" --format=%H 2>/dev/null | tail -1)"
	if [ -n "$oldest" ]; then
		if git rev-parse --verify -q "$oldest~1" >/dev/null 2>&1; then
			left="$oldest~1"
		else
			# The window reaches the root commit, which has no parent.
			left="$(git hash-object -t tree /dev/null)"
		fi
		emit range "$left..HEAD" "git diff $left..HEAD"
		exit 0
	fi
fi

printf 'radin-scope: "%s" is not a commit, PR, directory, range, or since-date here\n' "$arg" >&2
exit 1

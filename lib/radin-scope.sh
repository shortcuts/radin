#!/usr/bin/env bash
# Deterministic review-scope resolution for radin-review, so the skill
# doesn't probe git/gh by hand.
# Installed to ~/.claude/.radin/lib/radin-scope.sh by install.sh.
#
# Usage: radin-scope.sh [arg]
#        radin-scope.sh --in-scope [arg]   # classify "path:line" lines on stdin
#        radin-scope.sh --commits [arg]    # the scope's commits, "<hash> <subject>"
#        radin-scope.sh --specs [arg]      # candidate specs, "id created branch commit source", oldest first
#        radin-scope.sh --attribute [arg]  # map "path:line" lines on stdin to task + plan
#
# No arg: the current branch's diff against its merge-base with main/master.
# With arg: a commit-ish, a PR reference (#123, 123, GitHub PR URL), a
# directory path, a range (`last commit`, `last <n> commits`, `<rev>..<rev>`),
# a date phrase (`since yesterday`, `since last week`), or `staged`: the index
# diff, which a task reviews before it commits.
#
# Output (TAB-separated key/value lines):
#   type    commit|pr|dir|branch-diff|range|staged
#   scope   <normalized scope>
#   command <the diff/read command to run>
#   passes  <the ponytail skill(s) this scope type adds beyond the core's; empty unless dir>
# --in-scope resolves the same scope, then prints one `in<TAB>path:line` /
# `out<TAB>path:line` line per stdin citation in input order, then one final
# `dropped<TAB><n>`. A citation is `in` when the scope introduced that line:
# under the directory for a dir scope, inside a diff hunk otherwise.
# --commits resolves the same scope, then prints one "<hash> <subject>" line
# per commit it covers: newest first for git scopes, gh's order for a PR, and
# nothing for a `dir` scope.
# --attribute resolves the same scope, then prints `<citation><TAB><task id>
# <TAB><plan path|none>` per stdin citation in input order. The cited line is
# blamed; it maps only when the blamed commit is one of the scope's commits,
# joined through `radin state trace`. Anything else prints `none` twice.
# Exit: 0 resolved (--in-scope, --commits, --specs and --attribute too, even when they print nothing);
# 1 unrecognized; 2 ambiguous (each candidate reading printed to stderr).
# Must stay bash-3.2-compatible (macOS /bin/bash).
set -euo pipefail

TAB="$(printf '\t')"

die() {
	printf 'radin-scope: %s\n' "$*" >&2
	exit 1
}

emit() {
	# The type-dependent ponytail passes are named here, not in the skill.
	# Non-dir scopes add none: radin-review-core already runs ponytail-review
	# at levels diff and session, and a repeat reviews the diff twice.
	local passes
	case "$1" in
	dir) passes='/ponytail:ponytail-audit /ponytail:ponytail-debt' ;;
	*) passes='' ;;
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

# --commits re-resolve through this same script for the same
# reason --in-scope does: one resolution path. The scope-type branching below
# is the whole point of the flags -- it is what the review skill used to do
# itself.
if [ "${1:-}" = "--commits" ]; then
	shift
	resolved="$(bash "$0" "${1:-}")" || exit $?
	stype="$(printf '%s\n' "$resolved" | sed -n "s/^type$TAB//p")"
	sscope="$(printf '%s\n' "$resolved" | sed -n "s/^scope$TAB//p")"
	case "$stype" in
	commit) git log -1 --format='%H %s' "$sscope" ;;
	# A `since <date>` window reaching the root commit has the empty tree as
	# its left side; `git log <empty-tree>..HEAD` lists the whole history, so
	# that case needs no fallback of its own.
	range | branch-diff) git log --format='%H %s' "$sscope" ;;
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
		gh pr view "$num" $repo --json commits --jq '.commits[] | .oid + " " + .messageHeadline'
		;;
	# A dir scope reviews the files as they stand, a staged one has no commit
	# yet: no commit list.
	dir | staged) ;;
	esac
	exit 0
fi

# --specs: every task a review of this scope could take as its spec, oldest
# first. A completed task joins by its recorded commit (`commit`); when a
# squash or rebase rewrote that commit, by the review branch's reflog
# (`reflog`); a still-open entry recorded on the review branch joins as
# `pending`. Exit 4: a recorded commit no longer exists and HEAD sits on no
# branch, so the reflog fallback has nothing to read.
if [ "${1:-}" = "--specs" ]; then
	shift
	commits="$(bash "$0" --commits "${1:-}")" || exit $?
	hashes="$(printf '%s\n' "$commits" | cut -d' ' -f1)"
	LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	# shellcheck disable=SC1091
	. "$LIB_DIR/radin-namespace.sh"
	branch="$(git symbolic-ref --short -q HEAD 2>/dev/null || true)"
	reflog=""
	[ -z "$branch" ] || reflog="$(git reflog show --format=%H "$branch" 2>/dev/null || true)"
	rows=""
	done_ids=" "
	# ponytail: one `completed-show` fork per completed task; batch it if the
	# completed log ever grows past a few hundred lines.
	while IFS="$TAB" read -r id c; do
		[ -n "$id" ] || continue
		done_ids="$done_ids$id "
		case "$c" in ???????*) ;; *) continue ;; esac
		source=""
		for h in $hashes; do
			case "$c" in "$h"*) source=commit ;; esac
			case "$h" in "$c"*) source=commit ;; esac
		done
		if [ -z "$source" ]; then
			if [ -z "$branch" ] && ! git cat-file -e "$c^{commit}" 2>/dev/null; then
				printf 'radin-scope: commit %s of task %s no longer exists and HEAD has no branch to search the reflog of\n' "$c" "$id" >&2
				exit 4
			fi
			printf '%s\n' "$reflog" | grep -q "^$c" && source=reflog
		fi
		[ -n "$source" ] || continue
		shown="$(bash "$LIB_DIR/radin-state.sh" completed-show "$id" 2>/dev/null || true)"
		rows="$rows$id$TAB$(printf '%s\n' "$shown" | sed -n "s/^created$TAB//p")$TAB$(printf '%s\n' "$shown" | sed -n "s/^branch$TAB//p")$TAB$c$TAB$source
"
	done < <(bash "$LIB_DIR/radin-state.sh" completed-list 2>/dev/null || true)
	if [ -n "$branch" ]; then
		while IFS="$TAB" read -r id created b; do
			[ -n "$id" ] || continue
			case "$done_ids" in *" $id "*) continue ;; esac
			rows="$rows$id$TAB$created$TAB$b$TAB${TAB}pending
"
		done < <(bash "$LIB_DIR/radin-backlog.sh" stamps "$branch" 2>/dev/null || true)
	fi
	[ -z "$rows" ] || printf '%s' "$rows" | sort -s -t "$TAB" -k2,2
	exit 0
fi

if [ "${1:-}" = "--attribute" ]; then
	shift
	commits="$(bash "$0" --commits "${1:-}")" || exit $?
	hashes=" $(printf '%s\n' "$commits" | cut -d' ' -f1 | tr '\n' ' ') "
	LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	# ponytail: one `blame` and one `trace` fork per citation; cache per hash
	# if a wide review ever makes that matter (bash 3.2 has no assoc arrays).
	while IFS= read -r cite || [ -n "$cite" ]; do
		[ -n "$cite" ] || continue
		p="${cite%:*}"
		p="${p#./}"
		l="${cite##*:}"
		l="${l%%-*}"
		task=""
		plan=""
		case "$l" in '' | *[!0-9]*) ;; *)
			h="$(git blame --porcelain -L "$l,$l" -- "$p" 2>/dev/null | sed -n '1s/ .*//p' || true)"
			case "$h" in '' | *[!0-9a-f]*) h="" ;; esac
			[ -n "$h" ] && case "$hashes" in *" $h "*)
				traced="$(bash "$LIB_DIR/radin-state.sh" trace "$h" 2>/dev/null || true)"
				task="$(printf '%s\n' "$traced" | sed -n "s/^task$TAB//p" | head -n 1)"
				plan="$(printf '%s\n' "$traced" | sed -n "s/^plan$TAB//p" | head -n 1)"
				;;
			esac
			;;
		esac
		printf '%s\t%s\t%s\n' "$cite" "${task:-none}" "${plan:-none}"
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
staged)
	git rev-parse --git-dir >/dev/null 2>&1 || die "not in a git repo: $arg"
	emit staged "staged" "git diff --cached"
	exit 0
	;;
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

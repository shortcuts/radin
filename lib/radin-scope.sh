#!/usr/bin/env bash
# Deterministic review-scope resolution for radin-review, so the skill
# doesn't probe git/gh by hand. Natural-language ranges ("since yesterday")
# stay the caller's job -- this script only settles the mechanical cases.
# Installed to ~/.claude/.radin/lib/radin-scope.sh by install.sh.
#
# Usage: radin-scope.sh [arg]
#
# No arg: the current branch's diff against its merge-base with main/master.
# With arg: a commit-ish, a PR reference (#123, 123, GitHub PR URL), or a
# directory path.
#
# Output (TAB-separated key/value lines):
#   type    commit|pr|dir|branch-diff
#   scope   <normalized scope>
#   command <the diff/read command to run>
# Exit: 0 resolved; 1 unrecognized (caller decides, e.g. a natural-language
# range); 2 ambiguous (each candidate reading printed to stderr).
# Must stay bash-3.2-compatible (macOS /bin/bash).
set -euo pipefail

die() {
	printf 'radin-scope: %s\n' "$*" >&2
	exit 1
}

emit() {
	printf 'type\t%s\nscope\t%s\ncommand\t%s\n' "$1" "$2" "$3"
}

pr_ok() {
	command -v gh >/dev/null 2>&1 || return 1
	# $2 is an optional "--repo owner/repo" pair, split on purpose.
	# shellcheck disable=SC2086
	gh pr view "$1" ${2:-} >/dev/null 2>&1
}

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
printf 'radin-scope: "%s" is not a commit, PR, or directory here\n' "$arg" >&2
exit 1

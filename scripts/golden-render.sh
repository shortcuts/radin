#!/usr/bin/env bash
# Usage: scripts/golden-render.sh <home>. Prints one sha256 line per installed
# SKILL.md and lib/*.md under <home>, keyed by name, not by path.
# Baked paths are normalised first: the install home differs per run, and the
# later move to ~/.radin must not change the sums.
# Must stay bash-3.2-compatible (macOS /bin/bash).
set -euo pipefail
home="$1"
root="$(cd "$(dirname "$0")/.." && pwd)"

names() { # kind -> its names, one per line
	awk -v k="$1" '(NF == 2 && $1 == k) { print $NF }' "$root/SHIPPED"
}

hash_stdin() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum | awk '{print $1}'
	else
		shasum -a 256 | awk '{print $1}'
	fi
}

norm() {
	# shellcheck disable=SC2016  # the literal $HOME is the text the installer bakes
	sed -e 's|[^"[:space:]]*/\.claude/\.radin/lib|@RADIN_LIB@|g' \
		-e 's|"\$HOME/\.claude/\.radin/bin/radin"|@RADIN_CLI@|g' |
		hash_stdin
}

one() { # key file -> one sum line; a missing file fails the script
	local sum
	sum="$(norm <"$2")"
	printf '%s  %s\n' "$sum" "$1"
}

{
	for s in $(names skill); do one "skills/$s/SKILL.md" "$home/.claude/skills/$s/SKILL.md"; done
	for l in $(names lib); do
		case "$l" in *.md) one "lib/$l" "$home/.claude/.radin/lib/$l" ;; esac
	done
} | LC_ALL=C sort -k2

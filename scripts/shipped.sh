#!/usr/bin/env bash
# Usage: scripts/shipped.sh gen|check
# SHIPPED is the one list of files radin ships. `gen` writes it into the marked
# blocks of install.sh, doctor and uninstall, so the
# installed scripts stay self-contained and uninstall works with no registry.
# `check` fails, naming the fix, when anything disagrees.
# Must stay bash-3.2-compatible (macOS /bin/bash).
set -euo pipefail
cd "$(dirname "$0")/.."
TARGETS="install.sh lib/radin-doctor.sh lib/radin-uninstall.sh"

names() { # kind ("skill", "lib", "renamed skill", ...) -> its names, one per line
	awk -v k="$1" '(NF == 2 && $1 == k) || (NF == 3 && $1 " " $2 == k) { print $NF }' SHIPPED
}

# Each script gets only the lists it reads, so shellcheck sees no unused one.
vars_for() {
	case "$1" in
	install.sh) echo "SHIPPED_SKILLS SHIPPED_LIB RENAMED_SKILLS RETIRED_SKILLS" ;;
	lib/radin-doctor.sh) echo "SHIPPED_SKILLS SHIPPED_LIB" ;;
	*) echo "SHIPPED_SKILLS SHIPPED_LIB RENAMED_SKILLS RETIRED_SKILLS RETIRED_LIB" ;;
	esac
}

kind_of() {
	case "$1" in
	SHIPPED_SKILLS) echo skill ;;
	SHIPPED_LIB) echo lib ;;
	RENAMED_SKILLS) echo "renamed skill" ;;
	RETIRED_SKILLS) echo "retired skill" ;;
	RETIRED_LIB) echo "retired lib" ;;
	esac
}

render() {
	local v
	printf '# BEGIN shipped (generated from SHIPPED by scripts/shipped.sh; run make gen, never edit)\n'
	for v in $(vars_for "$1"); do
		printf '%s="%s"\n' "$v" "$(names "$(kind_of "$v")" | tr '\n' ' ' | sed 's/ $//')"
	done
	printf '# END shipped\n'
}

splice() { # file, block file -> stdout
	awk -v blk="$2" '
		/^ *# BEGIN shipped/ { while ((getline l < blk) > 0) print l; skip = 1; next }
		/^ *# END shipped/ { skip = 0; next }
		!skip { print }' "$1"
}

BLK="$(mktemp)"
trap 'rm -f "$BLK"' EXIT
die() {
	printf 'shipped: %s\n' "$*" >&2
	exit 1
}
fail() {
	printf 'shipped: %s\n' "$*" >&2
	bad=1
}

case "${1:-}" in
gen)
	for f in $TARGETS; do
		grep -qE '^ *# BEGIN shipped' "$f" || die "$f has no BEGIN/END marker pair: add one where the list belongs"
		render "$f" >"$BLK"
		splice "$f" "$BLK" >"$f.new" && cat "$f.new" >"$f" && rm -f "$f.new"
	done
	;;
check)
	bad=0
	awk 'NF && $1 !~ /^#/ && !((NF == 2 && ($1 == "skill" || $1 == "lib")) || (NF == 3 && ($1 == "renamed" || $1 == "retired") && ($2 == "skill" || $2 == "lib"))) { printf "shipped: SHIPPED line %d (%s) has no known kind: use skill, lib, renamed skill, retired skill or retired lib\n", NR, $0; e = 1 } END { exit e }' SHIPPED >&2 || bad=1
	for s in $(names skill); do [ -f "skills/$s/SKILL.md" ] || fail "SHIPPED lists skill $s but skills/$s/SKILL.md is missing: create it or delete the line"; done
	for l in $(names lib); do [ -f "lib/$l" ] || fail "SHIPPED lists lib $l but lib/$l is missing: create it or delete the line"; done
	for d in skills/*/; do
		s="$(basename "$d")"
		names skill | grep -qx "$s" || fail "skills/$s exists but is not in SHIPPED: add \"skill $s\" to SHIPPED, then run make gen"
	done
	for f in $(git ls-files --cached --others --exclude-standard lib); do
		l="${f#lib/}"
		names lib | grep -qx "$l" || fail "$f is tracked but not in SHIPPED: add \"lib $l\" to SHIPPED, then run make gen"
	done
	for f in $TARGETS; do
		render "$f" >"$BLK"
		splice "$f" "$BLK" | cmp -s - "$f" || fail "$f has a stale shipped block: run make gen"
	done
	for s in $(names skill); do grep -q "^| \`/$s\` |" README.md || fail "skill $s is not in the README table: add a row"; done
	exit "$bad"
	;;
*) die "usage: scripts/shipped.sh gen|check" ;;
esac

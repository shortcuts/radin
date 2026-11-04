#!/usr/bin/env bash
# Usage: render-host.sh [--hits] FILE HOST
# Prints FILE as HOST sees it: keeps text outside <!-- host:NAME[,NAME] --> ... <!-- /host -->
# blocks, keeps a block body only when HOST is listed, drops the marker lines, and replaces each
# @@skill:NAME@@ with HOST's value from lib/skill-names-HOST.txt (RADIN_LIB_DIR overrides lib/).
# Fails on a bad marker (FILE:LINE: reason) or a string from lib/forbid-HOST.txt that survives.
# --hits prints each surviving string and exits 0. HOST names are the files lib/forbid-*.txt.
# Must stay bash-3.2-compatible (macOS /bin/bash).
set -euo pipefail
lib_dir=${RADIN_LIB_DIR:-$(dirname "$0")/../lib}
hits=0
if [ "${1:-}" = --hits ]; then
	hits=1
	shift
fi
[ $# -eq 2 ] || {
	echo "usage: render-host.sh [--hits] FILE HOST" >&2
	exit 2
}
file=$1
host=$2
[ -f "$lib_dir/forbid-$host.txt" ] || {
	echo "$file: unknown host \"$host\"" >&2
	exit 1
}
[ -r "$file" ] || {
	echo "$file: unreadable" >&2
	exit 1
}
valid=$(cd "$lib_dir" && for f in forbid-*.txt; do
	f=${f#forbid-}
	echo "${f%.txt}"
done | tr '\n' ' ')
names_file=$lib_dir/skill-names-$host.txt
[ -f "$names_file" ] || {
	echo "$file: no skill-names-$host.txt" >&2
	exit 1
}
out=$(mktemp)
trap 'rm -f "$out"' EXIT

awk -v file="$file" -v host="$host" -v valid="$valid" -v names="$names_file" '
function fail(n, why) { printf "%s:%d: %s\n", file, n, why > "/dev/stderr"; bad = 1; exit 1 }
function subst(line, n,   res, i, rest, name) {
	res = ""
	while ((i = index(line, "@@skill:")) > 0) {
		rest = substr(line, i + 8)
		if (!match(rest, /^[a-z0-9-]+@@/)) fail(n, "malformed skill token")
		name = substr(rest, 1, RLENGTH - 2)
		if (!(name in sk)) fail(n, "unknown skill name \"" name "\"")
		res = res substr(line, 1, i - 1) sk[name]
		line = substr(rest, RLENGTH + 1)
	}
	return res line
}
BEGIN {
	nv = split(valid, v, " "); for (i = 1; i <= nv; i++) ok[v[i]] = 1
	while ((getline l < names) > 0) { if (l ~ /^[ \t]*(#|$)/) continue; k = l; sub(/[ \t].*$/, "", k); val = l; sub(/^[^ \t]*[ \t]+/, "", val); sk[k] = val }
}
/<!-- host:|<!-- \/host/ {
	if ($0 ~ /^[ \t]*<!-- \/host -->[ \t]*$/) {
		if (!open) fail(FNR, "<!-- /host --> with no open block")
		open = 0; next
	}
	if ($0 !~ /^[ \t]*<!-- host:[^ ]* -->[ \t]*$/) fail(FNR, "host marker must sit alone on its line")
	if (open) fail(FNR, "nested host block, opened at line " open)
	names = $0; sub(/^[ \t]*<!-- host:/, "", names); sub(/ -->[ \t]*$/, "", names)
	if (names == "") fail(FNR, "empty host name list")
	n = split(names, a, ","); keep = 0
	for (i = 1; i <= n; i++) {
		if (!(a[i] in ok)) fail(FNR, "unknown host \"" a[i] "\"")
		if (a[i] == host) keep = 1
	}
	open = FNR; next
}
!open || keep { print subst($0, FNR) }
END { if (!bad && open) fail(open, "host block never closed") }
' "$file" >"$out"

found=$(awk -v list="$lib_dir/forbid-$host.txt" '
BEGIN { while ((getline s < list) > 0) if (s != "" && s !~ /^#/) f[++n] = s }
{ for (i = 1; i <= n; i++) if (!(i in hit) && index($0, f[i])) hit[i] = 1 }
END { for (i = 1; i <= n; i++) if (i in hit) print f[i] }
' "$out")

if [ "$hits" -eq 1 ]; then
	[ -z "$found" ] || printf '%s\n' "$found"
	exit 0
fi
if [ -n "$found" ]; then
	printf '%s\n' "$found" | while IFS= read -r s; do
		printf '%s: forbidden string "%s" survives in the %s render\n' "$file" "$s" "$host" >&2
	done
	exit 1
fi
cat "$out"

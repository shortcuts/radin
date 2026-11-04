#!/usr/bin/env bash
# Usage: render-host.sh [--hits] FILE HOST
# Prints FILE as HOST sees it: keeps text outside <!-- host:NAME[,NAME] --> ... <!-- /host -->
# blocks, keeps a block body only when HOST is listed, drops the marker lines, and replaces each
# @@skill:NAME@@ with HOST's value from lib/skill-names-HOST.txt (RADIN_LIB_DIR overrides lib/).
# Fails on a bad marker (FILE:LINE: reason) or a string from lib/forbid-HOST.txt that survives.
# --hits prints each surviving string and exits 0. HOST names are the files lib/forbid-*.txt.
# Must stay bash-3.2-compatible (macOS /bin/bash).
set -euo pipefail
# Plain parameter expansion in place of dirname, find and mktemp: this script runs once per
# shipped file (~60 per install), so each fork it skips is seconds off every install and test.
case $0 in */*) self_dir=${0%/*} ;; *) self_dir=. ;; esac
lib_dir=${RADIN_LIB_DIR:-$self_dir/../lib}
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
valid=""
for f in "$lib_dir"/forbid-*.txt; do
	f=${f##*/}
	f=${f#forbid-}
	valid="$valid ${f%.txt}"
done
names_file=$lib_dir/skill-names-$host.txt
[ -f "$names_file" ] || {
	echo "$file: no skill-names-$host.txt" >&2
	exit 1
}

# One awk pass renders, checks the forbidden strings and prints. It buffers the render so a bad
# marker or a surviving string prints nothing to stdout.
exec awk -v file="$file" -v host="$host" -v valid="$valid" -v names="$names_file" \
	-v forbid="$lib_dir/forbid-$host.txt" -v hits="$hits" '
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
	while ((getline s < forbid) > 0) if (s != "" && s !~ /^#/) f[++nf] = s
}
/<!-- host:|<!-- \/host/ {
	if ($0 ~ /^[ \t]*<!-- \/host -->[ \t]*$/) {
		if (!open) fail(FNR, "<!-- /host --> with no open block")
		open = 0; next
	}
	if ($0 !~ /^[ \t]*<!-- host:[^ ]* -->[ \t]*$/) fail(FNR, "host marker must sit alone on its line")
	if (open) fail(FNR, "nested host block, opened at line " open)
	hn = $0; sub(/^[ \t]*<!-- host:/, "", hn); sub(/ -->[ \t]*$/, "", hn)
	if (hn == "") fail(FNR, "empty host name list")
	n = split(hn, a, ","); keep = 0
	for (i = 1; i <= n; i++) {
		if (!(a[i] in ok)) fail(FNR, "unknown host \"" a[i] "\"")
		if (a[i] == host) keep = 1
	}
	open = FNR; next
}
!open || keep {
	line = subst($0, FNR)
	out[++no] = line
	for (i = 1; i <= nf; i++) if (!(i in hit) && index(line, f[i])) hit[i] = 1
}
END {
	if (bad) exit 1
	if (open) fail(open, "host block never closed")
	if (hits + 0 == 1) { for (i = 1; i <= nf; i++) if (i in hit) print f[i]; exit 0 }
	for (i = 1; i <= nf; i++) if (i in hit) { printf "%s: forbidden string \"%s\" survives in the %s render\n", file, f[i], host > "/dev/stderr"; found = 1 }
	if (found) exit 1
	for (i = 1; i <= no; i++) print out[i]
}
' "$file"

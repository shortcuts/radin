#!/usr/bin/env bash
# Usage: render-host.sh [--hits] FILE HOST
#        render-host.sh --batch HOST   (stdin: one "SRC<TAB>DEST" line per file)
# Prints FILE as HOST sees it: keeps text outside <!-- host:NAME[,NAME] --> ... <!-- /host -->
# blocks, keeps a block body only when HOST is listed, drops the marker lines, and replaces each
# @@skill:NAME@@ with HOST's value from lib/skill-names-HOST.txt (RADIN_LIB_DIR overrides lib/).
# Fails on a bad marker (FILE:LINE: reason) or a string from lib/forbid-HOST.txt that survives.
# --hits prints each surviving string and exits 0. HOST names are the files lib/forbid-*.txt.
# --batch renders every pair in one process and stops at the first failure; a failing file
# writes nothing. install.sh renders ~60 files per host, and one fork per file cost seconds.
# Must stay bash-3.2-compatible (macOS /bin/bash).
set -euo pipefail
# Plain parameter expansion in place of dirname, find and mktemp: this script runs once per
# shipped file (~60 per install), so each fork it skips is seconds off every install and test.
case $0 in */*) self_dir=${0%/*} ;; *) self_dir=. ;; esac
lib_dir=${RADIN_LIB_DIR:-$self_dir/../lib}
hits=0
batch=0
srcs=()
dests=""
if [ "${1:-}" = --hits ]; then
	hits=1
	shift
elif [ "${1:-}" = --batch ]; then
	batch=1
	shift
	[ $# -eq 1 ] || {
		echo "usage: render-host.sh --batch HOST" >&2
		exit 2
	}
	host=$1
	file=""
	tab=$(printf '\t')
	while IFS="$tab" read -r src dest; do
		[ -n "$src" ] || continue
		[ -r "$src" ] || {
			echo "$src: unreadable" >&2
			exit 1
		}
		# awk sees no line of an empty file, so it could not pair the file with its dest.
		if [ -s "$src" ]; then
			srcs[${#srcs[@]}]=$src
			dests="$dests$dest$tab"
		else
			: >"$dest"
		fi
	done
	[ ${#srcs[@]} -gt 0 ] || exit 0
fi
if [ "$batch" = 0 ]; then
	[ $# -eq 2 ] || {
		echo "usage: render-host.sh [--hits] FILE HOST" >&2
		exit 2
	}
	file=$1
	host=$2
	srcs=("$file")
fi
[ -f "$lib_dir/forbid-$host.txt" ] || {
	echo "${file:-$host}: unknown host \"$host\"" >&2
	exit 1
}
[ "$batch" = 1 ] || [ -r "$file" ] || {
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
	echo "${file:-$host}: no skill-names-$host.txt" >&2
	exit 1
}

# One awk pass renders, checks the forbidden strings and prints. It buffers the render so a bad
# marker or a surviving string prints nothing to stdout.
exec awk -v host="$host" -v valid="$valid" -v names="$names_file" -v dests="$dests" \
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
	nd = split(dests, dest, "\t")
	nv = split(valid, v, " "); for (i = 1; i <= nv; i++) ok[v[i]] = 1
	while ((getline l < names) > 0) { if (l ~ /^[ \t]*(#|$)/) continue; k = l; sub(/[ \t].*$/, "", k); val = l; sub(/^[^ \t]*[ \t]+/, "", val); sk[k] = val }
	while ((getline s < forbid) > 0) if (s != "" && s !~ /^#/) f[++nf] = s
}
FNR == 1 {
	if (started) finish()
	started = 1; fi++; file = FILENAME
	open = 0; keep = 0; no = 0; delete out; delete hit
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
function finish(   i, found, o) {
	if (open) fail(open, "host block never closed")
	if (hits + 0 == 1) { for (i = 1; i <= nf; i++) if (i in hit) print f[i]; return }
	for (i = 1; i <= nf; i++) if (i in hit) { printf "%s: forbidden string \"%s\" survives in the %s render\n", file, f[i], host > "/dev/stderr"; found = 1 }
	if (found) { bad = 1; exit 1 }
	o = (fi in dest) && dest[fi] != "" ? dest[fi] : "/dev/stdout"
	for (i = 1; i <= no; i++) print out[i] > o
	if (o != "/dev/stdout") close(o)
}
END {
	if (bad) exit 1
	if (started) finish()
}
' "${srcs[@]}"

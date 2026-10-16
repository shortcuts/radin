#!/usr/bin/env bash
# Usage: check-prose.sh [root]. Three lints, each fails with file:line and the fix.
set -u
cd "${1:-.}" || exit 2
rc=0

# bats runs a test body under set -e, and set -e ignores a failing `! cmd`.
# Only the last command of a test reports its status.
bats_hits=$(awk '
FNR == 1 { if (n) flush(); n = 0; file = FILENAME }
function flush(  i) {
	for (i = 1; i <= n; i++)
		if (bang[i] && i < lastcmd[blk[i]])
			printf "%s:%d: bare `! cmd` mid-test never fails; use `run ! cmd` or `[ -z \"$(cmd)\" ]`\n", file, ln[i]
}
/^@test / { b++ }
{
	n++; blk[n] = b; ln[n] = FNR; bang[n] = ($0 ~ /^[ \t]+! /)
	if ($0 !~ /^[ \t]*(#|}|$)/ && b > 0) lastcmd[b] = n
}
END { flush() }
' tests/*.bats)
if [ -n "$bats_hits" ]; then
	printf '%s\n' "$bats_hits"
	rc=1
fi

# AGENTS.md: name a companion directly, with no `command -v` gate and no escape clause.
companions='caveman|ponytail|rtk|thermo|mattpocock|headroom|codebase-memory|graph tool'
guard_re="command -v|if (it|the|that|a)[^.]{0,40}(is|are) (installed|wired|available|present)|(unavailable|not installed|absent|missing|without)[^.]{0,50}($companions)|($companions|graph)[^.]{0,50}(unavailable|not installed|absent|is missing|when absent)"
guard_hits=$(grep -nEi "$guard_re" skills/*/SKILL.md lib/*.md)
if [ -n "$guard_hits" ]; then
	printf '%s\n' "$guard_hits" | awk -F: '{ printf "%s:%s: companion guard; name the tool directly, a missing tool fails loudly and counts as a skip\n", $1, $2 }'
	rc=1
fi

# A sentence of 8+ words in two places of model-facing prose drifts apart.
# Case, punctuation and line wrap are ignored. Only a sentence missing from the
# list below fails, so the check flags new copies only. The first file read
# owns a sentence, so the leaf contract goes first.
allowed='you are a leaf no user no askuserquestion no workflow no sub agent of your own|read radin lib radin run md in full now and follow it as this skill s body'
dup_hits=$(awk -v allowed="$allowed" '
BEGIN { n = split(allowed, a, "|"); for (i = 1; i <= n; i++) ok[a[i]] = 1 }
function emit(  s) {
	s = tolower(buf); gsub(/[^a-z0-9]+/, " ", s); gsub(/^ | $/, "", s); buf = ""
	if (split(s, w, " ") < 8 || s in ok) return
	if (s in seen) printf "%s:%d: repeats %s; state it once there and point to it\n", FILENAME, start, seen[s]
	else seen[s] = FILENAME ":" start
}
FNR == 1 { if (FILENAME in done) nextfile; done[FILENAME] = 1; buf = "" }
/^[ \t]*($|```|#|[-*] |[0-9]+[a-z]?\. |<!--)/ { emit() }
{
	line = $0
	if (buf == "") start = FNR
	while (match(line, /[.!?]([ \t]|$)/)) {
		buf = buf " " substr(line, 1, RSTART); emit()
		line = substr(line, RSTART + RLENGTH); start = FNR
	}
	if (line ~ /[^ \t]/) buf = buf " " line
}
' lib/radin-leaf-contract.md lib/*.md skills/*/SKILL.md) || rc=1
if [ -n "$dup_hits" ]; then
	printf '%s\n' "$dup_hits"
	rc=1
fi

exit "$rc"

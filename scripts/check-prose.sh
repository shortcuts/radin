#!/usr/bin/env bash
# Usage: check-prose.sh [root]. Six lints, each fails with file:line and the fix.
set -u
here=$(cd "$(dirname "$0")" && pwd)
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
companions='caveman|ponytail|rtk|thermo|mattpocock|codebase-memory|graph tool'
guard_re="command -v|if (it|the|that|a)[^.]{0,40}(is|are) (installed|wired|available|present)|(unavailable|not installed|absent|missing|without)[^.]{0,50}($companions)|($companions|graph)[^.]{0,50}(unavailable|not installed|absent|is missing|when absent)"
guard_hits=$(grep -nEi "$guard_re" skills/*/SKILL.md lib/*.md)
if [ -n "$guard_hits" ]; then
	printf '%s\n' "$guard_hits" | awk -F: '{ printf "%s:%s: companion guard; name the tool directly, a missing tool fails loudly and counts as a skip\n", $1, $2 }'
	rc=1
fi

# A line with "never" states a prohibition, which is not a router step.
git_hits=$(grep -nEi '(`|^[ \t]*)git [a-z]' lib/radin-run.md lib/radin-batch-*.md | grep -vi 'never')
if [ -n "$git_hits" ]; then
	printf '%s\n' "$git_hits" | awk -F: '{ printf "%s:%s: raw git command in router prose; add a radin subcommand, or state the prohibition with \"never\"\n", $1, $2 }'
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
	if (s in seen) {
		if (sb && seenb[s] && sb != seenb[s]) return
		printf "%s:%d: repeats %s; state it once there and point to it\n", FILENAME, start, seen[s]
	} else { seen[s] = FILENAME ":" start; seenb[s] = sb }
}
FNR == 1 { if (FILENAME in done) nextfile; done[FILENAME] = 1; buf = ""; blk = 0; nb = 0 }
/^[ \t]*<!-- (host:|\/host)/ { emit(); blk = /host:/ ? ++nb : 0; next }
/^[ \t]*($|```|#|[-*] |[0-9]+[a-z]?\. |<!--)/ { emit() }
{
	line = $0
	if (buf == "") { start = FNR; sb = blk }
	while (match(line, /[.!?]([ \t]|$)/)) {
		buf = buf " " substr(line, 1, RSTART); emit()
		line = substr(line, RSTART + RLENGTH); start = FNR; sb = blk
	}
	if (line ~ /[^ \t]/) buf = buf " " line
}
' lib/radin-leaf-contract.md lib/*.md skills/*/SKILL.md) || rc=1
if [ -n "$dup_hits" ]; then
	printf '%s\n' "$dup_hits"
	rc=1
fi

# A Claude-only string outside a host block breaks the agents render.
# hosts/forbid-baseline.txt lists the pairs that exist today and only shrinks.
export LC_ALL=C RADIN_HOSTS_DIR="$PWD/hosts"
# The pipeline below drops the status of render-host.sh, so a bad marker needs its own check.
for f in skills/*/SKILL.md lib/*.md; do
	"$here/render-host.sh" --hits "$f" agents >/dev/null || rc=1
done
forbid_found=$(for f in skills/*/SKILL.md lib/*.md; do
	"$here/render-host.sh" --hits "$f" agents | while IFS= read -r s; do printf '%s\t%s\n' "$f" "$s"; done
done | sort) || rc=1
forbid_base=$(sort hosts/forbid-baseline.txt 2>/dev/null)
forbid_new=$(comm -13 <(printf '%s\n' "$forbid_base") <(printf '%s\n' "$forbid_found") | grep .)
if [ -n "$forbid_new" ]; then
	printf '%s\n' "$forbid_new" | awk -F'\t' '{ printf "%s: forbidden string \"%s\" outside a host block; wrap it in <!-- host:claude --> or use the name map\n", $1, $2 }'
	rc=1
fi
forbid_stale=$(comm -23 <(printf '%s\n' "$forbid_base") <(printf '%s\n' "$forbid_found") | grep .)
if [ -n "$forbid_stale" ]; then
	printf '%s\n' "$forbid_stale" | awk -F'\t' '{ printf "hosts/forbid-baseline.txt: %s no longer holds \"%s\"; delete the line\n", $1, $2 }'
	rc=1
fi

# A companion skill name lives in lib/skill-names-HOST.txt. Scripts read it with radin_skill; prose uses @@skill:NAME@@.
name_hits=$(grep -nHE '/(mattpocock-skills|ponytail|caveman):|/thermo-nuclear' lib/*.sh)
if [ -n "$name_hits" ]; then
	printf '%s\n' "$name_hits" | awk -F: '{ printf "%s:%s: skill name outside the table; use radin_skill NAME\n", $1, $2 }'
	rc=1
fi
for tbl in lib/skill-names-*.txt; do
	[ -f "$tbl" ] || continue
	grep -noHE '@@skill:[a-z0-9-]+@@' skills/*/SKILL.md lib/*.md lib/*.sh | while IFS=: read -r f n tok; do
		k=${tok#@@skill:}
		k=${k%@@}
		awk -v k="$k" '$1 == k { f = 1 } END { exit !f }' "$tbl" || printf '%s:%s: skill %s is not in %s\n' "$f" "$n" "$k" "$tbl"
	done
done >"${TMPDIR:-/tmp}/check-prose.$$"
if [ -s "${TMPDIR:-/tmp}/check-prose.$$" ]; then
	cat "${TMPDIR:-/tmp}/check-prose.$$"
	rc=1
fi
rm -f "${TMPDIR:-/tmp}/check-prose.$$"

exit "$rc"

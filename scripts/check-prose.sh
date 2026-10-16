#!/usr/bin/env bash
# Usage: check-prose.sh [root]. Two lints, both fail with file:line and the fix.
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

exit "$rc"

#!/usr/bin/env bash
# Key-to-frame latency of the TUI on a seeded backlog, so a render change is
# judged on a number, not a feel. Not part of `make test`: timing is machine
# dependent and would flake a pass/fail gate.
#
# usage: tests/bench-tui.sh [tasks=42] [keys=20]   (or `make bench-tui`)
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASKS="${1:-42}"
KEYS="${2:-20}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

make -s -C "$ROOT" lib/radin-tui tests/helpers/pty-run

i=1
while [ "$i" -le "$TASKS" ]; do
	printf 'Body of task %s.\n' "$i" |
		(cd "$WORK" && bash "$ROOT/lib/radin-backlog.sh" add feat \
			"task $i with a title long enough to wrap inside the list pane" >/dev/null)
	i=$((i + 1))
done

# The empty first chunk waits out the startup frame, so every timed line is a
# keypress. 200x50 is wide enough for the split pane and its detail fork.
keys=""
i=0
while [ "$i" -lt "$KEYS" ]; do
	keys="$keys|j"
	i=$((i + 1))
done
(cd "$WORK" && PTY_TIMING=1 PTY_QUIET=0.3 PTY_COLS=200 PTY_ROWS=50 \
	"$ROOT/tests/helpers/pty-run" "$WORK/screen" "$keys|q" "$ROOT/lib/radin-tui") \
	2>"$WORK/timing" || true

# The first line is the startup frame and the last is `q`: neither is a keypress frame.
sed '1d;$d' "$WORK/timing" | sort -n | awk -v tasks="$TASKS" '
	{ ms[NR] = $1; w[NR] = $2; b[NR] = $3 }
	END {
		if (!NR) { print "no frames timed"; exit 1 }
		m = int((NR + 1) / 2)
		printf "%d tasks, %d keys: key-to-frame median %.1fms max %.1fms, %d writes, %d bytes per frame\n",
			tasks, NR, ms[m], ms[NR], w[m], b[m]
	}'

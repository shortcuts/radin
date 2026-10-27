#!/usr/bin/env bash
# Usage: real-setup-sum.sh. Prints one checksum line per real Claude setup file.
set -u
files=("$HOME/.claude/settings.json" "$HOME/.config/.claude/settings.json" "$HOME/.claude.json")
[ -n "${CLAUDE_CONFIG_DIR:-}" ] && files+=("$CLAUDE_CONFIG_DIR/settings.json")
for f in "${files[@]}"; do
	if [ -f "$f" ]; then
		echo "$f $(cksum <"$f")"
	else
		echo "$f absent"
	fi
done

#!/usr/bin/env bash
# Removes everything install.sh copies into ~/.claude. Never touches
# thermo-nuclear (not vendored by this repo), companion tools (advisory
# installs), ~/.claude/radin (the fetched source copy), or any per-repo
# .claude/.radin/ backlog directory -- see AGENTS.md's Constraints section.
# Installed to ~/.claude/.radin/lib/radin-uninstall.sh by install.sh.
#
# Usage: radin-uninstall.sh
# Must stay bash-3.2-compatible (macOS /bin/bash).
set -euo pipefail

CLAUDE_DIR="$HOME/.claude"

# rm -rf works on a plain file same as a directory -- one helper covers
# both the agent/lib files and the skill directories below.
remove_path() {
	local label="$1" path="$2"
	if [ -e "$path" ]; then
		rm -rf -- "$path"
		printf '  REMOVED  %s\n' "$label"
	else
		printf '  ABSENT   %s\n' "$label"
	fi
}

printf 'radin uninstall\n===============\n'

printf '\nAgent (%s/agents):\n' "$CLAUDE_DIR"
remove_path "radin-execute.md" "$CLAUDE_DIR/agents/radin-execute.md"

printf '\nSkills (%s/skills):\n' "$CLAUDE_DIR"
for name in radin-plan radin-record radin-review radin-setup-hooks radin-show radin-stats radin-doctor radin-uninstall; do
	remove_path "$name" "$CLAUDE_DIR/skills/$name"
done

printf '\nLib (%s/.radin/lib):\n' "$CLAUDE_DIR"
remove_path "radin-namespace.sh" "$CLAUDE_DIR/.radin/lib/radin-namespace.sh"
remove_path "radin-backlog.sh" "$CLAUDE_DIR/.radin/lib/radin-backlog.sh"
remove_path "radin-prioritization.md" "$CLAUDE_DIR/.radin/lib/radin-prioritization.md"
remove_path "radin-doctor.sh" "$CLAUDE_DIR/.radin/lib/radin-doctor.sh"

printf '\nLeft untouched:\n'
printf '  %-20s not vendored by radin, remove manually if wanted\n' "thermo-nuclear"
printf '  %-20s advisory install, remove with: brew uninstall rtk\n' "rtk"
printf '  %-20s advisory install, remove with: pipx uninstall code-review-graph\n' "code-review-graph"
printf '  %-20s advisory install, remove with: claude plugin uninstall caveman@caveman\n' "caveman"
printf '  %-20s advisory install, remove with: claude plugin uninstall i-have-adhd@i-have-adhd\n' "i-have-adhd"
printf '  %-20s advisory install, remove with: claude plugin uninstall ponytail@ponytail\n' "ponytail"
printf '  %s\n' "Any <repo-root>/.claude/.radin/ backlog directory -- your data, your call"

printf '\nradin removed from ~/.claude.\n'

remove_path "radin-uninstall.sh (this script)" "$CLAUDE_DIR/.radin/lib/radin-uninstall.sh"

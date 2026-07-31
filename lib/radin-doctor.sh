#!/usr/bin/env bash
# Read-only post-install health check for radin. Confirms the files
# install.sh should have copied are present, and reports which advisory
# companion tools (rtk, code-review-graph, caveman, i-have-adhd, ponytail,
# mattpocock-skills) are reachable. Never mutates anything -- mirrors install.sh's own
# "advisory only" stance on companion tools.
# Installed to ~/.claude/.radin/lib/radin-doctor.sh by install.sh.
#
# Usage: radin-doctor.sh
# Exit: 0 if every expected agent/skill/lib file is present and every lib
# shell script has valid syntax, 1 otherwise. Companion-tool reachability
# is informational only and never affects the exit code.
# Must stay bash-3.2-compatible (macOS /bin/bash).
set -euo pipefail

CLAUDE_DIR="$HOME/.claude"
MISSING=0

check_file() {
	local label="$1" path="$2"
	if [ -f "$path" ]; then
		printf '  OK       %s\n' "$label"
	else
		printf '  MISSING  %s\n' "$label"
		MISSING=$((MISSING + 1))
	fi
}

check_lib_script() {
	local label="$1" path="$2"
	if [ ! -f "$path" ]; then
		printf '  MISSING  %s\n' "$label"
		MISSING=$((MISSING + 1))
	elif bash -n "$path" 2>/dev/null; then
		printf '  OK       %s\n' "$label"
	else
		printf '  INVALID  %s (syntax error)\n' "$label"
		MISSING=$((MISSING + 1))
	fi
}

check_path_tool() {
	local label="$1" cmd="$2"
	if command -v "$cmd" >/dev/null 2>&1; then
		printf '  %-20s found\n' "$label"
	else
		printf '  %-20s not found\n' "$label"
	fi
}

check_plugin() {
	local label="$1" plugin_id="$2"
	if command -v claude >/dev/null 2>&1 && claude plugin list 2>/dev/null | grep -q "$plugin_id"; then
		printf '  %-20s found\n' "$label"
	else
		printf '  %-20s not found\n' "$label"
	fi
}

printf 'radin doctor\n============\n'

printf '\nAgents (%s/agents):\n' "$CLAUDE_DIR"
check_file "radin-execute.md" "$CLAUDE_DIR/agents/radin-execute.md"

printf '\nSkills (%s/skills):\n' "$CLAUDE_DIR"
for name in radin-plan radin-record radin-review radin-setup-hooks radin-show radin-stats radin-doctor radin-uninstall thermo-nuclear; do
	check_file "$name" "$CLAUDE_DIR/skills/$name/SKILL.md"
done

printf '\nLib (%s/.radin/lib):\n' "$CLAUDE_DIR"
check_lib_script "radin-namespace.sh" "$CLAUDE_DIR/.radin/lib/radin-namespace.sh"
check_lib_script "radin-backlog.sh" "$CLAUDE_DIR/.radin/lib/radin-backlog.sh"
check_lib_script "radin-state.sh" "$CLAUDE_DIR/.radin/lib/radin-state.sh"
check_file "radin-prioritization.md" "$CLAUDE_DIR/.radin/lib/radin-prioritization.md"
check_lib_script "radin-doctor.sh" "$CLAUDE_DIR/.radin/lib/radin-doctor.sh"
check_lib_script "radin-uninstall.sh" "$CLAUDE_DIR/.radin/lib/radin-uninstall.sh"

printf '\nCompanion tools (optional, advisory-only):\n'
check_path_tool "rtk" "rtk"
check_path_tool "code-review-graph" "code-review-graph"
check_path_tool "headroom" "headroom"
check_plugin "caveman" "caveman@caveman"
check_plugin "i-have-adhd" "i-have-adhd@i-have-adhd"
check_plugin "ponytail" "ponytail@ponytail"
check_plugin "mattpocock-skills" "mattpocock-skills@claude-plugins-official"

printf '\n'
if [ "$MISSING" -eq 0 ]; then
	printf 'All expected files present.\n'
	exit 0
else
	printf '%d expected file(s) missing or invalid.\n' "$MISSING"
	exit 1
fi

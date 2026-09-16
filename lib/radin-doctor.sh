#!/usr/bin/env bash
# Read-only post-install health check for radin. Confirms the files
# install.sh should have copied are present, and reports which advisory
# companion tools (rtk, codebase-memory-mcp, headroom, caveman, ponytail,
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

printf '\nSkills (%s/skills):\n' "$CLAUDE_DIR"
for name in radin-execute radin-plan radin-record radin-review radin-setup-hooks radin-show radin-stats radin-doctor radin-uninstall thermo-nuclear; do
	check_file "$name" "$CLAUDE_DIR/skills/$name/SKILL.md"
done

printf '\nLib (%s/.radin/lib):\n' "$CLAUDE_DIR"
printf '\nCLI (%s/.radin/bin):\n' "$CLAUDE_DIR"
check_lib_script "radin (dispatcher)" "$CLAUDE_DIR/.radin/bin/radin"
if [ "$(readlink "$HOME/.local/bin/radin" 2>/dev/null)" = "$CLAUDE_DIR/.radin/bin/radin" ]; then
	printf '  %-20s symlinked into ~/.local/bin\n' "radin (PATH)"
else
	printf '  %-20s not on PATH (optional; skills fall back to the full path)\n' "radin (PATH)"
fi

check_lib_script "radin-namespace.sh" "$CLAUDE_DIR/.radin/lib/radin-namespace.sh"
check_lib_script "radin-json.sh" "$CLAUDE_DIR/.radin/lib/radin-json.sh"
check_lib_script "radin-backlog.sh" "$CLAUDE_DIR/.radin/lib/radin-backlog.sh"
check_file "radin-tui.c" "$CLAUDE_DIR/.radin/lib/radin-tui.c"
check_file "radin-cbm-json.c" "$CLAUDE_DIR/.radin/lib/radin-cbm-json.c"
check_lib_script "radin-state.sh" "$CLAUDE_DIR/.radin/lib/radin-state.sh"
check_lib_script "radin-scope.sh" "$CLAUDE_DIR/.radin/lib/radin-scope.sh"
check_lib_script "radin-cbm-hooks.sh" "$CLAUDE_DIR/.radin/lib/radin-cbm-hooks.sh"
check_lib_script "radin-cbm-config.sh" "$CLAUDE_DIR/.radin/lib/radin-cbm-config.sh"
check_file "radin-prioritization.md" "$CLAUDE_DIR/.radin/lib/radin-prioritization.md"
check_file "radin-execute-prompts.md" "$CLAUDE_DIR/.radin/lib/radin-execute-prompts.md"
check_file "radin-execute-recovery.md" "$CLAUDE_DIR/.radin/lib/radin-execute-recovery.md"
check_file "radin-execute-reporting.md" "$CLAUDE_DIR/.radin/lib/radin-execute-reporting.md"
check_file "radin-execute-clarify.md" "$CLAUDE_DIR/.radin/lib/radin-execute-clarify.md"
check_file "radin-execute-session.md" "$CLAUDE_DIR/.radin/lib/radin-execute-session.md"
check_file "radin-execute-resume.md" "$CLAUDE_DIR/.radin/lib/radin-execute-resume.md"
check_lib_script "radin-update.sh" "$CLAUDE_DIR/.radin/lib/radin-update.sh"
check_lib_script "radin-doctor.sh" "$CLAUDE_DIR/.radin/lib/radin-doctor.sh"
check_lib_script "radin-uninstall.sh" "$CLAUDE_DIR/.radin/lib/radin-uninstall.sh"

# install.sh swaps every RADIN_* token and marker for the recorded answer. One
# that survived means the run died mid-install, and the skill then ships a
# literal token where a model name or a rule belongs. This script carries the
# token names as its own search pattern and ships into the scanned lib
# directory, so exclude it or it always matches itself.
printf '\nInstall-time substitutions:\n'
if grep -rq --exclude=radin-doctor.sh 'RADIN_MODEL_\|RADIN_CLI \|radin:concurrency' \
	"$CLAUDE_DIR/skills/radin-execute" "$CLAUDE_DIR/skills/radin-plan" \
	"$CLAUDE_DIR/skills/radin-review" "$CLAUDE_DIR/skills/radin-record" \
	"$CLAUDE_DIR/skills/radin-show" "$CLAUDE_DIR/.radin/lib" 2>/dev/null; then
	printf '  INVALID  unsubstituted RADIN_ token or marker -- re-run install.sh\n'
	MISSING=$((MISSING + 1))
else
	printf '  OK       no unsubstituted token or marker left\n'
fi

printf '\nCompanion tools (optional, advisory-only):\n'
check_path_tool "rtk" "rtk"
check_path_tool "codebase-memory-mcp" "codebase-memory-mcp"
check_path_tool "headroom" "headroom"
check_plugin "caveman" "caveman@caveman"
check_plugin "ponytail" "ponytail@ponytail"
check_plugin "mattpocock-skills" "mattpocock-skills@claude-plugins-official"

# Informational, like every companion check: the graph binary can be installed
# and still answer nothing if its Claude Code wiring never landed.
if command -v codebase-memory-mcp >/dev/null 2>&1 || [ -x "$HOME/.local/bin/codebase-memory-mcp" ]; then
	printf '\ncodebase-memory-mcp wiring (informational):\n'
	if [ -f "$CLAUDE_DIR/settings.json" ] && grep -q 'cbm' "$CLAUDE_DIR/settings.json"; then
		printf '  OK       hooks in %s/settings.json\n' "$CLAUDE_DIR"
	else
		printf '  MISSING  hooks in %s/settings.json (re-run install.sh, or radin cbm-config install)\n' "$CLAUDE_DIR"
	fi
	if { [ -f "$HOME/.claude.json" ] && grep -q 'codebase-memory-mcp' "$HOME/.claude.json"; } ||
		{ [ -f "$PWD/.mcp.json" ] && grep -q 'codebase-memory-mcp' "$PWD/.mcp.json"; }; then
		printf '  OK       MCP server entry (user scope or this repo)\n'
	else
		printf '  MISSING  MCP server entry -- run radin cbm-config install, or radin cbm-hooks mcp here\n'
	fi
	if [ -d "$CLAUDE_DIR/.radin/backups" ]; then
		printf '  OK       config snapshots in %s/.radin/backups\n' "$CLAUDE_DIR"
	fi
fi

printf '\n'
if [ "$MISSING" -eq 0 ]; then
	printf 'All expected files present.\n'
	exit 0
else
	printf '%d expected file(s) missing or invalid.\n' "$MISSING"
	exit 1
fi

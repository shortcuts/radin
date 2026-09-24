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

printf '\nSkills (%s/skills):\n' "$CLAUDE_DIR"
# radin-update shipped as a skill before `radin update` took the job; install.sh
# only adds, so only this script can clear the leftover.
for name in radin-execute radin-implement radin-plan radin-record radin-review radin-setup-hooks radin-show radin-stats radin-doctor radin-uninstall radin-update; do
	remove_path "$name" "$CLAUDE_DIR/skills/$name"
done

printf '\nCLI (%s/.radin/bin):\n' "$CLAUDE_DIR"
# The ~/.local/bin symlink is removed only when it points at radin's own
# dispatcher -- anything else there is not ours to delete.
if [ "$(readlink "$HOME/.local/bin/radin" 2>/dev/null)" = "$CLAUDE_DIR/.radin/bin/radin" ]; then
	remove_path "radin (~/.local/bin symlink)" "$HOME/.local/bin/radin"
fi
remove_path "radin (dispatcher)" "$CLAUDE_DIR/.radin/bin/radin"
remove_path "radin-tui" "$CLAUDE_DIR/.radin/bin/radin-tui"
remove_path "radin-cbm-json" "$CLAUDE_DIR/.radin/bin/radin-cbm-json"

printf '\nLib (%s/.radin/lib):\n' "$CLAUDE_DIR"
remove_path "radin-namespace.sh" "$CLAUDE_DIR/.radin/lib/radin-namespace.sh"
remove_path "radin-json.sh" "$CLAUDE_DIR/.radin/lib/radin-json.sh"
remove_path "radin-backlog.sh" "$CLAUDE_DIR/.radin/lib/radin-backlog.sh"
remove_path "radin-tui.c" "$CLAUDE_DIR/.radin/lib/radin-tui.c"
remove_path "radin-cbm-json.c" "$CLAUDE_DIR/.radin/lib/radin-cbm-json.c"
# Shipped while the TUI was bash: install.sh only adds, so only this clears it.
remove_path "radin-tui.sh" "$CLAUDE_DIR/.radin/lib/radin-tui.sh"
remove_path "radin-state.sh" "$CLAUDE_DIR/.radin/lib/radin-state.sh"
remove_path "radin-scope.sh" "$CLAUDE_DIR/.radin/lib/radin-scope.sh"
remove_path "radin-prompt.sh" "$CLAUDE_DIR/.radin/lib/radin-prompt.sh"
remove_path "radin-cbm-hooks.sh" "$CLAUDE_DIR/.radin/lib/radin-cbm-hooks.sh"
remove_path "radin-cbm-config.sh" "$CLAUDE_DIR/.radin/lib/radin-cbm-config.sh"
# Shipped by radin up to the codebase-memory-mcp switch: install.sh only adds,
# so an update leaves it behind and only this script can clear it.
remove_path "radin-crg-hooks.sh" "$CLAUDE_DIR/.radin/lib/radin-crg-hooks.sh"
remove_path "radin-prioritization.md" "$CLAUDE_DIR/.radin/lib/radin-prioritization.md"
for k in planning execution debug factfind; do
	remove_path "radin-prompt-$k.md" "$CLAUDE_DIR/.radin/lib/radin-prompt-$k.md"
done
remove_path "radin-execute-recovery.md" "$CLAUDE_DIR/.radin/lib/radin-execute-recovery.md"
remove_path "radin-execute-reporting.md" "$CLAUDE_DIR/.radin/lib/radin-execute-reporting.md"
remove_path "radin-execute-clarify.md" "$CLAUDE_DIR/.radin/lib/radin-execute-clarify.md"
remove_path "radin-execute-session.md" "$CLAUDE_DIR/.radin/lib/radin-execute-session.md"
remove_path "radin-execute-resume.md" "$CLAUDE_DIR/.radin/lib/radin-execute-resume.md"
remove_path "radin-run.md" "$CLAUDE_DIR/.radin/lib/radin-run.md"
remove_path "radin-update.sh" "$CLAUDE_DIR/.radin/lib/radin-update.sh"
remove_path "radin-doctor.sh" "$CLAUDE_DIR/.radin/lib/radin-doctor.sh"

printf '\nLeft untouched:\n'
printf '  %-20s not vendored by radin, remove manually if wanted\n' "thermo-nuclear"
# rtk and headroom come from whichever manager install.sh asked about, so name
# the matching remover instead of assuming brew.
PKG_MGR=""
if [ -f "$CLAUDE_DIR/.radin/manifest.json" ]; then
	PKG_MGR="$(sed -n 's/.*"package_manager": *"\([^"]*\)".*/\1/p' "$CLAUDE_DIR/.radin/manifest.json" | head -1)"
fi
case "$PKG_MGR" in
brew) RTK_REMOVE="brew uninstall rtk" ;;
mise) RTK_REMOVE="mise rm -g aqua:rtk-ai/rtk" ;;
*) RTK_REMOVE="rm $(command -v rtk 2>/dev/null || printf '%s' "$HOME/.local/bin/rtk")" ;;
esac
printf '  %-20s advisory install, remove with: %s\n' "rtk" "$RTK_REMOVE"
printf '  %-20s advisory install, remove with: codebase-memory-mcp uninstall\n' "codebase-memory-mcp"
if [ "$PKG_MGR" = mise ]; then
	printf '  %-20s advisory install, remove with: mise rm -g pipx:headroom-ai\n' "headroom"
else
	printf '  %-20s advisory install, remove with: pipx uninstall headroom-ai\n' "headroom"
fi
printf '  %-20s advisory install, remove with: claude plugin uninstall caveman@caveman\n' "caveman"
printf '  %-20s advisory install, remove with: claude plugin uninstall ponytail@ponytail\n' "ponytail"
printf '  %-20s advisory install, remove with: claude plugin uninstall mattpocock-skills@claude-plugins-official\n' "mattpocock-skills"
printf '  %s\n' "Any <repo-root>/.claude/.radin/ backlog directory -- your data, your call"
# The guidance block is inside a file radin doesn't own, so it is named, not
# edited out.
if [ -f "$CLAUDE_DIR/CLAUDE.md" ] && grep -q '^<!-- radin:begin -->$' "$CLAUDE_DIR/CLAUDE.md"; then
	printf '  %s\n' "$CLAUDE_DIR/CLAUDE.md keeps a radin section -- delete the lines between <!-- radin:begin --> and <!-- radin:end -->"
fi
if [ -f "$CLAUDE_DIR/CLAUDE.md" ] && grep -qF '<!-- codebase-memory-mcp MCP tools -->' "$CLAUDE_DIR/CLAUDE.md"; then
	printf '  %s\n' "$CLAUDE_DIR/CLAUDE.md keeps the codebase-memory-mcp section written by radin-cbm-hooks.sh -- delete it by hand"
fi
printf '  %s\n' "Any <repo-root>/.mcp.json entry for codebase-memory-mcp -- per-repo config, delete it by hand"
# Copies of the user's own settings.json / .claude.json, taken before upstream
# rewrote them. Deleting someone's only copy of their config is not radin's call.
if [ -d "$CLAUDE_DIR/.radin/backups" ]; then
	printf '  %s\n' "$CLAUDE_DIR/.radin/backups holds copies of your settings.json -- your data, your call"
fi

printf '\nradin removed from ~/.claude.\n'

remove_path "radin-uninstall.sh (this script)" "$CLAUDE_DIR/.radin/lib/radin-uninstall.sh"

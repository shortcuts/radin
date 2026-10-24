#!/usr/bin/env bash
# Removes everything install.sh copies into ~/.claude. Never touches
# thermo-nuclear (not vendored by this repo), the unslop and technical-writing
# skills (fetched from cursor/plugins at install time), companion tools (advisory
# installs), ~/.claude/radin (the fetched source copy), or any per-repo
# .claude/.radin/ backlog directory -- see AGENTS.md's Constraints section.
# Installed to ~/.claude/.radin/lib/radin-uninstall.sh by install.sh.
#
# Usage: radin-uninstall.sh
# Must stay bash-3.2-compatible (macOS /bin/bash).
set -euo pipefail

CLAUDE_DIR="$HOME/.claude"
# BEGIN shipped (generated from SHIPPED by scripts/shipped.sh; run make gen, never edit)
SHIPPED_SKILLS="radin-batch radin-do radin-plan radin-record radin-review radin-stats radin-uninstall"
SHIPPED_LIB="radin-namespace.sh radin-json.sh radin-backlog.sh radin-tui.c radin-cbm-json.c radin-state.sh radin-scope.sh radin-prompt.sh radin-prompt-planning.md radin-prompt-execution.md radin-prompt-debug.md radin-prompt-factfind.md radin-prompt-gate.md radin-prompt-merge.md radin-leaf-contract.md radin-comment-rule.md radin-explore-rule.md radin-open-decisions.md radin-prioritization.md radin-batch-recovery.md radin-batch-reporting.md radin-batch-gate.md radin-batch-merge.md radin-batch-review.md radin-batch-clarify.md radin-batch-session.md radin-batch-resume.md radin-run.md radin-review-core.md radin-cbm-hooks.sh radin-cbm-config.sh radin-update.sh radin-stats.sh radin-doctor.sh radin-uninstall.sh"
RENAMED_SKILLS="radin-execute radin-implement radin-run"
RETIRED_SKILLS="radin-update radin-show radin-doctor radin-setup-hooks"
RETIRED_LIB="radin-tui.sh radin-crg-hooks.sh radin-execute-recovery.md radin-execute-reporting.md radin-execute-gate.md radin-execute-review.md radin-execute-clarify.md radin-execute-session.md radin-execute-resume.md"
# END shipped

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
# install.sh only adds, so only this script clears a skill an older radin shipped.
for name in $SHIPPED_SKILLS $RENAMED_SKILLS $RETIRED_SKILLS; do
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
for name in $SHIPPED_LIB $RETIRED_LIB; do
	# This script goes last: bash reads a script as it runs.
	[ "$name" = radin-uninstall.sh ] || remove_path "$name" "$CLAUDE_DIR/.radin/lib/$name"
done

printf '\nLeft untouched:\n'
printf '  %-20s not vendored by radin, remove manually if wanted\n' "thermo-nuclear"
for pstack_skill in unslop technical-writing; do
	printf '  %-20s fetched from cursor/plugins at install time, remove manually if wanted\n' "$pstack_skill"
done
# rtk comes from whichever manager install.sh asked about, so name the matching
# remover instead of assuming brew. headroom stays listed for installs made by
# a radin that still shipped it.
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
printf '  %-20s %s\n' "" "$CLAUDE_DIR/.ponytail-band stays -- run /ponytail band on to show the band again"
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

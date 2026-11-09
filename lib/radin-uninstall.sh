#!/usr/bin/env bash
# Removes everything install.sh installed for every host (claude, codex,
# opencode): the files the manifest lists whose digest still matches, radin's
# guidance blocks and the opencode allow rule. Never touches
# thermo-nuclear (not vendored by this repo), the unslop and technical-writing
# skills (fetched from cursor/plugins at install time), companion tools (advisory
# installs), ~/.claude/radin (the fetched source copy), or any per-repo
# .radin/ backlog directory -- see AGENTS.md's Constraints section.
# Installed to ~/.radin/lib/radin-uninstall.sh by install.sh.
#
# Usage: radin-uninstall.sh [--dry-run] [--force]
# Must stay bash-3.2-compatible (macOS /bin/bash).
set -euo pipefail

DRY=""
FORCE=""
for arg in "$@"; do
	case "$arg" in
	--dry-run) DRY=1 ;;
	--force) FORCE=1 ;;
	*)
		printf 'usage: radin-uninstall.sh [--dry-run] [--force]\n' >&2
		exit 2
		;;
	esac
done

CLAUDE_DIR="$HOME/.claude"
RADIN_HOME="$HOME/.radin"
# BEGIN shipped (generated from SHIPPED by tests/shipped.rs; run make gen, never edit)
SHIPPED_SKILLS="radin-batch radin-do radin-plan radin-record radin-review radin-stats radin-teardown radin-uninstall"
SHIPPED_LIB="radin-host.sh radin-namespace.sh radin-json.sh radin-migrate.sh radin-backlog.sh radin-tui.c radin-cbm-json.c radin-state.sh radin-scope.sh radin-prompt.sh forbid-claude.txt forbid-agents.txt radin-cbm-hooks.sh radin-cbm-config.sh radin-update.sh radin-stats.sh radin-telemetry.sh radin-doctor.sh radin-uninstall.sh skill-names-claude.txt skill-names-agents.txt companion-skills.txt"
SHIPPED_HOSTLIB="radin-prompt-planning.md radin-prompt-execution.md radin-prompt-debug.md radin-prompt-factfind.md radin-prompt-gate.md radin-prompt-merge.md radin-leaf-contract.md radin-comment-rule.md radin-explore-rule.md radin-open-decisions.md radin-ask-rule.md radin-complexity-rule.md radin-planning-rule.md radin-prioritization.md radin-batch-recovery.md radin-batch-reporting.md radin-batch-gate.md radin-batch-merge.md radin-batch-clarify.md radin-batch-session.md radin-batch-resume.md radin-run.md radin-review-core.md"
RENAMED_SKILLS="radin-execute radin-implement radin-run"
RETIRED_SKILLS="radin-update radin-show radin-doctor radin-setup-hooks"
# END shipped

TAB="$(printf '\t')"
MANIFEST="$RADIN_HOME/manifest.json"
manifest_list() {
	[ -f "$MANIFEST" ] || return 0
	sed -n 's/.*"'"$1"'": *\[\([^]]*\)\].*/\1/p' "$MANIFEST" | head -1 | tr -d '",'
}
manifest_value() {
	[ -f "$MANIFEST" ] || return 0
	sed -n 's/.*"'"$1"'": *"\{0,1\}\([^",]*\)"\{0,1\}.*/\1/p' "$MANIFEST" | head -1
}
# `key<TAB>digest` lines of the files map.
manifest_files() {
	[ -f "$MANIFEST" ] || return 0
	sed -n '/^  "files": {/,/^  }/p' "$MANIFEST" | sed -n 's/^    "\(.*\)": "\(.*\)",\{0,1\}$/\1'"$TAB"'\2/p'
}
# ponytail: third copy of install.sh's sha256_of, next to radin-doctor.sh's; this script must run on a broken install
sha256_of() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | cut -d' ' -f1
	else
		shasum -a 256 "$1" | cut -d' ' -f1
	fi
}

# A manifest without a files map (or none at all) is a pre-digest install: claude only, every shipped name is radin's.
HAS_FILES=""
if [ -f "$MANIFEST" ] && grep -q '^  "files": {' "$MANIFEST"; then HAS_FILES=1; fi
hosts="$(manifest_list hosts)"
host_installed() {
	case " $hosts " in *" $1 "*) return 0 ;; esac
	[ "$1" = claude ] && { [ -z "$hosts" ] || [ -z "$HAS_FILES" ]; }
}
owned_lines() {
	local n
	if [ -n "$HAS_FILES" ]; then
		manifest_files
		return
	fi
	for n in $SHIPPED_SKILLS; do printf '.claude/skills/%s\t\n' "$n"; done
	for n in $SHIPPED_LIB; do printf '.radin/lib/%s\t\n' "$n"; done
	for n in $SHIPPED_HOSTLIB; do printf '.radin/hosts/claude/lib/%s\t\n' "$n"; done
	printf '.radin/bin/radin\t\n'
}

EDITED=0
# rm -rf covers a plain file and a directory, the only kind a pre-digest list holds.
remove_path() {
	local label="$1" path="$2"
	if [ -e "$path" ] || [ -L "$path" ]; then
		if [ -n "$DRY" ]; then
			printf '  WOULD REMOVE %s\n' "$label"
		else
			rm -rf -- "$path"
			printf '  REMOVED  %s\n' "$label"
		fi
	else
		printf '  ABSENT   %s\n' "$label"
	fi
}

# Removes a path under $HOME only when its recorded digest still matches.
remove_owned() {
	local rel="$1" want="$2" path="$HOME/$1" mine=""
	if [ "$want" = "-" ]; then
		printf '  KEPT (not radin'"'"'s) %s\n' "$rel"
		return
	fi
	if [ ! -e "$path" ] && [ ! -L "$path" ]; then
		printf '  ABSENT   %s\n' "$rel"
		return
	fi
	if [ -z "$want" ] || { [ -n "$FORCE" ] && { [ -L "$path" ] || [ ! -d "$path" ]; }; }; then
		mine=1
	elif [ -f "$path" ] && [ ! -L "$path" ] && [ "$(sha256_of "$path")" = "$want" ]; then
		mine=1
	fi
	if [ -n "$mine" ]; then
		remove_path "$rel" "$path"
	else
		printf '  KEPT (edited) %s\n' "$rel"
		EDITED=$((EDITED + 1))
	fi
}

# Empties the directories a removed file leaves, up to the host's own root, and only with rmdir.
prune_dirs() {
	local d
	d="$(dirname "$HOME/$1")"
	while :; do
		case "$d/" in
		"$HOME/.claude/skills/"?* | "$HOME/.agents/skills/"?* | "$RADIN_HOME/"?*) ;;
		*) return ;;
		esac
		[ -d "$d" ] || {
			d="$(dirname "$d")"
			continue
		}
		if ! rmdir "$d" 2>/dev/null; then
			case "$PRUNE_SEEN" in *"|$d|"*) ;; *) printf '  KEPT (holds other files) %s\n' "$d" ;; esac
			PRUNE_SEEN="$PRUNE_SEEN|$d|"
			return
		fi
		d="$(dirname "$d")"
	done
}

# Removes the radin block of a guidance file when its markers are exactly one balanced pair.
strip_block() {
	local file="$1" b e tmp
	[ -f "$file" ] || return 0
	b="$(grep -c '^<!-- radin:begin -->$' "$file" || true)"
	e="$(grep -c '^<!-- radin:end -->$' "$file" || true)"
	[ "$b$e" != 00 ] || return 0
	if [ "$b$e" != 11 ] || [ "$(grep -n '^<!-- radin:begin -->$' "$file" | cut -d: -f1)" -gt "$(grep -n '^<!-- radin:end -->$' "$file" | cut -d: -f1)" ]; then
		printf '  KEPT (markers unbalanced) %s: delete the radin block by hand\n' "$file"
		return
	fi
	if [ -n "$DRY" ]; then
		printf '  WOULD STRIP %s\n' "$file"
		return
	fi
	tmp="$(mktemp)"
	awk '/^<!-- radin:begin -->$/ { skip = 1 } !skip { print } /^<!-- radin:end -->$/ { skip = 0 }' "$file" |
		awk 'NF { while (pending-- > 0) print ""; pending = 0; print; next } { pending++ }' >"$tmp"
	cat "$tmp" >"$file"
	rm -f "$tmp"
	printf '  STRIPPED %s\n' "$file"
}

remove_opencode_allow() {
	local cfg real
	cfg="$(manifest_value opencode_allow)"
	if [ -z "$cfg" ]; then
		printf '  SKIPPED  no opencode rule recorded -- remove the external_directory rule for %s/** by hand\n' "$RADIN_HOME"
	elif [ ! -x "$RADIN_HOME/bin/radin-cbm-json" ]; then
		printf '  SKIPPED  radin-cbm-json not built -- remove the external_directory rule for %s/** from %s by hand\n' "$RADIN_HOME" "$cfg"
	elif [ -n "$DRY" ]; then
		printf '  WOULD REMOVE opencode external_directory rule in %s\n' "$cfg"
	else
		real="$(cd "$RADIN_HOME" && pwd -P)"
		if "$RADIN_HOME/bin/radin-cbm-json" remove-ext-dir "$cfg" "$RADIN_HOME/**" "$real/**" >/dev/null; then
			printf '  REMOVED  opencode external_directory rule %s/** in %s\n' "$RADIN_HOME" "$cfg"
		else
			printf '  SKIPPED  %s is not plain JSON -- remove the external_directory rule for %s/** by hand\n' "$cfg" "$RADIN_HOME"
		fi
	fi
}

printf 'radin uninstall\n===============\n'
[ -z "$DRY" ] || printf '(dry run: nothing changes)\n'

if host_installed claude; then
	printf '\nPermissions (%s/settings.json):\n' "$CLAUDE_DIR"
	# Only the Read rules install.sh added; the helper matches whole strings, so a
	# rule the user wrote stays. Runs first because it needs the files removed below.
	if [ ! -x "$RADIN_HOME/bin/radin-cbm-json" ] || [ ! -f "$RADIN_HOME/lib/radin-cbm-config.sh" ]; then
		printf '  SKIPPED  radin-cbm-json not built -- remove any Read(.../.radin/**) rule from settings.json by hand\n'
	elif [ -n "$DRY" ]; then
		printf '  WOULD REMOVE the Read(.../.radin/**) rules\n'
	else
		bash "$RADIN_HOME/lib/radin-cbm-config.sh" unallow || printf '  SKIPPED  settings.json is not valid JSON -- remove the Read(.../.radin/**) rules by hand\n'
	fi
fi
if host_installed opencode; then
	printf '\nopencode config:\n'
	remove_opencode_allow
fi

printf '\nGuidance blocks:\n'
host_installed claude && strip_block "$CLAUDE_DIR/CLAUDE.md"
host_installed codex && strip_block "${CODEX_HOME:-$HOME/.codex}/AGENTS.md"
host_installed opencode && strip_block "${XDG_CONFIG_HOME:-$HOME/.config}/opencode/AGENTS.md"

printf '\nFiles:\n'
OWNED="$(owned_lines)"
PRUNE_SEEN=""
while IFS="$TAB" read -r rel want; do
	[ -n "$rel" ] || continue
	remove_owned "$rel" "$want"
done <<<"$OWNED"
# install.sh only adds, so only this script clears a skill an older radin shipped.
for name in $RENAMED_SKILLS $RETIRED_SKILLS; do
	remove_path ".claude/skills/$name" "$CLAUDE_DIR/skills/$name"
done
[ -n "$DRY" ] || while IFS="$TAB" read -r rel _; do
	[ -n "$rel" ] && prune_dirs "$rel"
done <<<"$OWNED"

printf '\nCLI (%s/bin):\n' "$RADIN_HOME"
# The ~/.local/bin symlink is removed only when it points at radin's own
# dispatcher -- anything else there is not ours to delete.
link_now="$(readlink "$HOME/.local/bin/radin" 2>/dev/null || true)"
if [ "$link_now" = "$RADIN_HOME/bin/radin" ] || [ "$link_now" = "$CLAUDE_DIR/.radin/bin/radin" ]; then
	remove_path "radin (~/.local/bin symlink)" "$HOME/.local/bin/radin"
fi
remove_path "radin-tui" "$RADIN_HOME/bin/radin-tui"
remove_path "radin-cbm-json" "$RADIN_HOME/bin/radin-cbm-json"
remove_path "build stamp" "$RADIN_HOME/bin/.radin-tui.sum"
remove_path "build stamp" "$RADIN_HOME/bin/.radin-cbm-json.sum"
[ -n "$DRY" ] || rmdir "$RADIN_HOME/bin" 2>/dev/null || true

printf '\nLeft untouched:\n'
printf '  %-20s not vendored by radin, remove manually if wanted\n' "thermo-nuclear"
for pstack_skill in unslop technical-writing; do
	printf '  %-20s fetched from cursor/plugins at install time, remove manually if wanted\n' "$pstack_skill"
done
# rtk comes from whichever manager install.sh asked about, so name the matching
# remover instead of assuming brew. headroom stays listed for installs made by
# a radin that still shipped it.
PKG_MGR=""
if [ -f "$RADIN_HOME/manifest.json" ]; then
	PKG_MGR="$(sed -n 's/.*"package_manager": *"\([^"]*\)".*/\1/p' "$RADIN_HOME/manifest.json" | head -1)"
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
printf '  %s\n' "Any <repo-root>/.radin/ backlog directory -- your data, your call"
if [ -f "$CLAUDE_DIR/CLAUDE.md" ] && grep -qF '<!-- codebase-memory-mcp MCP tools -->' "$CLAUDE_DIR/CLAUDE.md"; then
	printf '  %s\n' "$CLAUDE_DIR/CLAUDE.md keeps the codebase-memory-mcp section written by radin-cbm-hooks.sh -- delete it by hand"
fi
printf '  %s\n' "Any <repo-root>/.mcp.json entry for codebase-memory-mcp -- per-repo config, delete it by hand"
# Copies of the user's own settings.json / .claude.json, taken before upstream
# rewrote them. Deleting someone's only copy of their config is not radin's call.
if [ -d "$RADIN_HOME/backups" ]; then
	printf '  %s\n' "$RADIN_HOME/backups holds copies of your settings.json -- your data, your call"
fi
if [ -d "$RADIN_HOME/telemetry" ]; then
	printf '  %s\n' "$RADIN_HOME/telemetry holds your telemetry records -- your data, your call"
fi

if [ -n "$(manifest_list agents_skills)" ]; then
	printf '  %s\n' "$HOME/.agents/skills: $(manifest_list agents_skills) -- fetched companion skills, remove by hand if wanted"
fi
if [ -z "$HAS_FILES" ]; then
	# No manifest proves who owns an agents-render file.
	held=""
	for p in "$HOME"/.agents/skills/radin-* "$RADIN_HOME/hosts/agents"; do
		[ ! -e "$p" ] || held="$held $p"
	done
	[ -z "$held" ] || printf '  %s\n' "agents render, remove by hand:$held"
fi

if [ -n "$DRY" ]; then
	printf '\nDry run done. Nothing changed.\n'
	exit 0
fi
# A kept edited file keeps the manifest: the next --force run needs its digest.
if [ "$EDITED" -eq 0 ]; then
	rm -f "$MANIFEST" "$RADIN_HOME/install_root"
	rmdir "$RADIN_HOME" 2>/dev/null || true
	printf '\nradin removed.\n'
else
	printf '\nradin removed, except %s edited file(s). Run again with --force to remove them.\n' "$EDITED"
fi

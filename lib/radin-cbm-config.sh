#!/usr/bin/env bash
# Runs codebase-memory-mcp's own Claude Code configuration -- its skill, three
# graph agents, MCP entries and lifecycle hooks -- and puts back what that
# write drops. Upstream #1200 (open through v0.10.8) replaces the whole
# SessionStart array in ~/.claude/settings.json instead of merging into it, so
# any hook another tool owns disappears silently. `codebase-memory-mcp update`
# reruns the same write, which is why this is a shipped command and not a
# one-shot inside install.sh.
#
#   radin cbm-config install   snapshot, run upstream's config, restore, report
#   radin cbm-config repair    restore from the newest snapshot (after an update)
#
# Restoring only ever puts back an entry that was in the snapshot and is now
# missing; upstream's own entries stay, and radin adds none of its own. The
# pre-existing entries go back first, upstream's after, so relative order
# inside each hook event survives.
# Scope limits (full list in docs/technical-constraints.md): this covers Claude
# Code's two files only, while upstream configures 45 client surfaces; it
# restores rather than rolls back, so it cannot undo the configuration
# (`codebase-memory-mcp uninstall` does); and `repair` reads the newest
# snapshot, which after one install already holds upstream's own entries.
# Installed to ~/.claude/.radin/lib/radin-cbm-config.sh by install.sh.
# Must stay bash-3.2-compatible (macOS /bin/bash).
set -euo pipefail

CLAUDE_DIR="$HOME/.claude"
SETTINGS="$CLAUDE_DIR/settings.json"
# Claude Code's user-scope config, where upstream writes the MCP server entry.
CLAUDE_JSON="$HOME/.claude.json"
BACKUP_DIR="$CLAUDE_DIR/.radin/backups"
CBM_NAME="codebase-memory-mcp"
# Upstream refuses every write under a symlinked ~/.claude and then drops
# Claude Code from its target list without failing (#1722, closed unresolved):
# exit 0, no skill, no agents, no hooks. Its own CLAUDE_CONFIG_DIR override
# takes the resolved path, so pass that when the link is what we have. `cd`
# plus `pwd -P` rather than realpath/readlink -f -- neither exists on a stock
# macOS.
CLAUDE_REAL_DIR="$CLAUDE_DIR"
[ ! -d "$CLAUDE_DIR" ] || CLAUDE_REAL_DIR="$(cd "$CLAUDE_DIR" && pwd -P)"
CONFIG_DIR_OVERRIDE=""
if [ "$CLAUDE_REAL_DIR" != "$CLAUDE_DIR" ] && [ -z "${CLAUDE_CONFIG_DIR:-}" ]; then
	CONFIG_DIR_OVERRIDE="$CLAUDE_REAL_DIR"
fi
# Where that override makes upstream write the MCP entry instead of
# ~/.claude.json -- adopted below, since Claude Code reads the latter.
STAGED_CLAUDE_JSON="$CLAUDE_REAL_DIR/.claude.json"

# Every JSON read and write here is C (lib/radin-cbm-json.c) -- radin ships
# bash and C only, and this script holds no JSON knowledge of its own. Next to
# this script in a dev checkout, in ~/.claude/.radin/bin once install.sh has
# built it.
CBM_JSON="$(cd "$(dirname "$0")" && pwd)/radin-cbm-json"
[ -x "$CBM_JSON" ] || CBM_JSON="$HOME/.claude/.radin/bin/radin-cbm-json"

die() {
	printf 'radin-cbm-config: %s\n' "$*" >&2
	exit 1
}

[ -x "$CBM_JSON" ] || die "radin-cbm-json not built (no C compiler at install time) -- it is what puts your own hooks back after upstream's write, so this command refuses to run without it. Use 'radin cbm-hooks all' for the merge-only wiring instead."

cbm_bin() {
	local bin
	bin="$(command -v "$CBM_NAME" || true)"
	[ -n "$bin" ] || bin="$HOME/.local/bin/$CBM_NAME"
	[ -x "$bin" ] || return 1
	printf '%s' "$bin"
}

# One timestamped pair per run: settings.json is the file at risk, .claude.json
# carries the MCP entries. Copies only -- radin never deletes a snapshot.
snapshot() {
	local stamp
	stamp="$(date -u +%Y%m%dT%H%M%SZ)"
	mkdir -p "$BACKUP_DIR"
	SNAP_SETTINGS="$BACKUP_DIR/settings.json.$stamp.bak"
	SNAP_CLAUDE_JSON="$BACKUP_DIR/claude.json.$stamp.bak"
	if [ -f "$SETTINGS" ]; then
		cp "$SETTINGS" "$SNAP_SETTINGS"
		printf 'SNAPSHOT %s\n' "$SNAP_SETTINGS"
	else
		SNAP_SETTINGS=""
		printf 'ABSENT   %s (nothing to snapshot)\n' "$SETTINGS"
	fi
	if [ -f "$CLAUDE_JSON" ]; then
		cp "$CLAUDE_JSON" "$SNAP_CLAUDE_JSON"
		printf 'SNAPSHOT %s\n' "$SNAP_CLAUDE_JSON"
	else
		SNAP_CLAUDE_JSON=""
		printf 'ABSENT   %s (nothing to snapshot)\n' "$CLAUDE_JSON"
	fi
}

# Newest snapshot of one file: the glob sorts lexicographically, which for this
# timestamp format is chronological. A loop, not `ls | grep | tail`, because an
# empty match there exits non-zero under pipefail and `set -e` would kill the
# caller mid-repair.
newest_snapshot() {
	local prefix="$1" newest="" f
	[ -d "$BACKUP_DIR" ] || return 0
	for f in "$BACKUP_DIR/$prefix."*.bak; do
		[ -f "$f" ] || continue
		newest="$f"
	done
	printf '%s' "$newest"
}

restore() {
	"$CBM_JSON" restore "$SETTINGS" "$1" "$CLAUDE_JSON" "$2" "$CBM_NAME"
}

# Upstream bakes an absolute $HOME path into each hook script it writes
# (BIN='/Users/<you>/.local/bin/codebase-memory-mcp') and leaves an existing
# one alone on a rerun, so a ~/.claude shared between machines keeps the other
# machine's path and every hook fails open -- silently, doing nothing. Move
# them into the snapshot directory so upstream has to write them again for
# this machine. Moved, never deleted: they are not radin's files.
stash_hook_scripts() {
	local dir="$CLAUDE_REAL_DIR/hooks" stamp f dest
	[ -d "$dir" ] || return 0
	stamp="$(date -u +%Y%m%dT%H%M%SZ)"
	for f in "$dir"/cbm-*; do
		[ -f "$f" ] || continue
		dest="$BACKUP_DIR/hooks.$stamp"
		mkdir -p "$dest"
		mv "$f" "$dest/"
		printf 'STASHED  %s -> %s (upstream rewrites it for this machine)\n' "$f" "$dest/"
	done
}

# With CLAUDE_CONFIG_DIR set, upstream writes its MCP entry to
# $CLAUDE_CONFIG_DIR/.claude.json. Claude Code reads ~/.claude.json unless the
# user exports the same variable, so move that one key over. Never overwrites
# an existing entry, and never deletes the staged file -- radin didn't ship it.
adopt_staged_mcp() {
	[ -n "$CONFIG_DIR_OVERRIDE" ] || return 0
	[ -f "$STAGED_CLAUDE_JSON" ] || return 0
	"$CBM_JSON" adopt-mcp "$STAGED_CLAUDE_JSON" "$CLAUDE_JSON"
}

# Did upstream's configuration actually land? It exits 0 on the symlink
# refusal above, so the caller needs this as a status and not just a printed
# line -- a silent no-op is the other way to end up with half a stack.
cbm_wired() {
	"$CBM_JSON" wired "$SETTINGS" "$CLAUDE_JSON" "$CBM_NAME"
}

# Upstream reads CLAUDE_CONFIG_DIR as set even when it is empty, so pass it
# only when the symlink check produced a path.
run_upstream() {
	local bin="$1" log="$2"
	if [ -n "$CONFIG_DIR_OVERRIDE" ]; then
		printf 'SYMLINK  %s resolves to %s -- passing it as CLAUDE_CONFIG_DIR (#1722)\n' \
			"$CLAUDE_DIR" "$CLAUDE_REAL_DIR"
		CLAUDE_CONFIG_DIR="$CONFIG_DIR_OVERRIDE" "$bin" install -y >"$log" 2>&1
	else
		"$bin" install -y >"$log" 2>&1
	fi
}

cmd_install() {
	local bin
	bin="$(cbm_bin)" || die "$CBM_NAME not found on PATH or in ~/.local/bin -- run radin's install.sh first"
	snapshot
	stash_hook_scripts
	local log
	log="$(mktemp)"
	if ! run_upstream "$bin" "$log"; then
		tail -n 20 "$log" >&2
		rm -f "$log"
		# Its config pass is transactional per client, not per file, so a failed
		# run can still have rewritten settings.json -- and can have finished
		# Claude Code before failing on a later step (its version-activation lock
		# is one). Restore, adopt, then let the end state decide: what install.sh
		# branches on is whether the graph is wired, not which step complained.
		printf 'FAILED   %s install -- restoring from the snapshot anyway\n' "$CBM_NAME" >&2
		restore "${SNAP_SETTINGS:-}" "${SNAP_CLAUDE_JSON:-}"
		adopt_staged_mcp
		cbm_wired || exit 1
		printf 'PARTIAL  %s reported a failure after configuring Claude Code -- hooks and MCP entry are in place\n' "$CBM_NAME" >&2
		exit 0
	fi
	rm -f "$log"
	printf 'CONFIGURED %s install -y\n' "$CBM_NAME"
	restore "${SNAP_SETTINGS:-}" "${SNAP_CLAUDE_JSON:-}"
	adopt_staged_mcp
	# An exit 0 that wired nothing is what makes install.sh claim the tool is
	# ready when it is not, so end non-zero and let its fallback branch run.
	cbm_wired || die "$CBM_NAME exited 0 but configured no Claude Code hooks or MCP entry -- your own hooks are untouched. Use 'radin cbm-hooks all' for the merge-only wiring."
}

cmd_repair() {
	local snap_settings snap_claude_json
	snap_settings="$(newest_snapshot 'settings.json')"
	snap_claude_json="$(newest_snapshot 'claude.json')"
	[ -n "$snap_settings" ] || [ -n "$snap_claude_json" ] || die "no snapshot in $BACKUP_DIR -- nothing to repair from"
	[ -z "$snap_settings" ] || printf 'FROM     %s\n' "$snap_settings"
	[ -z "$snap_claude_json" ] || printf 'FROM     %s\n' "$snap_claude_json"
	restore "$snap_settings" "$snap_claude_json"
	adopt_staged_mcp
	# Informational here: repair puts back what an update dropped, and a
	# never-configured machine is install's job, not this one's.
	cbm_wired || true
}

case "${1:-}" in
install) cmd_install ;;
repair) cmd_repair ;;
*)
	die "usage: radin-cbm-config.sh <install|repair>"
	;;
esac

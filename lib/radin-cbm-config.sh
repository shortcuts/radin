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
# Installed to ~/.claude/.radin/lib/radin-cbm-config.sh by install.sh.
# Must stay bash-3.2-compatible (macOS /bin/bash).
set -euo pipefail

CLAUDE_DIR="$HOME/.claude"
SETTINGS="$CLAUDE_DIR/settings.json"
# Claude Code's user-scope config, where upstream writes the MCP server entry.
CLAUDE_JSON="$HOME/.claude.json"
BACKUP_DIR="$CLAUDE_DIR/.radin/backups"
CBM_NAME="codebase-memory-mcp"

die() {
	printf 'radin-cbm-config: %s\n' "$*" >&2
	exit 1
}

cbm_bin() {
	local bin
	bin="$(command -v "$CBM_NAME" || true)"
	[ -n "$bin" ] || bin="$HOME/.local/bin/$CBM_NAME"
	[ -x "$bin" ] || return 1
	printf '%s' "$bin"
}

command -v python3 >/dev/null 2>&1 || die "python3 not found -- it is what puts your own hooks back after upstream's write, so this command refuses to run without it. Use 'radin cbm-hooks all' for the merge-only wiring instead."

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
	local snap_settings="$1" snap_claude_json="$2"
	python3 - "$SETTINGS" "$snap_settings" "$CLAUDE_JSON" "$snap_claude_json" "$CBM_NAME" <<'PY'
import json, sys

settings_path, snap_settings, claude_json_path, snap_claude_json, cbm = sys.argv[1:6]


def load(path, label):
    if not path:
        return None
    try:
        with open(path) as f:
            return json.load(f)
    except FileNotFoundError:
        return None
    except json.JSONDecodeError:
        sys.exit(f"radin-cbm-config: {label} is not valid JSON -- nothing restored, "
                 f"your snapshot is still on disk")


def save(path, data):
    with open(path, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")


def entry_key(entry):
    return json.dumps(entry, sort_keys=True)


def restore_settings():
    old = load(snap_settings, snap_settings)
    if old is None:
        return
    new = load(settings_path, settings_path)
    if new is None:
        save(settings_path, old)
        print(f"RESTORED {settings_path} (whole file -- upstream's write removed it)")
        return
    changed = False

    for key, value in old.items():
        if key == "hooks":
            continue
        if key not in new:
            new[key] = value
            changed = True
            print(f"RESTORED {settings_path} ({key})")

    old_hooks = old.get("hooks") or {}
    if old_hooks and not isinstance(new.get("hooks"), dict):
        new["hooks"] = {}
    new_hooks = new.get("hooks") if isinstance(new.get("hooks"), dict) else {}

    for event, old_entries in old_hooks.items():
        if not isinstance(old_entries, list):
            continue
        current = new_hooks.get(event)
        if not isinstance(current, list):
            new_hooks[event] = old_entries
            changed = True
            print(f"RESTORED {settings_path} (hooks.{event}: {len(old_entries)} "
                  f"entr{'y' if len(old_entries) == 1 else 'ies'}, array was gone)")
            continue
        present = {entry_key(e) for e in current}
        missing = [e for e in old_entries if entry_key(e) not in present]
        if missing:
            # Pre-existing entries first, upstream's after: their order inside
            # the event is what the owning tool expects.
            new_hooks[event] = missing + current
            changed = True
            print(f"RESTORED {settings_path} (hooks.{event}: {len(missing)} "
                  f"entr{'y' if len(missing) == 1 else 'ies'})")
        else:
            print(f"INTACT   {settings_path} (hooks.{event})")

    if changed:
        save(settings_path, new)


def restore_mcp_servers():
    old = load(snap_claude_json, snap_claude_json)
    if old is None:
        return
    new = load(claude_json_path, claude_json_path)
    if new is None:
        save(claude_json_path, old)
        print(f"RESTORED {claude_json_path} (whole file -- upstream's write removed it)")
        return
    old_servers = old.get("mcpServers")
    if not isinstance(old_servers, dict) or not old_servers:
        return
    if not isinstance(new.get("mcpServers"), dict):
        new["mcpServers"] = {}
    servers = new["mcpServers"]
    restored = [name for name in old_servers if name not in servers]
    for name in restored:
        servers[name] = old_servers[name]
        print(f"RESTORED {claude_json_path} (mcpServers.{name})")
    if restored:
        save(claude_json_path, new)
    else:
        print(f"INTACT   {claude_json_path} (mcpServers)")


def report_cbm():
    # Did upstream's configuration actually land? A silent no-op here is the
    # other way to end up with half a stack.
    settings = load(settings_path, settings_path) or {}
    claude_json = load(claude_json_path, claude_json_path) or {}
    # Its hook entries run shims named cbm-* rather than the full binary name,
    # so match either spelling.
    hooks_blob = json.dumps(settings.get("hooks") or {})
    in_hooks = cbm in hooks_blob or "cbm-" in hooks_blob
    in_mcp = cbm in json.dumps(claude_json.get("mcpServers") or {})
    print(f"CBM      hooks: {'present' if in_hooks else 'absent'}, "
          f"user-scope MCP entry: {'present' if in_mcp else 'absent'}")


restore_settings()
restore_mcp_servers()
report_cbm()
PY
}

cmd_install() {
	local bin
	bin="$(cbm_bin)" || die "$CBM_NAME not found on PATH or in ~/.local/bin -- run radin's install.sh first"
	snapshot
	local log
	log="$(mktemp)"
	if ! "$bin" install -y >"$log" 2>&1; then
		tail -n 20 "$log" >&2
		rm -f "$log"
		# Its config pass is transactional per client, not per file, so a failed
		# run can still have rewritten settings.json before giving up.
		printf 'FAILED   %s install -- restoring from the snapshot anyway\n' "$CBM_NAME" >&2
		restore "${SNAP_SETTINGS:-}" "${SNAP_CLAUDE_JSON:-}"
		exit 1
	fi
	rm -f "$log"
	printf 'CONFIGURED %s install -y\n' "$CBM_NAME"
	restore "${SNAP_SETTINGS:-}" "${SNAP_CLAUDE_JSON:-}"
}

cmd_repair() {
	local snap_settings snap_claude_json
	snap_settings="$(newest_snapshot 'settings.json')"
	snap_claude_json="$(newest_snapshot 'claude.json')"
	[ -n "$snap_settings" ] || [ -n "$snap_claude_json" ] || die "no snapshot in $BACKUP_DIR -- nothing to repair from"
	[ -z "$snap_settings" ] || printf 'FROM     %s\n' "$snap_settings"
	[ -z "$snap_claude_json" ] || printf 'FROM     %s\n' "$snap_claude_json"
	restore "$snap_settings" "$snap_claude_json"
}

case "${1:-}" in
install) cmd_install ;;
repair) cmd_repair ;;
*)
	die "usage: radin-cbm-config.sh <install|repair>"
	;;
esac

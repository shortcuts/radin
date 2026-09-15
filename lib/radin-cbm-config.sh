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
import json, os, shlex, sys

settings_path, snap_settings, claude_json_path, snap_claude_json, cbm = sys.argv[1:6]
HOME = os.path.expanduser("~")


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


# An upstream hook entry whose command spelling changed between versions looks
# dropped rather than replaced, so restoring it resurrects a dead path forever.
# Upstream owns its own entries; radin only puts back another tool's.
def is_cbm_entry(entry):
    blob = json.dumps(entry)
    return cbm in blob or "cbm-" in blob


def command_exists(command):
    if not isinstance(command, str) or not command.strip():
        return True
    # Judge a path only. A bare shim name resolves against Claude Code's PATH,
    # not this script's, so calling it missing here would prune a live hook.
    target = shlex.split(command)[0]
    return "/" not in target or os.path.exists(os.path.expanduser(target))


# A hook command naming a path that does not exist can only fail. Upstream
# merges PreToolUse instead of replacing it, and a ~/.claude shared between
# machines carries the other machine's $HOME, so such an entry survives every
# rerun and prints `no such file or directory` on each session start. Dropped
# whoever wrote it: radin cannot re-point another tool's hook, and leaving it
# in place is the error the user sees.
def prune_dead(new_hooks, settings_path):
    changed = False
    for event, entries in list(new_hooks.items()):
        if not isinstance(entries, list):
            continue
        kept = []
        for entry in entries:
            hooks = entry.get("hooks") if isinstance(entry, dict) else None
            if not isinstance(hooks, list):
                kept.append(entry)
                continue
            live = [h for h in hooks
                    if not isinstance(h, dict) or command_exists(h.get("command"))]
            if len(live) == len(hooks):
                kept.append(entry)
                continue
            changed = True
            for h in hooks:
                if h not in live:
                    print(f"PRUNED   {settings_path} (hooks.{event}: "
                          f"{h.get('command')!r} does not exist)")
            if live:
                entry["hooks"] = live
                kept.append(entry)
        new_hooks[event] = kept
    return changed


# Upstream writes its hook commands as a quoted absolute path, so a ~/.claude
# shared between machines carries the other machine's $HOME and the entry is
# pruned above instead of running. A hook command goes through a shell, which
# expands an unquoted leading ~, so the ~/ form is valid on every machine
# (verified -- docs/technical-constraints.md). Rewritten words go in bare: a
# tilde inside quotes does not expand. Only cbm entries: radin does not
# rewrite another tool's hook.
def portable(command):
    if not isinstance(command, str) or not command.strip():
        return command
    try:
        words = shlex.split(command)
    except ValueError:
        return command
    rewritten, changed = [], False
    for word in words:
        if word.startswith(HOME + "/"):
            rewritten.append("~" + word[len(HOME):])
            changed = True
        else:
            rewritten.append(shlex.quote(word))
    return " ".join(rewritten) if changed else command


def normalize_cbm(new_hooks, settings_path):
    changed = False
    for event, entries in new_hooks.items():
        if not isinstance(entries, list):
            continue
        for entry in entries:
            hooks = entry.get("hooks") if isinstance(entry, dict) else None
            if not isinstance(hooks, list) or not is_cbm_entry(entry):
                continue
            for h in hooks:
                if not isinstance(h, dict):
                    continue
                command = portable(h.get("command"))
                if command != h.get("command"):
                    h["command"] = command
                    changed = True
                    print(f"PORTABLE {settings_path} (hooks.{event}: {command!r})")
    return changed


def restore_settings():
    old = load(snap_settings, snap_settings)
    new = load(settings_path, settings_path)
    if new is None:
        if old is not None:
            save(settings_path, old)
            print(f"RESTORED {settings_path} (whole file -- upstream's write removed it)")
        return
    changed = False

    for key, value in (old or {}).items():
        if key == "hooks":
            continue
        if key not in new:
            new[key] = value
            changed = True
            print(f"RESTORED {settings_path} ({key})")

    old_hooks = (old or {}).get("hooks") or {}
    if old_hooks and not isinstance(new.get("hooks"), dict):
        new["hooks"] = {}
    new_hooks = new.get("hooks") if isinstance(new.get("hooks"), dict) else {}

    for event, old_entries in old_hooks.items():
        if not isinstance(old_entries, list):
            continue
        old_entries = [e for e in old_entries if not is_cbm_entry(e)]
        current = new_hooks.get(event)
        if not isinstance(current, list):
            if not old_entries:
                continue
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

    if prune_dead(new_hooks, settings_path):
        changed = True
    if normalize_cbm(new_hooks, settings_path):
        changed = True
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


restore_settings()
restore_mcp_servers()
PY
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
	python3 - "$STAGED_CLAUDE_JSON" "$CLAUDE_JSON" <<'PY'
import json, os, sys

staged_path, claude_json_path = sys.argv[1:3]


def load(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return None


staged = load(staged_path) or {}
staged_servers = staged.get("mcpServers")
if not isinstance(staged_servers, dict) or not staged_servers:
    sys.exit(0)
target = load(claude_json_path)
if target is None:
    target = {}
if not isinstance(target.get("mcpServers"), dict):
    target["mcpServers"] = {}
servers = target["mcpServers"]


# A ~/.claude.json shared between machines names the other machine's binary,
# which is no entry at all here, so replace it rather than keep it. The
# absolute path stays: Claude Code posix_spawns an mcpServers command instead
# of running it through a shell, so a leading ~ is a literal directory name
# and the server fails with ENOENT (verified -- see
# docs/technical-constraints.md). Detecting a stale path is the only fix
# available here; don't retry the ~/ rewrite the hook commands get.
def stale(name):
    command = (servers.get(name) or {}).get("command")
    return isinstance(command, str) and "/" in command \
        and not os.path.exists(os.path.expanduser(command))


adopted = [name for name in staged_servers if name not in servers or stale(name)]
for name in adopted:
    servers[name] = staged_servers[name]
    print(f"ADOPTED  {claude_json_path} (mcpServers.{name} from {staged_path})")
if adopted:
    with open(claude_json_path, "w") as f:
        json.dump(target, f, indent=2)
        f.write("\n")
PY
}

# Did upstream's configuration actually land? It exits 0 on the symlink
# refusal above, so the caller needs this as a status and not just a printed
# line -- a silent no-op is the other way to end up with half a stack.
cbm_wired() {
	python3 - "$SETTINGS" "$CLAUDE_JSON" "$CBM_NAME" <<'PY'
import json, sys

settings_path, claude_json_path, cbm = sys.argv[1:4]


def load(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


# Its hook entries run shims named cbm-* rather than the full binary name, so
# match either spelling.
hooks_blob = json.dumps(load(settings_path).get("hooks") or {})
in_hooks = cbm in hooks_blob or "cbm-" in hooks_blob
in_mcp = cbm in json.dumps(load(claude_json_path).get("mcpServers") or {})
print(f"CBM      hooks: {'present' if in_hooks else 'absent'}, "
      f"user-scope MCP entry: {'present' if in_mcp else 'absent'}")
sys.exit(0 if in_hooks and in_mcp else 4)
PY
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

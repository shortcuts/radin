#!/usr/bin/env bats
# Exercises lib/radin-cbm-config.sh: run codebase-memory-mcp's own Claude Code
# configuration, then put back every hook and MCP entry its write dropped
# (upstream #1200). A stub binary stands in for the real installer and is what
# simulates the destructive SessionStart rewrite.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  CLI="$REPO_ROOT/lib/radin-cbm-config.sh"
  TEST_HOME="$(mktemp -d)"
  MOCK_BIN="$(mktemp -d)"
  export HOME="$TEST_HOME"
  export PATH="$MOCK_BIN:/usr/bin:/bin:/usr/sbin:/sbin"
  command -v python3 >/dev/null 2>&1 || skip "python3 required"
  mkdir -p "$TEST_HOME/.claude"
}

teardown() {
  rm -rf "$TEST_HOME" "$MOCK_BIN"
}

# Reproduces upstream's behaviour: PreToolUse merges, SessionStart is replaced
# wholesale, and the user-scope MCP entry is added.
stub_cbm() {
  cat > "$MOCK_BIN/codebase-memory-mcp" <<EOF
#!/usr/bin/env python3
import json, os, sys
if sys.argv[1:2] != ["install"]:
    sys.exit(0)
home = os.environ["HOME"]
p = os.path.join(home, ".claude", "settings.json")
try:
    s = json.load(open(p))
except FileNotFoundError:
    s = {}
hooks = s.setdefault("hooks", {})
hooks["SessionStart"] = [{"matcher": "", "hooks": [{"type": "command", "command": "cbm-session-reminder"}]}]
pre = hooks.setdefault("PreToolUse", [])
mine = {"matcher": "Grep|Glob", "hooks": [{"type": "command", "command": "cbm-hook-augment"}]}
if mine not in pre:
    pre.append(mine)
json.dump(s, open(p, "w"), indent=2)
cj = os.path.join(home, ".claude.json")
try:
    c = json.load(open(cj))
except FileNotFoundError:
    c = {}
c.setdefault("mcpServers", {})["codebase-memory-mcp"] = {"command": "codebase-memory-mcp"}
json.dump(c, open(cj, "w"), indent=2)
EOF
  chmod +x "$MOCK_BIN/codebase-memory-mcp"
}

@test "fails without codebase-memory-mcp on PATH or in ~/.local/bin" {
  run bash "$CLI" install
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]]
}

@test "unknown command fails with usage" {
  run bash "$CLI" nope
  [ "$status" -ne 0 ]
  [[ "$output" == *usage* ]]
}

@test "install restores the SessionStart hooks upstream replaced, keeping theirs" {
  stub_cbm
  cat > "$TEST_HOME/.claude/settings.json" <<'EOF'
{"model": "opus",
 "hooks": {"SessionStart": [{"matcher": "", "hooks": [{"type": "command", "command": "caveman-session"}]},
                            {"matcher": "compact", "hooks": [{"type": "command", "command": "ponytail-session"}]}],
           "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "mine"}]}]}}
EOF
  run bash "$CLI" install
  [ "$status" -eq 0 ]
  [[ "$output" == *RESTORED*SessionStart* ]]
  run python3 -c "
import json
h = json.load(open('$TEST_HOME/.claude/settings.json'))['hooks']
cmds = [k['command'] for e in h['SessionStart'] for k in e['hooks']]
assert cmds == ['caveman-session', 'ponytail-session', 'cbm-session-reminder'], cmds
pre = [k['command'] for e in h['PreToolUse'] for k in e['hooks']]
assert 'mine' in pre and 'cbm-hook-augment' in pre, pre
"
  [ "$status" -eq 0 ]
}

@test "install does not resurrect upstream's own stale hook entries" {
  stub_cbm
  cat > "$TEST_HOME/.claude/settings.json" <<'EOF'
{"hooks": {"SessionStart": [{"matcher": "startup", "hooks": [{"type": "command", "command": "'/gone/.config/.claude/hooks/cbm-session-reminder'"}]},
                            {"matcher": "startup", "hooks": [{"type": "command", "command": "cbm-hook-augment --old-spelling"}]},
                            {"matcher": "", "hooks": [{"type": "command", "command": "caveman-session"}]}]}}
EOF
  run bash "$CLI" install
  [ "$status" -eq 0 ]
  run python3 -c "
import json
h = json.load(open('$TEST_HOME/.claude/settings.json'))['hooks']
cmds = [k['command'] for e in h['SessionStart'] for k in e['hooks']]
assert cmds == ['caveman-session', 'cbm-session-reminder'], cmds
"
  [ "$status" -eq 0 ]
}

@test "install prunes hook entries whose command path does not exist" {
  stub_cbm
  touch "$TEST_HOME/live-hook" && chmod +x "$TEST_HOME/live-hook"
  cat > "$TEST_HOME/.claude/settings.json" <<EOF
{"hooks": {"PreToolUse": [{"matcher": "Grep|Glob", "hooks": [{"type": "command", "command": "'/gone/.config/.claude/hooks/cbm-code-discovery-gate'"}]},
                          {"matcher": "Bash", "hooks": [{"type": "command", "command": "/gone/other-tool-hook"}]},
                          {"matcher": "Bash", "hooks": [{"type": "command", "command": "$TEST_HOME/live-hook"}]},
                          {"matcher": "Write", "hooks": [{"type": "command", "command": "bare-shim-not-on-path"}]}]}}
EOF
  run bash "$CLI" install
  [ "$status" -eq 0 ]
  [[ "$output" == *PRUNED*cbm-code-discovery-gate* ]]
  [[ "$output" == *PRUNED*other-tool-hook* ]]
  run python3 -c "
import json
h = json.load(open('$TEST_HOME/.claude/settings.json'))['hooks']
cmds = [k['command'] for e in h['PreToolUse'] for k in e['hooks']]
assert cmds == ['$TEST_HOME/live-hook', 'bare-shim-not-on-path', 'cbm-hook-augment'], cmds
"
  [ "$status" -eq 0 ]
}

@test "install stashes upstream's hook scripts so it rewrites them for this machine" {
  stub_cbm
  mkdir -p "$TEST_HOME/.claude/hooks"
  printf "BIN='/Users/someone-else/.local/bin/codebase-memory-mcp'\n" > "$TEST_HOME/.claude/hooks/cbm-session-reminder"
  echo 'mine' > "$TEST_HOME/.claude/hooks/my-own-hook.sh"
  echo '{}' > "$TEST_HOME/.claude/settings.json"
  run bash "$CLI" install
  [ "$status" -eq 0 ]
  [[ "$output" == *STASHED*cbm-session-reminder* ]]
  [ ! -f "$TEST_HOME/.claude/hooks/cbm-session-reminder" ]
  [ -f "$TEST_HOME/.claude/hooks/my-own-hook.sh" ]
  run bash -c "cat \"$TEST_HOME\"/.claude/.radin/backups/hooks.*/cbm-session-reminder"
  [[ "$output" == *someone-else* ]]
}

@test "install keeps unrelated settings keys and reports the graph is wired" {
  stub_cbm
  echo '{"model": "opus", "env": {"A": "1"}}' > "$TEST_HOME/.claude/settings.json"
  run bash "$CLI" install
  [ "$status" -eq 0 ]
  grep -q '"model": "opus"' "$TEST_HOME/.claude/settings.json"
  grep -q '"A": "1"' "$TEST_HOME/.claude/settings.json"
  [[ "$output" == *"hooks: present"* ]]
  [[ "$output" == *"user-scope MCP entry: present"* ]]
}

@test "install restores an mcpServers entry upstream's write dropped" {
  stub_cbm
  echo '{"mcpServers": {"other": {"command": "x"}}}' > "$TEST_HOME/.claude.json"
  # Upstream's stub rewrites the file from its own parse, which keeps "other";
  # simulate the destructive case by removing it mid-run instead.
  cat > "$MOCK_BIN/codebase-memory-mcp" <<EOF
#!/bin/sh
[ "\$1" = "install" ] || exit 0
printf '%s\n' '{"mcpServers": {"codebase-memory-mcp": {"command": "codebase-memory-mcp"}}}' > "\$HOME/.claude.json"
printf '%s\n' '{"hooks": {"SessionStart": [{"matcher": "", "hooks": [{"type": "command", "command": "cbm-session-reminder"}]}]}}' > "\$HOME/.claude/settings.json"
EOF
  chmod +x "$MOCK_BIN/codebase-memory-mcp"
  run bash "$CLI" install
  [ "$status" -eq 0 ]
  [[ "$output" == *RESTORED*mcpServers.other* ]]
  grep -q '"other"' "$TEST_HOME/.claude.json"
  grep -q '"codebase-memory-mcp"' "$TEST_HOME/.claude.json"
}

@test "install is idempotent: a second run reports INTACT and changes nothing" {
  stub_cbm
  cat > "$TEST_HOME/.claude/settings.json" <<'EOF'
{"hooks": {"SessionStart": [{"matcher": "", "hooks": [{"type": "command", "command": "caveman-session"}]}]}}
EOF
  run bash "$CLI" install
  [ "$status" -eq 0 ]
  before="$(cat "$TEST_HOME/.claude/settings.json")"
  run bash "$CLI" install
  [ "$status" -eq 0 ]
  [[ "$output" == *INTACT* ]]
  [ "$(cat "$TEST_HOME/.claude/settings.json")" = "$before" ]
}

@test "snapshots land in ~/.claude/.radin/backups and are never removed" {
  stub_cbm
  echo '{"model": "opus"}' > "$TEST_HOME/.claude/settings.json"
  run bash "$CLI" install
  [ "$status" -eq 0 ]
  [ "$(ls "$TEST_HOME/.claude/.radin/backups" | grep -c '^settings.json\.')" -eq 1 ]
  grep -q '"model": "opus"' "$TEST_HOME/.claude/.radin/backups/"settings.json.*.bak
}

@test "a failed upstream install still restores from the snapshot" {
  cat > "$MOCK_BIN/codebase-memory-mcp" <<'EOF'
#!/bin/sh
[ "$1" = "install" ] || exit 0
printf '%s\n' '{"hooks": {"SessionStart": []}}' > "$HOME/.claude/settings.json"
echo "boom" >&2
exit 1
EOF
  chmod +x "$MOCK_BIN/codebase-memory-mcp"
  cat > "$TEST_HOME/.claude/settings.json" <<'EOF'
{"hooks": {"SessionStart": [{"matcher": "", "hooks": [{"type": "command", "command": "caveman-session"}]}]}}
EOF
  run bash "$CLI" install
  [ "$status" -ne 0 ]
  grep -q 'caveman-session' "$TEST_HOME/.claude/settings.json"
}

@test "repair works off the newest snapshot, after an upstream update" {
  stub_cbm
  cat > "$TEST_HOME/.claude/settings.json" <<'EOF'
{"hooks": {"SessionStart": [{"matcher": "", "hooks": [{"type": "command", "command": "caveman-session"}]}]}}
EOF
  run bash "$CLI" install
  [ "$status" -eq 0 ]
  # An upstream `update` reruns the same destructive write.
  printf '%s\n' '{"hooks": {"SessionStart": [{"matcher": "", "hooks": [{"type": "command", "command": "cbm-session-reminder"}]}]}}' > "$TEST_HOME/.claude/settings.json"
  run bash "$CLI" repair
  [ "$status" -eq 0 ]
  [[ "$output" == *RESTORED* ]]
  grep -q 'caveman-session' "$TEST_HOME/.claude/settings.json"
}

@test "repair without a snapshot fails instead of guessing" {
  run bash "$CLI" repair
  [ "$status" -ne 0 ]
  [[ "$output" == *"no snapshot"* ]]
}

@test "refuses to touch invalid JSON, leaving the snapshot in place" {
  stub_cbm
  echo '{"model": "opus"}' > "$TEST_HOME/.claude/settings.json"
  run bash "$CLI" install
  [ "$status" -eq 0 ]
  echo 'not json' > "$TEST_HOME/.claude/settings.json"
  run bash "$CLI" repair
  [ "$status" -ne 0 ]
  [ "$(cat "$TEST_HOME/.claude/settings.json")" = "not json" ]
}

# Reproduces upstream #1722: writes under a symlinked ~/.claude are refused,
# and Claude Code silently drops out of the target list. Honours
# CLAUDE_CONFIG_DIR the way the real binary does, including writing the MCP
# entry beside that directory instead of at ~/.claude.json.
stub_cbm_symlink_averse() {
  cat > "$MOCK_BIN/codebase-memory-mcp" <<'EOF'
#!/usr/bin/env python3
import json, os, sys
if sys.argv[1:2] != ["install"]:
    sys.exit(0)
home = os.environ["HOME"]
cfg = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(home, ".claude")
if os.path.islink(cfg.rstrip("/")):
    # "(target: does not exist or cannot be inspected)" -- and exit 0 anyway.
    print("Detected agents: Shell")
    sys.exit(0)
p = os.path.join(cfg, "settings.json")
try:
    s = json.load(open(p))
except FileNotFoundError:
    s = {}
hooks = s.setdefault("hooks", {})
hooks.setdefault("PreToolUse", []).append(
    {"matcher": "Grep|Glob", "hooks": [{"type": "command", "command": "cbm-hook-augment"}]})
json.dump(s, open(p, "w"), indent=2)
cj = os.path.join(cfg, ".claude.json") if os.environ.get("CLAUDE_CONFIG_DIR") \
    else os.path.join(home, ".claude.json")
try:
    c = json.load(open(cj))
except FileNotFoundError:
    c = {}
c.setdefault("mcpServers", {})["codebase-memory-mcp"] = {"command": "codebase-memory-mcp"}
json.dump(c, open(cj, "w"), indent=2)
EOF
  chmod +x "$MOCK_BIN/codebase-memory-mcp"
}

@test "install passes the resolved path when ~/.claude is a symlink, and adopts the staged MCP entry" {
  stub_cbm_symlink_averse
  rm -rf "$TEST_HOME/.claude"
  mkdir -p "$TEST_HOME/.config/.claude"
  ln -s "$TEST_HOME/.config/.claude" "$TEST_HOME/.claude"
  printf '%s\n' '{"hooks": {"SessionStart": [{"matcher": "", "hooks": [{"type": "command", "command": "caveman-session"}]}]}}' > "$TEST_HOME/.config/.claude/settings.json"
  printf '%s\n' '{"mcpServers": {"fff": {"command": "fff"}}}' > "$TEST_HOME/.claude.json"

  run bash "$CLI" install
  [ "$status" -eq 0 ]
  [[ "$output" == *"SYMLINK"* ]]
  [[ "$output" == *"ADOPTED"* ]]
  [[ "$output" == *"hooks: present"* ]]
  [[ "$output" == *"MCP entry: present"* ]]
  # Claude Code reads ~/.claude.json, so the entry has to end up there next to
  # the one that was already present.
  run python3 -c "
import json
c = json.load(open('$TEST_HOME/.claude.json'))
assert sorted(c['mcpServers']) == ['codebase-memory-mcp', 'fff'], c
s = json.load(open('$TEST_HOME/.config/.claude/settings.json'))
assert 'cbm-hook-augment' in json.dumps(s['hooks']['PreToolUse']), s
assert 'caveman-session' in json.dumps(s['hooks']['SessionStart']), s
"
  [ "$status" -eq 0 ]
}

@test "install succeeds when upstream fails after configuring Claude Code" {
  cat > "$MOCK_BIN/codebase-memory-mcp" <<'EOF'
#!/usr/bin/env python3
import json, os, sys
if sys.argv[1:2] != ["install"]:
    sys.exit(0)
home = os.environ["HOME"]
p = os.path.join(home, ".claude", "settings.json")
s = json.load(open(p))
s.setdefault("hooks", {}).setdefault("SessionStart", []).append(
    {"matcher": "", "hooks": [{"type": "command", "command": "cbm-session-reminder"}]})
json.dump(s, open(p, "w"), indent=2)
cj = os.path.join(home, ".claude.json")
c = json.load(open(cj))
c.setdefault("mcpServers", {})["codebase-memory-mcp"] = {"command": "codebase-memory-mcp"}
json.dump(c, open(cj, "w"), indent=2)
# The real binary's version-activation step fails here, after the config pass.
print("error: activation could not reserve exclusive access", file=sys.stderr)
sys.exit(1)
EOF
  chmod +x "$MOCK_BIN/codebase-memory-mcp"
  printf '%s\n' '{"hooks": {"SessionStart": [{"matcher": "", "hooks": [{"type": "command", "command": "caveman-session"}]}]}}' > "$TEST_HOME/.claude/settings.json"
  printf '%s\n' '{"mcpServers": {}}' > "$TEST_HOME/.claude.json"

  run bash "$CLI" install
  [ "$status" -eq 0 ]
  [[ "$output" == *"FAILED"* ]]
  [[ "$output" == *"PARTIAL"* ]]
  [[ "$output" == *"hooks: present"* ]]
}

@test "install fails when upstream exits 0 having configured nothing" {
  cat > "$MOCK_BIN/codebase-memory-mcp" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$MOCK_BIN/codebase-memory-mcp"
  printf '%s\n' '{"hooks": {}}' > "$TEST_HOME/.claude/settings.json"

  run bash "$CLI" install
  [ "$status" -ne 0 ]
  [[ "$output" == *"hooks: absent"* ]]
  [[ "$output" == *"cbm-hooks all"* ]]
}

@test "install rewrites upstream's absolute hook paths to the ~/ form" {
  mkdir -p "$TEST_HOME/.claude/hooks"
  touch "$TEST_HOME/.claude/hooks/cbm-session-reminder" "$TEST_HOME/other-tool-hook"
  # Upstream writes its hook command as a quoted absolute path; another tool's
  # absolute hook is left alone.
  cat > "$MOCK_BIN/codebase-memory-mcp" <<'EOF'
#!/usr/bin/env python3
import json, os, sys
if sys.argv[1:2] != ["install"]:
    sys.exit(0)
home = os.environ["HOME"]
# upstream rewrites the hook script radin stashed
os.makedirs(os.path.join(home, ".claude", "hooks"), exist_ok=True)
open(os.path.join(home, ".claude", "hooks", "cbm-session-reminder"), "w").close()
json.dump({"hooks": {"SessionStart": [
    {"matcher": "startup", "hooks": [{"type": "command",
     "command": "'%s/.claude/hooks/cbm-session-reminder'" % home}]},
    {"matcher": "", "hooks": [{"type": "command",
     "command": "%s/other-tool-hook" % home}]}]}},
    open(os.path.join(home, ".claude", "settings.json"), "w"), indent=2)
json.dump({"mcpServers": {"codebase-memory-mcp": {
    "command": "%s/.local/bin/codebase-memory-mcp" % home}}},
    open(os.path.join(home, ".claude.json"), "w"), indent=2)
EOF
  chmod +x "$MOCK_BIN/codebase-memory-mcp"
  mkdir -p "$TEST_HOME/.local/bin"
  touch "$TEST_HOME/.local/bin/codebase-memory-mcp"
  run bash "$CLI" install
  [ "$status" -eq 0 ]
  [[ "$output" == *PORTABLE*"~/.claude/hooks/cbm-session-reminder"* ]]
  run python3 -c "
import json
h = json.load(open('$TEST_HOME/.claude/settings.json'))['hooks']
cmds = [k['command'] for e in h['SessionStart'] for k in e['hooks']]
assert cmds == ['~/.claude/hooks/cbm-session-reminder', '$TEST_HOME/other-tool-hook'], cmds
# posix_spawn does not expand ~, so the MCP command keeps its absolute path.
c = json.load(open('$TEST_HOME/.claude.json'))['mcpServers']['codebase-memory-mcp']['command']
assert c == '$TEST_HOME/.local/bin/codebase-memory-mcp', c
"
  [ "$status" -eq 0 ]
}

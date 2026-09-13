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

@test "syntax is valid" {
  run bash -n "$CLI"
  [ "$status" -eq 0 ]
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

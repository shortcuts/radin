#!/usr/bin/env bats
# Exercises lib/radin-cbm-config.sh: run codebase-memory-mcp's own Claude Code
# configuration, then put back every hook and MCP entry its write dropped
# (upstream #1200). A /bin/sh stub binary stands in for the real installer; it
# states upstream's post-write state as a literal and copies it over both
# files wholesale, which is what #1200 does. stub_cbm writes ~/.claude.json
# directly, the no-override case; stub_cbm_symlink_averse below is the one
# that honours CLAUDE_CONFIG_DIR, because that is what its test is about.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  CLI="$REPO_ROOT/lib/radin-cbm-config.sh"
  TEST_HOME="$(mktemp -d)"
  MOCK_BIN="$(mktemp -d)"
  export HOME="$TEST_HOME"
  export PATH="$MOCK_BIN:/usr/bin:/bin:/usr/sbin:/sbin"
  # $HOME moved, so the stub cannot find its own literals by ~; tell it where.
  export MOCK_AFTER="$MOCK_BIN"
  load helpers/pty
  cc_build "$REPO_ROOT/lib/radin-cbm-json.c" "$REPO_ROOT/lib/radin-cbm-json" ||
    skip "a C compiler is needed to build the JSON helper"
  mkdir -p "$TEST_HOME/.claude"
  # What #1200 leaves behind when nothing else is asked for: its own
  # SessionStart entry, and no trace of anyone else's.
  AFTER_SETTINGS='{"hooks": {"SessionStart": [{"matcher": "", "hooks": [{"type": "command", "command": "cbm-session-reminder"}]}]}}'
  AFTER_CLAUDE='{"mcpServers": {"codebase-memory-mcp": {"command": "codebase-memory-mcp"}}}'
}

teardown() {
  rm -rf "$TEST_HOME" "$MOCK_BIN"
}

# Every hook command in the file, in file order -- which is the order the
# writer preserves, so this asserts placement as well as presence.
hook_commands() {
  grep -o '"command": "[^"]*"' "$1" | sed 's/.*": "//; s/"$//'
}

# The two literals upstream's write leaves behind: $1 the settings.json, $2
# the ~/.claude.json. Either empty or absent takes the default above.
stub_after() {
  if [ $# -gt 0 ] && [ -n "$1" ]; then
    printf '%s\n' "$1" > "$MOCK_BIN/after-settings.json"
  else
    printf '%s\n' "$AFTER_SETTINGS" > "$MOCK_BIN/after-settings.json"
  fi
  if [ $# -gt 1 ] && [ -n "$2" ]; then
    printf '%s\n' "$2" > "$MOCK_BIN/after-claude.json"
  else
    printf '%s\n' "$AFTER_CLAUDE" > "$MOCK_BIN/after-claude.json"
  fi
}

stub_cbm() {
  stub_after "$@"
  cat > "$MOCK_BIN/codebase-memory-mcp" <<'EOF'
#!/bin/sh
[ "$1" = "install" ] || exit 0
cfg="$HOME/.claude"
cp "$MOCK_AFTER/after-settings.json" "$cfg/settings.json"
cp "$MOCK_AFTER/after-claude.json" "$HOME/.claude.json"
EOF
  chmod +x "$MOCK_BIN/codebase-memory-mcp"
}

# Upstream 0.11.0's PATH step exits 1 with no message under any $SHELL but
# zsh, after Claude Code is already configured. This stub reproduces that: it
# writes both files, then fails unless the run passed SHELL=/bin/sh.
stub_cbm_shell_picky() {
  stub_after "$@"
  cat > "$MOCK_BIN/codebase-memory-mcp" <<'EOF'
#!/bin/sh
[ "$1" = "install" ] || exit 0
cp "$MOCK_AFTER/after-settings.json" "$HOME/.claude/settings.json"
cp "$MOCK_AFTER/after-claude.json" "$HOME/.claude.json"
[ "$SHELL" = "/bin/sh" ] || exit 1
EOF
  chmod +x "$MOCK_BIN/codebase-memory-mcp"
}

@test "install passes SHELL=/bin/sh so upstream's PATH step does not fail" {
  stub_cbm_shell_picky
  printf '%s\n' '{"hooks": {"SessionStart": [{"matcher": "", "hooks": [{"type": "command", "command": "caveman-session"}]}]}}' \
    > "$TEST_HOME/.claude/settings.json"
  run env SHELL=/opt/homebrew/bin/fish bash "$CLI" install
  [ "$status" -eq 0 ]
  [[ "$output" != *PARTIAL* ]]
  [[ "$output" == *CONFIGURED* ]]
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
  # Upstream merges PreToolUse and replaces SessionStart wholesale.
  stub_cbm '{"hooks": {"SessionStart": [{"matcher": "", "hooks": [{"type": "command", "command": "cbm-session-reminder"}]}], "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "mine"}]}, {"matcher": "Grep|Glob", "hooks": [{"type": "command", "command": "cbm-hook-augment"}]}]}}'
  cat > "$TEST_HOME/.claude/settings.json" <<'EOF'
{"model": "opus",
 "hooks": {"SessionStart": [{"matcher": "", "hooks": [{"type": "command", "command": "caveman-session"}]},
                            {"matcher": "compact", "hooks": [{"type": "command", "command": "ponytail-session"}]}],
           "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "mine"}]}]}}
EOF
  run bash "$CLI" install
  [ "$status" -eq 0 ]
  [[ "$output" == *RESTORED*SessionStart* ]]
  [ "$(hook_commands "$TEST_HOME/.claude/settings.json")" = "$(printf '%s\n' caveman-session ponytail-session cbm-session-reminder mine cbm-hook-augment)" ]
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
  [ "$(hook_commands "$TEST_HOME/.claude/settings.json")" = "$(printf '%s\n' caveman-session cbm-session-reminder)" ]
}

@test "install prunes hook entries whose command path does not exist" {
  touch "$TEST_HOME/live-hook" && chmod +x "$TEST_HOME/live-hook"
  stub_cbm "$(cat <<EOF
{"hooks": {"PreToolUse": [{"matcher": "Grep|Glob", "hooks": [{"type": "command", "command": "'/gone/.config/.claude/hooks/cbm-code-discovery-gate'"}]},
                          {"matcher": "Bash", "hooks": [{"type": "command", "command": "/gone/other-tool-hook"}]},
                          {"matcher": "Bash", "hooks": [{"type": "command", "command": "$TEST_HOME/live-hook"}]},
                          {"matcher": "Write", "hooks": [{"type": "command", "command": "bare-shim-not-on-path"}]},
                          {"matcher": "Grep|Glob", "hooks": [{"type": "command", "command": "cbm-hook-augment"}]}],
           "SessionStart": [{"matcher": "", "hooks": [{"type": "command", "command": "cbm-session-reminder"}]}]}}
EOF
  )"
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
  [ "$(hook_commands "$TEST_HOME/.claude/settings.json")" = "$(printf '%s\n' "$TEST_HOME/live-hook" bare-shim-not-on-path cbm-hook-augment cbm-session-reminder)" ]
}

@test "install prunes a dead hook wrapped in sh, not just a bare dead path" {
  stub_cbm "$(cat <<EOF
{"hooks": {"SessionStart": [{"matcher": "startup", "hooks": [{"type": "command", "command": "sh /Users/someone-else/.claude/hooks/cbm-session-reminder"}]},
                            {"matcher": "startup", "hooks": [{"type": "command", "command": "cbm-session-reminder"}]}]}}
EOF
  )"
  echo '{}' > "$TEST_HOME/.claude/settings.json"
  run bash "$CLI" install
  [ "$status" -eq 0 ]
  [[ "$output" == *PRUNED*someone-else* ]]
  [ "$(hook_commands "$TEST_HOME/.claude/settings.json")" = "cbm-session-reminder" ]
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
  # The stub replaces ~/.claude.json wholesale the way #1200 does, so "other"
  # is gone by the time radin looks.
  stub_cbm
  echo '{"mcpServers": {"other": {"command": "x"}}}' > "$TEST_HOME/.claude.json"
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
  printf '%s\n' "$AFTER_SETTINGS" > "$TEST_HOME/.claude/settings.json"
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
  grep -q '"model": "opus"' "$TEST_HOME/.claude/.radin/backups/"settings.json.*.bak
}

# Reproduces upstream #1722: writes under a symlinked ~/.claude are refused,
# and Claude Code silently drops out of the target list. Honours
# CLAUDE_CONFIG_DIR the way the real binary does, including writing the MCP
# entry beside that directory instead of at ~/.claude.json.
stub_cbm_symlink_averse() {
  stub_after "$@"
  cat > "$MOCK_BIN/codebase-memory-mcp" <<'EOF'
#!/bin/sh
[ "$1" = "install" ] || exit 0
cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
if [ -L "$cfg" ]; then
	# "(target: does not exist or cannot be inspected)" -- and exit 0 anyway.
	printf 'Detected agents: Shell\n'
	exit 0
fi
cp "$MOCK_AFTER/after-settings.json" "$cfg/settings.json"
if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
	cp "$MOCK_AFTER/after-claude.json" "$cfg/.claude.json"
else
	cp "$MOCK_AFTER/after-claude.json" "$HOME/.claude.json"
fi
EOF
  chmod +x "$MOCK_BIN/codebase-memory-mcp"
}

@test "install passes the resolved path when ~/.claude is a symlink, and adopts the staged MCP entry" {
  stub_cbm_symlink_averse '{"hooks": {"SessionStart": [{"matcher": "", "hooks": [{"type": "command", "command": "caveman-session"}]}], "PreToolUse": [{"matcher": "Grep|Glob", "hooks": [{"type": "command", "command": "cbm-hook-augment"}]}]}}'
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
  grep -q '"fff"' "$TEST_HOME/.claude.json"
  grep -q '"codebase-memory-mcp"' "$TEST_HOME/.claude.json"
  [ "$(hook_commands "$TEST_HOME/.config/.claude/settings.json")" = "$(printf '%s\n' caveman-session cbm-hook-augment)" ]
}

@test "install succeeds when upstream fails after configuring Claude Code" {
  stub_cbm '{"hooks": {"SessionStart": [{"matcher": "", "hooks": [{"type": "command", "command": "caveman-session"}]}, {"matcher": "", "hooks": [{"type": "command", "command": "cbm-session-reminder"}]}]}}'
  # The real binary's version-activation step fails here, after the config pass.
  cat >> "$MOCK_BIN/codebase-memory-mcp" <<'EOF'
printf 'error: activation could not reserve exclusive access\n' >&2
exit 1
EOF
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
#!/bin/sh
exit 0
EOF
  chmod +x "$MOCK_BIN/codebase-memory-mcp"
  printf '%s\n' '{"hooks": {}}' > "$TEST_HOME/.claude/settings.json"

  run bash "$CLI" install
  [ "$status" -ne 0 ]
  [[ "$output" == *"hooks: absent"* ]]
  [[ "$output" == *"radin hooks all"* ]]
}

@test "install rewrites ~/ hook paths to absolute, leaving another tool's alone" {
  mkdir -p "$TEST_HOME/.claude/hooks" "$TEST_HOME/.local/bin"
  touch "$TEST_HOME/.claude/hooks/cbm-session-reminder" "$TEST_HOME/other-tool-hook"
  touch "$TEST_HOME/.local/bin/codebase-memory-mcp"
  # Upstream writes its hook command as a quoted absolute path; another tool's
  # absolute hook is left alone.
  stub_cbm "$(cat <<EOF
{"hooks": {"SessionStart": [{"matcher": "startup", "hooks": [{"type": "command", "command": "'$TEST_HOME/.claude/hooks/cbm-session-reminder'"}]},
                            {"matcher": "", "hooks": [{"type": "command", "command": "$TEST_HOME/other-tool-hook"}]},
                            {"matcher": "startup", "hooks": [{"type": "command", "command": "~/.local/bin/codebase-memory-mcp"}]}]}}
EOF
  )" "$(cat <<EOF
{"mcpServers": {"codebase-memory-mcp": {"command": "$TEST_HOME/.local/bin/codebase-memory-mcp"}}}
EOF
  )"
  # Upstream rewrites the hook script radin stashed.
  cat >> "$MOCK_BIN/codebase-memory-mcp" <<'EOF'
mkdir -p "$cfg/hooks"
: > "$cfg/hooks/cbm-session-reminder"
EOF
  run bash "$CLI" install
  [ "$status" -eq 0 ]
  [[ "$output" == *ABSOLUTE*"$TEST_HOME/.claude/hooks/cbm-session-reminder"* ]]
  # posix_spawn does not expand ~ in a hook command either, which is why the
  # rewrite goes this way; the MCP command was always absolute.
  [ "$(hook_commands "$TEST_HOME/.claude/settings.json")" = "$(printf '%s\n' "$TEST_HOME/.claude/hooks/cbm-session-reminder" "$TEST_HOME/other-tool-hook" "$TEST_HOME/.local/bin/codebase-memory-mcp")" ]
  grep -q "\"command\": \"$TEST_HOME/.local/bin/codebase-memory-mcp\"" "$TEST_HOME/.claude.json"
}

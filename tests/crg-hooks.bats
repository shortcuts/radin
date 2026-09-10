#!/usr/bin/env bats
# Exercises lib/radin-crg-hooks.sh: merge-only wiring of code-review-graph
# into ~/.claude/CLAUDE.md, ~/.claude/settings.json and a repo's .mcp.json.
# A stub code-review-graph on PATH satisfies the binary check.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  CLI="$REPO_ROOT/lib/radin-crg-hooks.sh"
  TEST_HOME="$(mktemp -d)"
  MOCK_BIN="$(mktemp -d)"
  export HOME="$TEST_HOME"
  printf '#!/bin/sh\n' > "$MOCK_BIN/code-review-graph"
  chmod +x "$MOCK_BIN/code-review-graph"
  export PATH="$MOCK_BIN:/usr/bin:/bin:/usr/sbin:/sbin"
  command -v python3 >/dev/null 2>&1 || skip "python3 required"
  git init -q "$TEST_HOME/proj"
}

teardown() {
  rm -rf "$TEST_HOME" "$MOCK_BIN"
}

@test "syntax is valid" {
  run bash -n "$CLI"
  [ "$status" -eq 0 ]
}

@test "fails without code-review-graph on PATH" {
  rm -f "$MOCK_BIN/code-review-graph"
  run bash "$CLI" all "$TEST_HOME/proj"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not installed"* ]]
}

@test "claude-md appends the section once, preserving existing content" {
  mkdir -p "$TEST_HOME/.claude"
  echo "user content stays" > "$TEST_HOME/.claude/CLAUDE.md"
  run bash "$CLI" claude-md
  [ "$status" -eq 0 ]
  [[ "$output" == *ADDED* ]]
  run bash "$CLI" claude-md
  [[ "$output" == *PRESENT* ]]
  grep -q "user content stays" "$TEST_HOME/.claude/CLAUDE.md"
  [ "$(grep -c '## MCP Tools: code-review-graph' "$TEST_HOME/.claude/CLAUDE.md")" -eq 1 ]
}

@test "claude-md skips a user-authored section without radin's marker" {
  mkdir -p "$TEST_HOME/.claude"
  echo "## MCP Tools: code-review-graph" > "$TEST_HOME/.claude/CLAUDE.md"
  run bash "$CLI" claude-md
  [ "$status" -eq 0 ]
  [[ "$output" == *PRESENT* ]]
  [ "$(wc -l < "$TEST_HOME/.claude/CLAUDE.md")" -eq 1 ]
}

@test "settings adds both hooks and keeps unrelated settings" {
  mkdir -p "$TEST_HOME/.claude"
  echo '{"model": "opus", "hooks": {"Stop": [{"matcher": "", "hooks": []}]}}' > "$TEST_HOME/.claude/settings.json"
  run bash "$CLI" settings
  [ "$status" -eq 0 ]
  grep -q '"model": "opus"' "$TEST_HOME/.claude/settings.json"
  grep -q '"Stop"' "$TEST_HOME/.claude/settings.json"
  grep -q 'code-review-graph update --skip-flows' "$TEST_HOME/.claude/settings.json"
  grep -q 'code-review-graph status' "$TEST_HOME/.claude/settings.json"
}

@test "settings never redefines a hook the user already carries, in any shape" {
  mkdir -p "$TEST_HOME/.claude"
  cat > "$TEST_HOME/.claude/settings.json" <<'EOF'
{"hooks": {"SessionStart": [{"matcher": "", "hooks": [{"type": "command", "command": "custom-wrapper && code-review-graph status --repo /x"}]}]}}
EOF
  run bash "$CLI" settings
  [ "$status" -eq 0 ]
  grep -q "custom-wrapper" "$TEST_HOME/.claude/settings.json"
  [ "$(grep -c 'code-review-graph status' "$TEST_HOME/.claude/settings.json")" -eq 1 ]
  grep -q 'code-review-graph update --skip-flows' "$TEST_HOME/.claude/settings.json"
}

@test "settings refuses to touch invalid JSON" {
  mkdir -p "$TEST_HOME/.claude"
  echo 'not json' > "$TEST_HOME/.claude/settings.json"
  run bash "$CLI" settings
  [ "$status" -ne 0 ]
  [ "$(cat "$TEST_HOME/.claude/settings.json")" = "not json" ]
}

@test "mcp adds the server entry once and keeps other servers" {
  echo '{"mcpServers": {"other": {"command": "x"}}}' > "$TEST_HOME/proj/.mcp.json"
  run bash "$CLI" mcp "$TEST_HOME/proj"
  [ "$status" -eq 0 ]
  [[ "$output" == *ADDED* ]]
  grep -q '"other"' "$TEST_HOME/proj/.mcp.json"
  grep -q '"code-review-graph"' "$TEST_HOME/proj/.mcp.json"
  run bash "$CLI" mcp "$TEST_HOME/proj"
  [[ "$output" == *PRESENT* ]]
}

@test "all runs the three writes against a fresh home and repo" {
  run bash "$CLI" all "$TEST_HOME/proj"
  [ "$status" -eq 0 ]
  grep -q '## MCP Tools: code-review-graph' "$TEST_HOME/.claude/CLAUDE.md"
  grep -q 'code-review-graph update --skip-flows' "$TEST_HOME/.claude/settings.json"
  grep -q '"code-review-graph"' "$TEST_HOME/proj/.mcp.json"
}

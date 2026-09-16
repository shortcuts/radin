#!/usr/bin/env bats
# Exercises lib/radin-cbm-hooks.sh: merge-only wiring of codebase-memory-mcp
# into ~/.claude/CLAUDE.md and a repo's .mcp.json. A stub codebase-memory-mcp
# on PATH satisfies the binary check.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  CLI="$REPO_ROOT/lib/radin-cbm-hooks.sh"
  TEST_HOME="$(mktemp -d)"
  MOCK_BIN="$(mktemp -d)"
  export HOME="$TEST_HOME"
  printf '#!/bin/sh\n' > "$MOCK_BIN/codebase-memory-mcp"
  chmod +x "$MOCK_BIN/codebase-memory-mcp"
  export PATH="$MOCK_BIN:/usr/bin:/bin:/usr/sbin:/sbin"
  load helpers/pty
  cc_build "$REPO_ROOT/lib/radin-cbm-json.c" "$REPO_ROOT/lib/radin-cbm-json" ||
    skip "a C compiler is needed to build the JSON helper"
  git init -q "$TEST_HOME/proj"
}

teardown() {
  rm -rf "$TEST_HOME" "$MOCK_BIN"
}

@test "fails without codebase-memory-mcp on PATH or in ~/.local/bin" {
  rm -f "$MOCK_BIN/codebase-memory-mcp"
  run bash "$CLI" all "$TEST_HOME/proj"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]]
}

@test "falls back to ~/.local/bin when the binary is off PATH" {
  rm -f "$MOCK_BIN/codebase-memory-mcp"
  mkdir -p "$TEST_HOME/.local/bin"
  printf '#!/bin/sh\n' > "$TEST_HOME/.local/bin/codebase-memory-mcp"
  chmod +x "$TEST_HOME/.local/bin/codebase-memory-mcp"
  run bash "$CLI" mcp "$TEST_HOME/proj"
  [ "$status" -eq 0 ]
  grep -q "$TEST_HOME/.local/bin/codebase-memory-mcp" "$TEST_HOME/proj/.mcp.json"
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
  [ "$(grep -c '## MCP Tools: codebase-memory-mcp' "$TEST_HOME/.claude/CLAUDE.md")" -eq 1 ]
}

@test "claude-md skips a user-authored section without radin's marker" {
  mkdir -p "$TEST_HOME/.claude"
  echo "## MCP Tools: codebase-memory-mcp" > "$TEST_HOME/.claude/CLAUDE.md"
  run bash "$CLI" claude-md
  [ "$status" -eq 0 ]
  [[ "$output" == *PRESENT* ]]
  [ "$(wc -l < "$TEST_HOME/.claude/CLAUDE.md")" -eq 1 ]
}

@test "no settings subcommand: the watcher keeps the graph current" {
  run bash "$CLI" settings
  [ "$status" -ne 0 ]
  [[ "$output" == *usage* ]]
  [ ! -e "$TEST_HOME/.claude/settings.json" ]
}

@test "mcp adds the server entry once and keeps other servers" {
  echo '{"mcpServers": {"other": {"command": "x"}}}' > "$TEST_HOME/proj/.mcp.json"
  run bash "$CLI" mcp "$TEST_HOME/proj"
  [ "$status" -eq 0 ]
  [[ "$output" == *ADDED* ]]
  grep -q '"other"' "$TEST_HOME/proj/.mcp.json"
  grep -q '"codebase-memory-mcp"' "$TEST_HOME/proj/.mcp.json"
  run bash "$CLI" mcp "$TEST_HOME/proj"
  [[ "$output" == *PRESENT* ]]
}

@test "mcp never redefines a user's own entry, in any shape" {
  echo '{"mcpServers": {"codebase-memory-mcp": {"command": "custom-wrapper"}}}' > "$TEST_HOME/proj/.mcp.json"
  run bash "$CLI" mcp "$TEST_HOME/proj"
  [ "$status" -eq 0 ]
  [[ "$output" == *PRESENT* ]]
  grep -q "custom-wrapper" "$TEST_HOME/proj/.mcp.json"
}

@test "mcp refuses to touch invalid JSON" {
  echo 'not json' > "$TEST_HOME/proj/.mcp.json"
  run bash "$CLI" mcp "$TEST_HOME/proj"
  [ "$status" -ne 0 ]
  [[ "$output" == *"$TEST_HOME/proj/.mcp.json"* ]]
  [ "$(cat "$TEST_HOME/proj/.mcp.json")" = "not json" ]
}

@test "mcp creates .mcp.json when the repo has none, and rerunning is a no-op" {
  run bash "$CLI" mcp "$TEST_HOME/proj"
  [ "$status" -eq 0 ]
  [[ "$output" == *ADDED* ]]
  cp "$TEST_HOME/proj/.mcp.json" "$TEST_HOME/first"
  run bash "$CLI" mcp "$TEST_HOME/proj"
  [ "$status" -eq 0 ]
  [[ "$output" == *PRESENT* ]]
  cmp "$TEST_HOME/first" "$TEST_HOME/proj/.mcp.json"
}

@test "mcp keeps an existing file's other keys and their order" {
  printf '{\n  "zebra": 1,\n  "alpha": {"deep": [1, 2]}\n}\n' > "$TEST_HOME/proj/.mcp.json"
  run bash "$CLI" mcp "$TEST_HOME/proj"
  [ "$status" -eq 0 ]
  run grep -n '"zebra"\|"alpha"\|"mcpServers"' "$TEST_HOME/proj/.mcp.json"
  [[ "${lines[0]}" == *zebra* ]]
  [[ "${lines[1]}" == *alpha* ]]
  [[ "${lines[2]}" == *mcpServers* ]]
}

@test "all runs both writes against a fresh home and repo" {
  run bash "$CLI" all "$TEST_HOME/proj"
  [ "$status" -eq 0 ]
  grep -q '## MCP Tools: codebase-memory-mcp' "$TEST_HOME/.claude/CLAUDE.md"
  grep -q '"codebase-memory-mcp"' "$TEST_HOME/proj/.mcp.json"
  [ ! -e "$TEST_HOME/.claude/settings.json" ]
}

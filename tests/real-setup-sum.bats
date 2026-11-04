#!/usr/bin/env bats
# make test fails when this script's output changes, so each watched path must
# flip from absent to a checksum and track later edits.

bats_require_minimum_version 1.5.0

setup() {
  SUM="$BATS_TEST_DIRNAME/../scripts/real-setup-sum.sh"
  load helpers/isolate
  isolate_env "$BATS_TEST_TMPDIR/h"
  mkdir -p "$CODEX_HOME" "$XDG_CONFIG_HOME/opencode" "$HOME/.radin"
}

@test "every Codex, opencode and radin path shows as absent on a clean home" {
  run "$SUM"
  [ "$status" -eq 0 ]
  [[ "$output" == *"$CODEX_HOME/AGENTS.md absent"* ]]
  [[ "$output" == *"$CODEX_HOME/hooks.json absent"* ]]
  [[ "$output" == *"$CODEX_HOME/config.toml absent"* ]]
  [[ "$output" == *"$XDG_CONFIG_HOME/opencode/AGENTS.md absent"* ]]
  [[ "$output" == *"$XDG_CONFIG_HOME/opencode/opencode.json absent"* ]]
  [[ "$output" == *"$HOME/.radin/manifest.json absent"* ]]
}

@test "an edit to a watched file changes its line each time" {
  OPENCODE_CONFIG="$BATS_TEST_TMPDIR/custom.json"
  export OPENCODE_CONFIG
  run "$SUM"
  [[ "$output" == *"$OPENCODE_CONFIG absent"* ]]
  printf 'one\n' >"$CODEX_HOME/AGENTS.md"
  printf '{}\n' >"$XDG_CONFIG_HOME/opencode/opencode.json"
  printf '{}\n' >"$OPENCODE_CONFIG"
  run "$SUM"
  first="$output"
  [[ "$first" != *"$CODEX_HOME/AGENTS.md absent"* ]]
  [[ "$first" != *"opencode.json absent"* ]]
  [[ "$first" != *"$OPENCODE_CONFIG absent"* ]]
  printf 'two\n' >"$CODEX_HOME/AGENTS.md"
  run "$SUM"
  [ "$output" != "$first" ]
}

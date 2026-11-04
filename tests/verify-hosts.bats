#!/usr/bin/env bats
# scripts/verify-hosts.sh --no-install against a fake installed tree and stub
# opencode and codex CLIs. The real CLIs need the network, so only this seam
# runs offline.

bats_require_minimum_version 1.5.0

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  WORK="$(cd "$(mktemp -d)" && pwd -P)"
  load helpers/isolate
  isolate_env "$WORK/home"
  BIN="$WORK/bin"
  SKILLS="$(awk '$1=="skill" {print $2}' "$ROOT/SHIPPED")"
  KINDS="planning execution review debug factfind gate merge"
  mkdir -p "$BIN" "$HOME/.radin/bin" "$HOME/.radin/hosts/agents" "$XDG_CONFIG_HOME/opencode/agents" "$CODEX_HOME"
  for s in $SKILLS; do
    mkdir -p "$HOME/.agents/skills/$s"
    printf -- '---\nname: %s\n---\nbody\n' "$s" >"$HOME/.agents/skills/$s/SKILL.md"
  done
  for k in $KINDS; do printf -- '---\nmode: subagent\n---\n' >"$XDG_CONFIG_HOME/opencode/agents/radin-$k.md"; done
  printf '<!-- radin:begin -->\nx\n<!-- radin:end -->\n' >"$XDG_CONFIG_HOME/opencode/AGENTS.md"
  cp "$XDG_CONFIG_HOME/opencode/AGENTS.md" "$CODEX_HOME/AGENTS.md"
  printf '#!/bin/sh\nprintf "  OK       Codex lists radin skills\\n"\n' >"$HOME/.radin/bin/radin"
  chmod +x "$HOME/.radin/bin/radin"
  stub_opencode "$KINDS" "$HOME/.radin/**"
  stub_codex "$SKILLS radin:begin"
  export PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin"
}

teardown() {
  rm -rf "$WORK"
}

stub_opencode() { # agent kinds, config text
  {
    echo '#!/bin/sh'
    echo 'case "$2" in agents) for k in '"$1"'; do printf "  \"id\": \"radin-%s\"\n" "$k"; done ;; config) echo "'"$2"'" ;; esac'
  } >"$BIN/opencode"
  chmod +x "$BIN/opencode"
}

stub_codex() { # prompt-input text
  printf '#!/bin/sh\necho "%s"\n' "$1" >"$BIN/codex"
  chmod +x "$BIN/codex"
}

@test "a complete tree passes both hosts" {
  run "$ROOT/scripts/verify-hosts.sh" --no-install
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK opencode"* ]]
  [[ "$output" == *"OK codex"* ]]
}

@test "a missing opencode agent fails and names it" {
  stub_opencode "planning execution review debug factfind merge" "$HOME/.radin/**"
  run "$ROOT/scripts/verify-hosts.sh" --no-install --only opencode
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL opencode: agent radin-gate missing"* ]]
}

@test "a missing external_directory rule fails opencode" {
  stub_opencode "$KINDS" "nothing"
  run "$ROOT/scripts/verify-hosts.sh" --no-install --only opencode
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL opencode: external_directory rule missing"* ]]
}

@test "a skill missing from the codex listing fails and names it" {
  stub_codex "radin-do radin-plan radin-record radin-review radin-stats radin-teardown radin-uninstall radin:begin"
  run "$ROOT/scripts/verify-hosts.sh" --no-install --only codex
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL codex: skill radin-batch not listed"* ]]
}

@test "an unresolved token in an installed skill fails" {
  printf 'RADIN_CLI\n' >>"$HOME/.agents/skills/radin-do/SKILL.md"
  run "$ROOT/scripts/verify-hosts.sh" --no-install --only opencode
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL opencode: unresolved token"* ]]
  [[ "$output" == *"radin-do/SKILL.md"* ]]
}

@test "no CLI on PATH skips both hosts and fails the run" {
  rm "$BIN/opencode" "$BIN/codex"
  run "$ROOT/scripts/verify-hosts.sh" --no-install
  [ "$status" -eq 1 ]
  [[ "$output" == *"SKIP opencode: opencode not on PATH"* ]]
  [[ "$output" == *"SKIP codex: codex not on PATH"* ]]
}

@test "an unknown argument exits 2" {
  run "$ROOT/scripts/verify-hosts.sh" --bogus
  [ "$status" -eq 2 ]
}

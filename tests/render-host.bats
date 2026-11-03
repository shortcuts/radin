#!/usr/bin/env bats
# Exercises scripts/render-host.sh and the forbid lint of scripts/check-prose.sh.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  RENDER="$REPO_ROOT/scripts/render-host.sh"
  T="$(mktemp -d)"
}

teardown() {
  rm -rf "$T"
}

src() { printf '%s\n' "$@" > "$T/in.md"; }

@test "keeps outside text and matching blocks, drops others and every marker" {
  src one '<!-- host:claude -->' c-only '<!-- /host -->' '<!-- host:agents -->' a-only '<!-- /host -->' '<!-- host:claude,agents -->' both '<!-- /host -->' two
  run "$RENDER" "$T/in.md" claude
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'one\nc-only\nboth\ntwo')" ]
  run "$RENDER" "$T/in.md" agents
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'one\na-only\nboth\ntwo')" ]
}

@test "fails with FILE:LINE on an unclosed block" {
  src one '<!-- host:claude -->' body
  run "$RENDER" "$T/in.md" claude
  [ "$status" -eq 1 ]
  [ "$output" = "$T/in.md:2: host block never closed" ]
}

@test "fails with FILE:LINE on a stray close" {
  src one '<!-- /host -->'
  run "$RENDER" "$T/in.md" claude
  [ "$status" -eq 1 ]
  [ "$output" = "$T/in.md:2: <!-- /host --> with no open block" ]
}

@test "fails with FILE:LINE on a nested block" {
  src '<!-- host:claude -->' '<!-- host:agents -->'
  run "$RENDER" "$T/in.md" claude
  [ "$status" -eq 1 ]
  [ "$output" = "$T/in.md:2: nested host block, opened at line 1" ]
}

@test "fails with FILE:LINE on an unknown host name" {
  src one '<!-- host:claude,mars -->'
  run "$RENDER" "$T/in.md" claude
  [ "$status" -eq 1 ]
  [ "$output" = "$T/in.md:2: unknown host \"mars\"" ]
}

@test "fails with FILE:LINE on a marker that shares its line" {
  src one 'text <!-- host:claude -->'
  run "$RENDER" "$T/in.md" claude
  [ "$status" -eq 1 ]
  [ "$output" = "$T/in.md:2: host marker must sit alone on its line" ]
}

@test "fails on an unknown HOST" {
  src one
  run "$RENDER" "$T/in.md" mars
  [ "$status" -eq 1 ]
}

@test "a forbidden string outside a block fails the agents render" {
  src one 'call SendMessage now'
  run "$RENDER" "$T/in.md" agents
  [ "$status" -eq 1 ]
  [ "$output" = "$T/in.md: forbidden string \"SendMessage\" survives in the agents render" ]
}

@test "the same string inside a claude block passes the agents render" {
  src one '<!-- host:claude -->' 'call SendMessage now' '<!-- /host -->'
  run "$RENDER" "$T/in.md" agents
  [ "$status" -eq 0 ]
  [ "$output" = one ]
}

@test "--hits prints the surviving string and exits 0" {
  src 'call SendMessage now'
  run "$RENDER" --hits "$T/in.md" agents
  [ "$status" -eq 0 ]
  [ "$output" = SendMessage ]
}

lint_root() {
  mkdir -p "$T/r/hosts" "$T/r/skills/x" "$T/r/lib" "$T/r/tests"
  cp "$REPO_ROOT"/hosts/forbid-claude.txt "$REPO_ROOT"/hosts/forbid-agents.txt "$T/r/hosts/"
  : > "$T/r/tests/x.bats"
  : > "$T/r/lib/radin-run.md"
  : > "$T/r/lib/radin-leaf-contract.md"
}

@test "lint fails on a new forbidden string, passes once baselined, fails on a stale pair" {
  lint_root
  printf 'use SendMessage\n' > "$T/r/skills/x/SKILL.md"
  run "$REPO_ROOT/scripts/check-prose.sh" "$T/r"
  [ "$status" -eq 1 ]
  [[ "$output" == *'skills/x/SKILL.md: forbidden string "SendMessage" outside a host block'* ]]
  printf 'skills/x/SKILL.md\tSendMessage\n' > "$T/r/hosts/forbid-baseline.txt"
  run "$REPO_ROOT/scripts/check-prose.sh" "$T/r"
  [ "$status" -eq 0 ]
  printf 'clean\n' > "$T/r/skills/x/SKILL.md"
  run "$REPO_ROOT/scripts/check-prose.sh" "$T/r"
  [ "$status" -eq 1 ]
  [[ "$output" == *'no longer holds "SendMessage"; delete the line'* ]]
}

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

@test "the agents render of radin-run.md names no Claude dispatch tool" {
  run "$RENDER" --hits "$REPO_ROOT/lib/radin-run.md" agents
  [ "$status" -eq 0 ]
  [[ "$output" != *ListAgents* ]]
  [[ "$output" != *CronCreate* ]]
  [[ "$output" != *SendMessage* ]]
  [[ "$output" != *run_in_background* ]]
}

@test "lint fails on a malformed host marker in a lib file" {
  lint_root
  printf 'clean\n' > "$T/r/skills/x/SKILL.md"
  printf '<!-- host:claude -->\nbody\n' > "$T/r/lib/radin-batch-gate.md"
  run "$REPO_ROOT/scripts/check-prose.sh" "$T/r"
  [ "$status" -eq 1 ]
  [[ "$output" == *'lib/radin-batch-gate.md:1: host block never closed'* ]]
}

ask_hosts() {
  mkdir -p "$T/h"
  cp "$REPO_ROOT/hosts/forbid-claude.txt" "$T/h/"
  printf 'AskUserQuestion\n' > "$T/h/forbid-agents.txt"
}

@test "the agents render of each ask site has no AskUserQuestion" {
  ask_hosts
  for f in lib/radin-run.md lib/radin-batch-session.md lib/radin-batch-merge.md lib/radin-batch-clarify.md skills/radin-review/SKILL.md skills/radin-record/SKILL.md skills/radin-do/SKILL.md; do
    run env RADIN_HOSTS_DIR="$T/h" "$RENDER" "$REPO_ROOT/$f" agents
    [ "$status" -eq 0 ]
  done
}

@test "the agents render of each file that asks names the ask rule" {
  ask_hosts
  for f in lib/radin-run.md lib/radin-batch-merge.md skills/radin-review/SKILL.md skills/radin-record/SKILL.md skills/radin-do/SKILL.md; do
    run env RADIN_HOSTS_DIR="$T/h" "$RENDER" "$REPO_ROOT/$f" agents
    [ "$status" -eq 0 ]
    [[ "$output" == *radin-ask-rule.md* ]]
  done
}

@test "the agents render of the leaf contract names no question tool" {
  run "$RENDER" "$REPO_ROOT/lib/radin-leaf-contract.md" agents
  [ "$status" -eq 0 ]
  [[ "$output" != *AskUserQuestion* ]]
  [[ "$output" == *"no question tool"* ]]
}

@test "the agents render of the leaf contract and explore rule names no claude-only tool" {
  for f in lib/radin-leaf-contract.md lib/radin-explore-rule.md; do
    run "$RENDER" "$REPO_ROOT/$f" agents
    [ "$status" -eq 0 ]
    [[ "$output" != *Monitor* ]]
    [[ "$output" != *Workflow* ]]
    [[ "$output" != *TaskStop* ]]
    [[ "$output" != *ToolSearch* ]]
    [[ "$output" != *"4 minutes"* ]]
  done
  run "$RENDER" "$REPO_ROOT/lib/radin-leaf-contract.md" claude
  [[ "$output" == *Monitor* ]]
  [[ "$output" == *Workflow* ]]
}

@test "the assembled factfind prompt carries the leaf rules of each host" {
  for host in claude agents; do
    H="$T/$host"
    mkdir -p "$H"
    cp -R "$REPO_ROOT/lib" "$H/lib"
    for f in "$H"/lib/*.md; do
      run env RADIN_LIB_DIR="$H/lib" RADIN_HOSTS_DIR="$REPO_ROOT/hosts" "$RENDER" "$f" "$host"
      [ "$status" -eq 0 ]
      printf '%s\n' "$output" > "$f"
    done
    git init -q "$H/proj"
    git -C "$H/proj" config user.email t@t
    git -C "$H/proj" config user.name t
    git -C "$H/proj" commit -q --allow-empty -m init
    (cd "$H/proj" && RADIN_HOST=$host bash "$H/lib/radin-backlog.sh" add fix "t one" <<<"body")
    run bash -c "cd '$H/proj' && RADIN_HOST=$host bash '$H/lib/radin-prompt.sh' factfind t-one q"
    [ "$status" -eq 0 ]
    prompt=$(printf '%s\n' "$output" | awk -F'\t' '$1 == "prompt" { print $2 }')
    text=$(cat "$prompt")
    if [ "$host" = agents ]; then
      [[ "$text" != *"<!-- host"* ]]
      [[ "$text" != *Monitor* ]]
      [[ "$text" != *Workflow* ]]
      [[ "$text" != *ToolSearch* ]]
    else
      [[ "$text" == *ToolSearch* ]]
      [[ "$text" == *Monitor* ]]
    fi
  done
}

@test "lint passes a sentence shared by the claude and agents twins of one line" {
  lint_root
  printf 'clean\n' > "$T/r/skills/x/SKILL.md"
  printf '%s\n' '<!-- host:claude -->' 'Read the shared plan file before you start the task.' '<!-- /host -->' '<!-- host:agents -->' 'Read the shared plan file before you start the task.' '<!-- /host -->' > "$T/r/lib/radin-twin.md"
  run "$REPO_ROOT/scripts/check-prose.sh" "$T/r"
  [ "$status" -eq 0 ]
}

@test "lint fails on a sentence repeated outside any host block" {
  lint_root
  printf 'clean\n' > "$T/r/skills/x/SKILL.md"
  printf '%s\n' 'Read the shared plan file before you start the task.' '' 'Read the shared plan file before you start the task.' > "$T/r/lib/radin-twin.md"
  run "$REPO_ROOT/scripts/check-prose.sh" "$T/r"
  [ "$status" -eq 1 ]
  [[ "$output" == *'lib/radin-twin.md:3: repeats lib/radin-twin.md:1; state it once there and point to it'* ]]
}

@test "a skill token renders each host's value" {
  src 'Invoke `@@skill:grilling@@` now, then @@skill:ponytail-review@@.'
  run "$RENDER" "$T/in.md" claude
  [ "$status" -eq 0 ]
  [ "$output" = 'Invoke `/mattpocock-skills:grilling` now, then /ponytail:ponytail-review.' ]
  run "$RENDER" "$T/in.md" agents
  [ "$status" -eq 0 ]
  [ "$output" = 'Invoke `grilling` now, then ponytail-review.' ]
}

@test "an unknown skill name fails with FILE:LINE" {
  src ok 'x @@skill:nope@@'
  run "$RENDER" "$T/in.md" agents
  [ "$status" -eq 1 ]
  [[ "$output" == *"in.md:2: unknown skill name \"nope\""* ]]
}

@test "a malformed skill token fails with FILE:LINE" {
  src '@@skill:Bad Name@@'
  run "$RENDER" "$T/in.md" claude
  [ "$status" -eq 1 ]
  [[ "$output" == *"in.md:1: malformed skill token"* ]]
}

@test "a missing skill-names table fails" {
  src one
  mkdir -p "$T/empty"
  RADIN_LIB_DIR="$T/empty" run "$RENDER" "$T/in.md" claude
  [ "$status" -eq 1 ]
  [[ "$output" == *"in.md: no skill-names-claude.txt"* ]]
}

@test "a token in a dropped host block is ignored" {
  src '<!-- host:claude -->' '@@skill:nope@@' '<!-- /host -->' '@@skill:research@@'
  run "$RENDER" "$T/in.md" agents
  [ "$status" -eq 0 ]
  [ "$output" = research ]
}

@test "lint fails on a skill name outside the table and on a token missing from it" {
  lint_root
  printf 'clean\n' > "$T/r/skills/x/SKILL.md"
  cp "$REPO_ROOT"/lib/skill-names-*.txt "$T/r/lib/"
  printf '# /ponytail:ponytail\n' > "$T/r/lib/radin-scope.sh"
  run "$REPO_ROOT/scripts/check-prose.sh" "$T/r"
  [ "$status" -eq 1 ]
  [[ "$output" == *"lib/radin-scope.sh:1: skill name outside the table; use radin_skill NAME"* ]]
  printf 'clean\n' > "$T/r/lib/radin-scope.sh"
  printf '@@skill:nope@@\n' > "$T/r/skills/x/SKILL.md"
  run "$REPO_ROOT/scripts/check-prose.sh" "$T/r"
  [ "$status" -eq 1 ]
  [[ "$output" == *"skills/x/SKILL.md:1: skill nope is not in lib/skill-names-claude.txt"* ]]
}

@test "radin-scope.sh names the host's own ponytail passes" {
  mkdir -p "$T/d"
  run bash "$REPO_ROOT/lib/radin-scope.sh" "$T/d"
  [[ "$output" == *$'passes\t/ponytail:ponytail-audit /ponytail:ponytail-debt'* ]]
  RADIN_HOST=agents run bash "$REPO_ROOT/lib/radin-scope.sh" "$T/d"
  [[ "$output" == *$'passes\tponytail-audit ponytail-debt'* ]]
}

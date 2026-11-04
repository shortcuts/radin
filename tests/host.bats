#!/usr/bin/env bats
# Exercises the radin dispatcher's global --host flag: the state directory
# follows the host, and the claude host stays byte-identical to no flag.

setup() {
  SRC="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  WORK="$(cd "$(mktemp -d)" && pwd -P)"
  # bin/radin hardcodes $HOME/.radin/lib, so a fake HOME links to the repo.
  export HOME="$WORK/home"
  mkdir -p "$HOME/.radin" "$WORK/proj"
  ln -s "$SRC/lib" "$HOME/.radin/lib"
  ln -s "$SRC/bin" "$HOME/.radin/bin"
  RADIN="$HOME/.radin/bin/radin"
  unset RADIN_HOST
  cd "$WORK/proj"
}

teardown() {
  rm -rf "$WORK"
}

@test "no flag writes only under .claude/.radin" {
  run bash -c "echo body | '$RADIN' backlog add feat 'one thing'"
  [ "$status" -eq 0 ]
  [ -f .claude/.radin/backlog/index.jsonl ]
  [ ! -e .agents ]
}

@test "--host agents backlog add, list and count use only .agents/.radin" {
  run bash -c "echo body | '$RADIN' --host agents backlog add feat 'one thing'"
  [ "$status" -eq 0 ]
  [ -f .agents/.radin/backlog/index.jsonl ]
  [ ! -e .claude ]
  run "$RADIN" --host agents backlog count
  [ "$output" = "1" ]
  run "$RADIN" --host agents backlog list
  [[ "$output" == *"one-thing"* ]]
  run "$RADIN" backlog count
  [ "$output" = "0" ]
}

@test "--host=agents is the same as --host agents" {
  run bash -c "echo body | '$RADIN' --host=agents backlog add feat 'one thing'"
  [ "$status" -eq 0 ]
  [ -f .agents/.radin/backlog/index.jsonl ]
}

@test "--host claude is the same as no flag" {
  run bash -c "echo body | '$RADIN' --host claude backlog add feat 'one thing'"
  [ "$status" -eq 0 ]
  [ -f .claude/.radin/backlog/index.jsonl ]
}

@test "an unknown host exits 2 with the host list" {
  run "$RADIN" --host nope backlog count
  [ "$status" -eq 2 ]
  [ "$output" = "radin: unknown host 'nope' (expected claude|agents)" ]
}

@test "--host with no value exits 2 with the usage text" {
  run "$RADIN" --host
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage: radin [--host claude|agents|all]"* ]]
}

@test "--host after the subcommand is not the dispatcher's" {
  run "$RADIN" backlog --host agents
  [ ! -e .agents ]
}

@test "state verbs follow the host" {
  git init -q .
  git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  mkdir -p .agents/.radin .claude/.radin
  printf 'x\n' >.agents/.radin/x
  git add -f .agents/.radin/x
  git -c user.email=t@t -c user.name=t commit -q -m "touch agents state"
  hash="$(git rev-parse HEAD)"
  run "$RADIN" --host agents state task-done some-id "$hash"
  [ "$status" -eq 3 ]
  [[ "$output" == *"under .agents/.radin/"* ]]
  run "$RADIN" state dirty-check
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  printf 'y\n' >.agents/.radin/y
  run "$RADIN" --host agents state dirty-check
  [ -z "$output" ]
  run "$RADIN" state dirty-check
  [[ "$output" == *".agents"* ]]
}

@test "stats scans the host's state directory" {
  mkdir -p "$WORK/repos/a/.agents/.radin" "$WORK/repos/b/.claude/.radin"
  run "$RADIN" --host agents stats --no-transcripts --no-companions --repos-root "$WORK/repos"
  [[ "$output" == *$'\na '* ]]
  [[ "$output" != *$'\nb '* ]]
}

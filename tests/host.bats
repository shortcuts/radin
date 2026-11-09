#!/usr/bin/env bats
# Exercises the radin dispatcher's global --host flag: it picks skill names and the render,
# never the state directory.

setup() {
  SRC="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  WORK="$(cd "$(mktemp -d)" && pwd -P)"
  # A fake HOME links to the repo lib and the built binary.
  export HOME="$WORK/home"
  load helpers/isolate
  isolate_env "$HOME"
  mkdir -p "$HOME/.radin" "$WORK/proj"
  ln -s "$SRC/lib" "$HOME/.radin/lib"
  mkdir -p "$HOME/.radin/bin"
  ln -s "$SRC/target/debug/radin" "$HOME/.radin/bin/radin"
  RADIN="$HOME/.radin/bin/radin"
  unset RADIN_HOST
  cd "$WORK/proj"
}

teardown() {
  rm -rf "$WORK"
}

@test "every host writes the same .radin" {
  run bash -c "echo body | '$RADIN' backlog add feat 'one thing'"
  [ "$status" -eq 0 ]
  run bash -c "echo body | '$RADIN' --host agents backlog add feat 'two thing'"
  [ "$status" -eq 0 ]
  [ -f .radin/backlog/index.jsonl ]
  [ ! -e .claude ]
  [ ! -e .agents ]
  run "$RADIN" --host=agents backlog count
  [ "$output" = "2" ]
  run "$RADIN" --host claude backlog count
  [ "$output" = "2" ]
}

@test "an unknown host exits 2 with the host list" {
  run "$RADIN" --host nope backlog count
  [ "$status" -eq 2 ]
  [ "$output" = "radin: unknown host 'nope' (expected claude|agents)" ]
}

@test "--host with no value exits 2 with the usage text" {
  run "$RADIN" --host
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage: radin [--host claude|agents]"* ]]
}

@test "--host after the subcommand is not the dispatcher's" {
  run "$RADIN" backlog --host agents
  [ ! -e .agents ]
}

@test "--host all is an unknown host" {
  run "$RADIN" --host all backlog count
  [ "$status" -eq 2 ]
  [ "$output" = "radin: unknown host 'all' (expected claude|agents)" ]
}

@test "state verbs read .radin for every host" {
  git init -q .
  git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  mkdir -p .radin
  printf 'x\n' >.radin/x
  git add -f .radin/x
  git -c user.email=t@t -c user.name=t commit -q -m "touch state"
  hash="$(git rev-parse HEAD)"
  run "$RADIN" --host agents state task-done some-id "$hash"
  [ "$status" -eq 3 ]
  [[ "$output" == *"under .radin/"* ]]
  printf 'y\n' >.radin/y
  run "$RADIN" state dirty-check
  [ -z "$output" ]
}

@test "inside opencode no flag still writes .radin" {
  run env OPENCODE=1 bash -c "echo body | '$RADIN' backlog add feat 'one thing'"
  [ "$status" -eq 0 ]
  [ -f .radin/backlog/index.jsonl ]
  [ ! -e .agents ]
}

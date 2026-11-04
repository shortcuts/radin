#!/usr/bin/env bats
# `radin --host all backlog` reads .claude/.radin and .agents/.radin as one
# read-only view with host-prefixed ids; one backlog stays byte-identical.

setup() {
  SRC="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  WORK="$(cd "$(mktemp -d)" && pwd -P)"
  export HOME="$WORK/home"
  load helpers/isolate
  isolate_env "$HOME"
  mkdir -p "$HOME/.radin" "$WORK/proj"
  ln -s "$SRC/lib" "$HOME/.radin/lib"
  ln -s "$SRC/bin" "$HOME/.radin/bin"
  RADIN="$HOME/.radin/bin/radin"
  unset RADIN_HOST RADIN_MERGED
  cd "$WORK/proj"
}

teardown() {
  rm -rf "$WORK"
}

both() {
  echo b | "$RADIN" backlog add feat "shared thing" >/dev/null
  echo b | "$RADIN" backlog add fix "claude only" >/dev/null
  echo b | "$RADIN" --host agents backlog add feat "agents thing" >/dev/null
  echo b | "$RADIN" --host agents backlog add chore "shared thing too" --deps agents-thing >/dev/null
  "$RADIN" --host agents backlog set-priority agents-thing 8 >/dev/null
}

@test "list prefixes ids and depends-on tokens, a higher agents priority first" {
  both
  run "$RADIN" --host all backlog list
  [ "$status" -eq 0 ]
  [ "${lines[0]%%$'\037'*}" = "agents:agents-thing" ]
  [ "${lines[1]%%$'\037'*}" = "claude:shared-thing" ]
  [ "${lines[2]%%$'\037'*}" = "claude:claude-only" ]
  [ "${lines[3]%%$'\037'*}" = "agents:shared-thing-too" ]
  [ "${lines[3]##*$'\037'}" = "agents:agents-thing" ]
}

@test "list --order created is claude then agents" {
  both
  run "$RADIN" --host all backlog list --order created
  [ "${lines[0]%%$'\037'*}" = "claude:shared-thing" ]
  [ "${lines[1]%%$'\037'*}" = "claude:claude-only" ]
  [ "${lines[2]%%$'\037'*}" = "agents:agents-thing" ]
}

@test "count sums both hosts" {
  both
  run "$RADIN" --host all backlog count
  [ "$output" = "4" ]
}

@test "find with a host prefix reads one host, without it both" {
  both
  run "$RADIN" --host all backlog find claude:shared-thing
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "$output" == "claude:shared-thing"$'\t'* ]]
  run "$RADIN" --host all backlog find "shared thing"
  [ "${#lines[@]}" -eq 2 ]
  [[ "${lines[0]}" == "claude:shared-thing"$'\t'* ]]
  [[ "${lines[1]}" == "agents:shared-thing-too"$'\t'* ]]
  run "$RADIN" --host all backlog find nothing-matches
  [ "$status" -eq 1 ]
  [ "$output" = "radin-backlog: no entry matches: nothing-matches" ]
}

@test "show labels each host" {
  both
  run "$RADIN" --host all backlog show
  [[ "$output" == *"# Backlog (host: claude)"* ]]
  [[ "$output" == *"# Backlog (host: agents)"* ]]
}

@test "a write verb is refused and both indexes stay identical" {
  both
  cat .claude/.radin/backlog/index.jsonl .agents/.radin/backlog/index.jsonl >"$WORK/before"
  run "$RADIN" --host all backlog set-priority claude:shared-thing 5
  [ "$status" -eq 1 ]
  [ "$output" = "radin-backlog: merged view is read-only; rerun with --host claude|agents" ]
  cat .claude/.radin/backlog/index.jsonl .agents/.radin/backlog/index.jsonl | cmp - "$WORK/before"
}

@test "--host all on a non-backlog command exits 2" {
  run "$RADIN" --host all update
  [ "$status" -eq 2 ]
  [ "$output" = "radin: --host all reads only: use backlog list|show|count|find" ]
}

@test "one backlog gives the plain single-host output" {
  echo b | "$RADIN" --host agents backlog add feat "only agents" >/dev/null
  run "$RADIN" --host all backlog list
  [ "$output" = "$("$RADIN" --host agents backlog list)" ]
  [[ "$output" == "only-agents"* ]]
  rm -rf .agents
  echo b | "$RADIN" backlog add feat "only claude" >/dev/null
  run "$RADIN" --host all backlog list
  [ "$output" = "$("$RADIN" backlog list)" ]
}

@test "--host agents list stays plain with both seeded" {
  both
  run "$RADIN" --host agents backlog list
  [[ "${lines[0]}" == "agents-thing"* ]]
}

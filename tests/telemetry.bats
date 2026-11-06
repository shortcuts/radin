#!/usr/bin/env bats
# Exercises lib/radin-telemetry.sh: appends one JSON line per event to
# $HOME/.radin/telemetry/<scope>.jsonl. Runs under an isolated HOME.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  CLI="$REPO_ROOT/lib/radin-telemetry.sh"
  TEST_HOME="$(mktemp -d)"
  load helpers/isolate
  isolate_env "$TEST_HOME"
  P="$TEST_HOME/proj"
  git init -q "$P"
  mkdir -p "$P/sub"
  TELE="$TEST_HOME/.radin/telemetry"
}

teardown() {
  rm -rf "$TEST_HOME"
}

@test "record in a repo subdirectory writes the toplevel as repo, with fields in order" {
  top="$(git -C "$P" rev-parse --show-toplevel)"
  run bash -c "cd '$P/sub' && bash '$CLI' record parallel wave-start n=3 mode=group"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$TELE/parallel.jsonl")" -eq 1 ]
  line="$(cat "$TELE/parallel.jsonl")"
  [[ "$line" =~ ^\{\"ts\":\"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\",\"repo\":\"$top\",\"scope\":\"parallel\",\"kind\":\"wave-start\",\"evidence\":\{\"n\":\"3\",\"mode\":\"group\"\}\}$ ]]
}

@test "report-error writes kind error with where, message, then the extra pairs" {
  run bash -c "cd '$P' && bash '$CLI' report-error parallel gate-merge 'merge failed' task=t-one"
  [ "$status" -eq 0 ]
  line="$(cat "$TELE/parallel.jsonl")"
  [[ "$line" == *'"kind":"error"'* ]]
  [[ "$line" == *'"evidence":{"where":"gate-merge","message":"merge failed","task":"t-one"}}' ]]
}

@test "a message with quote, backslash and newline stays on one JSON line" {
  run bash -c "cd '$P' && bash '$CLI' report-error parallel where \$'say \"hi\" \\\\ a\nb'"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$TELE/parallel.jsonl")" -eq 1 ]
  [[ "$(cat "$TELE/parallel.jsonl")" == *'"message":"say \"hi\" \\ a b"'* ]]
}

@test "two scopes write two files, and one scope appends a line per call" {
  run bash -c "cd '$P' && bash '$CLI' record parallel a && bash '$CLI' record parallel b && bash '$CLI' record install c"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$TELE/parallel.jsonl")" -eq 2 ]
  [ "$(wc -l < "$TELE/install.jsonl")" -eq 1 ]
}

@test "outside a git repo the repo field is the working directory" {
  mkdir -p "$TEST_HOME/plain"
  run bash -c "cd '$TEST_HOME/plain' && bash '$CLI' record parallel a"
  [ "$status" -eq 0 ]
  [[ "$(cat "$TELE/parallel.jsonl")" == *"\"repo\":\"$TEST_HOME/plain\""* ]]
}

@test "invalid input exits 2 and writes nothing" {
  run bash "$CLI" record '../x' a
  [ "$status" -eq 2 ]
  run bash "$CLI" record Parallel a
  [ "$status" -eq 2 ]
  run bash "$CLI" record parallel a n3
  [ "$status" -eq 2 ]
  run bash "$CLI" record parallel a 'bad/key=1'
  [ "$status" -eq 2 ]
  run bash "$CLI" record parallel
  [ "$status" -eq 2 ]
  run bash "$CLI" nope
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage:"* ]]
  [ ! -e "$TELE" ]
}

@test "a telemetry path that is a file warns and exits 0 without a record" {
  mkdir -p "$TEST_HOME/.radin"
  : > "$TELE"
  run bash "$CLI" record parallel a n=1
  [ "$status" -eq 0 ]
  [[ "$output" == *"warning"* ]]
  [ ! -s "$TELE" ]
}

@test "bin/radin routes telemetry to the script" {
  mkdir -p "$TEST_HOME/.radin"
  ln -s "$REPO_ROOT/lib" "$TEST_HOME/.radin/lib"
  run bash -c "cd '$P' && env HOME='$TEST_HOME' bash '$REPO_ROOT/bin/radin' telemetry record parallel wave-start n=1"
  [ "$status" -eq 0 ]
  [[ "$(cat "$TELE/parallel.jsonl")" == *'"evidence":{"n":"1"}'* ]]
}

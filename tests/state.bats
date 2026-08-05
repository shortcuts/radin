#!/usr/bin/env bats
# Exercises lib/radin-state.sh: deterministic operations on radin-execute's
# JSONL state files (BACKLOG_STEPS.json, completed.json). Also covers the
# shared JSON helpers in radin-json.sh from the state side (note escaping,
# field extraction).

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  CLI="$REPO_ROOT/lib/radin-state.sh"
  WORK="$(cd "$(mktemp -d)" && pwd -P)"
  STEPS="$WORK/BACKLOG_STEPS.json"
  COMPLETED="$WORK/completed.json"
}

teardown() {
  rm -rf "$WORK"
}

cli() {
  bash "$CLI" "$@"
}

@test "syntax is valid" {
  run bash -n "$CLI"
  [ "$status" -eq 0 ]
}

@test "set-status updates one line, preserving order and depends_on" {
  printf '{"id":"a","order":1,"status":"pending","depends_on":["b"],"note":""}\n' > "$STEPS"
  printf '{"id":"c","order":2,"status":"pending","depends_on":[],"note":""}\n' >> "$STEPS"
  run cli set-status "$STEPS" a failed "boom"
  [ "$status" -eq 0 ]
  run cat "$STEPS"
  [[ "${lines[0]}" == '{"id":"a","order":1,"status":"failed","depends_on":["b"],"note":"boom"}' ]]
  [[ "${lines[1]}" == '{"id":"c","order":2,"status":"pending","depends_on":[],"note":""}' ]]
}

@test "set-status escapes quotes in the note (shared json_escape)" {
  printf '{"id":"a","order":1,"status":"pending","depends_on":[],"note":""}\n' > "$STEPS"
  run cli set-status "$STEPS" a blocked 'keep "x" or drop?'
  [ "$status" -eq 0 ]
  run cat "$STEPS"
  [[ "$output" == *'"note":"keep \"x\" or drop?"'* ]]
}

@test "set-status rejects an unknown status and a missing id" {
  printf '{"id":"a","order":1,"status":"pending","depends_on":[],"note":""}\n' > "$STEPS"
  run cli set-status "$STEPS" a wat ""
  [ "$status" -ne 0 ]
  run cli set-status "$STEPS" nope failed ""
  [ "$status" -ne 0 ]
}

@test "remove deletes only the matching line" {
  printf '{"id":"a","order":1,"status":"pending","depends_on":[],"note":""}\n' > "$STEPS"
  printf '{"id":"b","order":2,"status":"pending","depends_on":[],"note":""}\n' >> "$STEPS"
  run cli remove "$STEPS" a
  [ "$status" -eq 0 ]
  run cat "$STEPS"
  [[ "$output" != *'"id":"a"'* ]]
  [[ "$output" == *'"id":"b"'* ]]
}

@test "completed-add then completed-get round-trips the commit hash (shared json_get)" {
  cli completed-add "$COMPLETED" my-task deadbeef
  run cli completed-get "$COMPLETED" my-task
  [ "$status" -eq 0 ]
  [ "$output" = "deadbeef" ]
}

@test "completed-get exits 1 for an absent id or an absent file" {
  cli completed-add "$COMPLETED" my-task deadbeef
  run cli completed-get "$COMPLETED" other
  [ "$status" -eq 1 ]
  run cli completed-get "$WORK/nope.json" my-task
  [ "$status" -eq 1 ]
}

@test "dirty-check excludes radin's own namespace but reports other changes" {
  git init -q "$WORK/repo"
  ( cd "$WORK/repo"
    git config user.email t@t && git config user.name t
    mkdir -p .claude/.radin/state
    printf 'x\n' > .claude/.radin/state/BACKLOG_STEPS.json )
  run cli dirty-check "$WORK/repo"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  printf 'code\n' > "$WORK/repo/app.txt"
  run cli dirty-check "$WORK/repo"
  [[ "$output" == *"app.txt"* ]]
}

@test "unknown command fails" {
  run cli frobnicate
  [ "$status" -ne 0 ]
}

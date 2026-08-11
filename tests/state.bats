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

@test "steps-init writes schema-shaped JSONL from tab-separated stdin" {
  run cli steps-init "$STEPS" <<EOF
task-a	1
task-b	2	task-a,task-c
EOF
  [ "$status" -eq 0 ]
  run cat "$STEPS"
  [[ "${lines[0]}" == '{"id":"task-a","order":1,"status":"pending","depends_on":[],"note":""}' ]]
  [[ "${lines[1]}" == '{"id":"task-b","order":2,"status":"pending","depends_on":["task-a","task-c"],"note":""}' ]]
}

@test "steps-init rejects a non-numeric order and empty stdin" {
  run cli steps-init "$STEPS" <<EOF
task-a	first
EOF
  [ "$status" -ne 0 ]
  run cli steps-init "$STEPS" < /dev/null
  [ "$status" -ne 0 ]
  [ ! -f "$STEPS" ]
}

@test "next-pending prints the lowest-order pending entry with its deps csv" {
  printf '{"id":"b","order":2,"status":"pending","depends_on":["a"],"note":""}\n' > "$STEPS"
  printf '{"id":"a","order":1,"status":"pending","depends_on":[],"note":""}\n' >> "$STEPS"
  run cli next-pending "$STEPS"
  [ "$status" -eq 0 ]
  [[ "$output" == "a"$'\t'"1"$'\t' ]]
  cli set-status "$STEPS" a failed "boom"
  run cli next-pending "$STEPS"
  [ "$status" -eq 0 ]
  [[ "$output" == "b"$'\t'"2"$'\t'"a" ]]
}

@test "next-pending exits 1 when nothing is pending or the file is absent" {
  printf '{"id":"a","order":1,"status":"failed","depends_on":[],"note":"x"}\n' > "$STEPS"
  run cli next-pending "$STEPS"
  [ "$status" -eq 1 ]
  run cli next-pending "$WORK/nope.json"
  [ "$status" -eq 1 ]
}

@test "deps-check prints id/hash pairs when every dependency completed" {
  printf '{"id":"c","order":2,"status":"pending","depends_on":["a","b"],"note":""}\n' > "$STEPS"
  cli completed-add "$COMPLETED" a hash-a
  cli completed-add "$COMPLETED" b hash-b
  run cli deps-check "$STEPS" "$COMPLETED" c
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "a"$'\t'"hash-a" ]]
  [[ "${lines[1]}" == "b"$'\t'"hash-b" ]]
}

@test "deps-check is silent for an entry with no deps, fails naming an unresolved one" {
  printf '{"id":"a","order":1,"status":"pending","depends_on":[],"note":""}\n' > "$STEPS"
  printf '{"id":"c","order":2,"status":"pending","depends_on":["a"],"note":""}\n' >> "$STEPS"
  run cli deps-check "$STEPS" "$COMPLETED" a
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run cli deps-check "$STEPS" "$COMPLETED" c
  [ "$status" -ne 0 ]
  [[ "$output" == *"dependency 'a'"* ]]
  [[ "$output" == *"pending"* ]]
}

@test "task-done records the commit and removes backlog + steps entries, idempotently" {
  git init -q "$WORK/repo"
  ( cd "$WORK/repo" && bash "$REPO_ROOT/lib/radin-backlog.sh" add fix "my task" <<<"body" )
  NS="$WORK/repo/.claude/.radin"
  printf '{"id":"my-task","order":1,"status":"pending","depends_on":[],"note":""}\n' > "$NS/state/BACKLOG_STEPS.json"
  run cli task-done "$NS" my-task deadbeef
  [ "$status" -eq 0 ]
  run cli completed-get "$NS/state/completed.json" my-task
  [ "$output" = "deadbeef" ]
  [ ! -f "$NS/backlog/tasks/my-task.md" ]
  run grep my-task "$NS/state/BACKLOG_STEPS.json"
  [ "$status" -ne 0 ]
  # A retry after a partial run must not duplicate or fail.
  run cli task-done "$NS" my-task deadbeef
  [ "$status" -eq 0 ]
  [ "$(grep -c my-task "$NS/state/completed.json")" -eq 1 ]
}

@test "stash parks everything except radin's namespace and prints the ref" {
  git init -q "$WORK/repo"
  ( cd "$WORK/repo"
    git config user.email t@t && git config user.name t
    printf 'a\n' > tracked.txt && git add -A && git commit -qm init
    printf 'b\n' > tracked.txt
    mkdir -p .claude/.radin/state
    printf 'x\n' > .claude/.radin/state/BACKLOG_STEPS.json )
  run cli stash "$WORK/repo" "radin-execute: parked"
  [ "$status" -eq 0 ]
  [ "$output" = "stash@{0}" ]
  run git -C "$WORK/repo" stash list
  [[ "$output" == *"radin-execute: parked"* ]]
  [ -f "$WORK/repo/.claude/.radin/state/BACKLOG_STEPS.json" ]
  run cli dirty-check "$WORK/repo"
  [ -z "$output" ]
}

@test "stash fails when there is nothing to stash" {
  git init -q "$WORK/repo"
  ( cd "$WORK/repo" && git config user.email t@t && git config user.name t \
    && printf 'a\n' > f.txt && git add -A && git commit -qm init )
  run cli stash "$WORK/repo" "nothing here"
  [ "$status" -ne 0 ]
  [[ "$output" == *"nothing to stash"* ]]
}

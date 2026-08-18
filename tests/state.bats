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

@test "set-status updates one line, preserving order, depends_on and attempts" {
  printf '{"id":"a","order":1,"status":"in_progress","depends_on":["b"],"attempts":2,"note":""}\n' > "$STEPS"
  printf '{"id":"c","order":2,"status":"pending","depends_on":[],"attempts":0,"note":""}\n' >> "$STEPS"
  run cli set-status "$STEPS" a failed "boom"
  [ "$status" -eq 0 ]
  run cat "$STEPS"
  [[ "${lines[0]}" == '{"id":"a","order":1,"status":"failed","depends_on":["b"],"attempts":2,"note":"boom"}' ]]
  [[ "${lines[1]}" == '{"id":"c","order":2,"status":"pending","depends_on":[],"attempts":0,"note":""}' ]]
}

@test "steps-init seeds attempts at 0 and start claims the task" {
  mkdir -p "$WORK/state"
  steps="$WORK/state/BACKLOG_STEPS.json"
  printf 'a\t1\t\nb\t2\ta\n' | cli steps-init "$steps"
  run cli start "$steps" a
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'attempts\t1')" ]
  run cat "$steps"
  [[ "${lines[0]}" == *'"status":"in_progress"'* ]]
  [[ "${lines[0]}" == *'"attempts":1'* ]]
  # in_progress is not pending: the loop must triage it, never pick it up
  run cli next-pending "$steps"
  [ "$status" -eq 0 ]
  [[ "$output" == b* ]]
}

@test "stuck lists in_progress entries only, exit 1 when none" {
  printf '{"id":"a","order":1,"status":"pending","depends_on":[],"attempts":0,"note":""}\n' > "$STEPS"
  run cli stuck "$STEPS"
  [ "$status" -eq 1 ]
  cli set-status "$STEPS" a in_progress "" 
  run cli stuck "$STEPS"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'a\t0\t')" ]
}

@test "start blocks the task once it passes MAX_ATTEMPTS instead of retrying forever" {
  printf '{"id":"a","order":1,"status":"pending","depends_on":[],"attempts":3,"note":""}\n' > "$STEPS"
  run cli start "$STEPS" a
  [ "$status" -eq 2 ]
  run cat "$STEPS"
  [[ "$output" == *'"status":"blocked"'* ]]
  [[ "$output" == *"MAX_ATTEMPTS"* ]] || [[ "$output" == *"3 times"* ]]
}

@test "every mutation appends a journal event, journal-tail reads them back" {
  ns="$WORK/repo/.claude/.radin"
  mkdir -p "$ns/state"
  steps="$ns/state/BACKLOG_STEPS.json"
  printf 'a\t1\t\n' | cli steps-init "$steps"
  cli start "$steps" a
  cli set-status "$steps" a failed "boom"
  run cli journal-tail "$ns" 10
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == *'"event":"steps-init"'* ]]
  [[ "${lines[1]}" == *'"event":"in_progress","id":"a"'* ]]
  [[ "${lines[2]}" == *'"event":"failed","id":"a","detail":"boom"'* ]]
  [[ "${lines[2]}" == *'"ts":"20'* ]]
}

@test "task-dir prefers the task's worktree and falls back to the repo root" {
  run cli task-dir "$WORK/repo" a
  [ "$status" -eq 0 ]
  [ "$output" = "$WORK/repo" ]
  mkdir -p "$WORK/repo-a"
  run cli task-dir "$WORK/repo" a
  [ "$output" = "$WORK/repo-a" ]
}

@test "triage reports the commits a dead sub-agent left on the task branch" {
  ns="$WORK/repo/.claude/.radin"
  mkdir -p "$ns/state"
  git init -q "$WORK/repo"
  git -C "$WORK/repo" config user.email t@t
  git -C "$WORK/repo" config user.name t
  echo base > "$WORK/repo/f.txt"
  git -C "$WORK/repo" add f.txt
  git -C "$WORK/repo" commit -qm init
  base="$(git -C "$WORK/repo" rev-parse --abbrev-ref HEAD)"
  printf 'a\t1\t\n' | cli steps-init "$ns/state/BACKLOG_STEPS.json"
  cli start "$ns/state/BACKLOG_STEPS.json" a
  git -C "$WORK/repo" checkout -q -b radin/a
  echo work > "$WORK/repo/g.txt"
  git -C "$WORK/repo" add g.txt
  git -C "$WORK/repo" commit -qm work
  git -C "$WORK/repo" checkout -q "$base"
  run cli triage "$ns" a
  [ "$status" -eq 0 ]
  [[ "$output" == *"$(printf 'attempts\t1')"* ]]
  [[ "$output" == *"$(printf 'completed\tnone')"* ]]
  [[ "$output" == *"$(printf 'branch\tradin/a')"* ]]
  [[ "$output" == *"branch_commit"* ]]
  [[ "$output" == *"$(printf 'dirty_files\t0')"* ]]
}

@test "session-set persists the worktree/branch answers, session-get reads them back" {
  ns="$WORK/repo/.claude/.radin"
  mkdir -p "$ns/state"
  run cli session-get "$ns"
  [ "$status" -eq 1 ]
  cli session-set "$ns" yes no
  run cli session-get "$ns"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "$(printf 'worktree\tyes')" ]
  [ "${lines[1]}" = "$(printf 'branch\tno')" ]
  run cli session-set "$ns" maybe no
  [ "$status" -ne 0 ]
}

@test "set-status escapes quotes in the note (shared json_escape)" {
  printf '{"id":"a","order":1,"status":"pending","depends_on":[],"note":""}\n' > "$STEPS"
  run cli set-status "$STEPS" a blocked 'keep "x" or drop?'
  [ "$status" -eq 0 ]
  run cat "$STEPS"
  [[ "$output" == *'"note":"keep \"x\" or drop?"'* ]]
}

@test "set-status rejects an unknown status and a missing id" {
  printf '{"id":"a","order":1,"status":"pending","depends_on":[],"attempts":0,"note":""}\n' > "$STEPS"
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
  [[ "${lines[0]}" == '{"id":"task-a","order":1,"status":"pending","depends_on":[],"attempts":0,"note":""}' ]]
  [[ "${lines[1]}" == '{"id":"task-b","order":2,"status":"pending","depends_on":["task-a","task-c"],"attempts":0,"note":""}' ]]
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

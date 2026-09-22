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

@test "set-status updates one line, preserving order, depends_on and attempts" {
  printf '{"id":"a","order":1,"status":"in_progress","depends_on":["b"],"attempts":2,"note":""}\n' > "$STEPS"
  printf '{"id":"c","order":2,"status":"pending","depends_on":[],"attempts":0,"note":""}\n' >> "$STEPS"
  run cli set-status "$STEPS" a failed "boom"
  [ "$status" -eq 0 ]
  run cat "$STEPS"
  [[ "${lines[0]}" == '{"id":"a","order":1,"status":"failed","depends_on":["b"],"attempts":2,"debugged":0,"note":"boom"}' ]]
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
  cli session-set "$ns" no yes
  cli prepare "$ns" a > /dev/null
  echo work > "$WORK/repo/g.txt"
  git -C "$WORK/repo" add g.txt
  git -C "$WORK/repo" commit -qm work
  git -C "$WORK/repo" checkout -q "$base"
  run cli triage "$ns" a
  [ "$status" -eq 0 ]
  [[ "$output" == *"$(printf 'attempts\t1')"* ]]
  [[ "$output" == *"$(printf 'completed\tnone')"* ]]
  # The branch comes from prepare's record, not from the id.
  [[ "$output" == *"$(printf 'branch\tradin/a')"* ]]
  [[ "$output" == *"branch_commit"* ]]
  [[ "$output" == *"$(printf 'dirty_files\t0')"* ]]
  # An id prepare never saw has no branch to name.
  run cli triage "$ns" never-prepared
  [ "$status" -eq 0 ]
  [[ "$output" == *"$(printf 'branch\tnone')"* ]]
  [[ "$output" != *"branch_commit"* ]]
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

@test "prepare applies the recorded answers instead of trusting a caller" {
  ns="$WORK/repo/.claude/.radin"
  mkdir -p "$ns/state"
  git init -q "$WORK/repo"
  git -C "$WORK/repo" config user.email t@t
  git -C "$WORK/repo" config user.name t
  echo base > "$WORK/repo/f.txt"
  git -C "$WORK/repo" add f.txt
  git -C "$WORK/repo" commit -qm init
  base="$(git -C "$WORK/repo" rev-parse --abbrev-ref HEAD)"

  run cli prepare "$ns" a
  [ "$status" -ne 0 ]
  [[ "$output" == *"session.json"* ]]

  # both no: the user's checkout and branch, untouched
  cli session-set "$ns" no no
  run cli prepare "$ns" a
  [ "$status" -eq 0 ]
  [ "${lines[${#lines[@]}-1]}" = "$WORK/repo" ]
  [ "$(git -C "$WORK/repo" rev-parse --abbrev-ref HEAD)" = "$base" ]
  ! git -C "$WORK/repo" rev-parse --verify -q radin/a
  [ ! -d "$WORK/repo-a" ]
  # The branch is recorded even here, where no derivation could see it.
  [[ "$(cat "$ns/state/prepared/a.json")" == *"\"branch\":\"$base\""*'"worktree":""'* ]]

  # branch only: task branch in the same checkout, no worktree
  cli session-set "$ns" no yes
  run cli prepare "$ns" b
  [ "$status" -eq 0 ]
  [ "${lines[${#lines[@]}-1]}" = "$WORK/repo" ]
  [ "$(git -C "$WORK/repo" rev-parse --abbrev-ref HEAD)" = "radin/b" ]
  [ ! -d "$WORK/repo-b" ]
  [[ "$(cat "$ns/state/prepared/b.json")" == *'"branch":"radin/b"'*'"worktree":""'* ]]
  git -C "$WORK/repo" checkout -q "$base"

  # worktree: its own tree on its own branch, and reusable after a dead run
  cli session-set "$ns" yes yes
  run cli prepare "$ns" c
  [ "$status" -eq 0 ]
  [ "${lines[${#lines[@]}-1]}" = "$WORK/repo-c" ]
  [ "$(git -C "$WORK/repo-c" rev-parse --abbrev-ref HEAD)" = "radin/c" ]
  [[ "$(cat "$ns/state/prepared/c.json")" == *'"branch":"radin/c"'*"\"worktree\":\"$WORK/repo-c\""* ]]
  run cli prepare "$ns" c
  [ "$status" -eq 0 ]
  [ "${lines[${#lines[@]}-1]}" = "$WORK/repo-c" ]
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

@test "completed-list prints id and commit per line" {
  cli completed-add "$COMPLETED" first-task hash1
  cli completed-add "$COMPLETED" second-task hash2
  run cli completed-list "$COMPLETED"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "$(printf 'first-task\thash1')" ]
  [ "${lines[1]}" = "$(printf 'second-task\thash2')" ]
}

@test "completed-list exits 1 with no completions" {
  run cli completed-list "$WORK/nope.json"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  : >"$COMPLETED"
  run cli completed-list "$COMPLETED"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
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
  [[ "${lines[0]}" == '{"id":"task-a","order":1,"status":"pending","depends_on":[],"attempts":0,"debugged":0,"note":""}' ]]
  [[ "${lines[1]}" == '{"id":"task-b","order":2,"status":"pending","depends_on":["task-a","task-c"],"attempts":0,"debugged":0,"note":""}' ]]
}

@test "steps-init takes depends_on from the index line, ignoring stdin" {
  printf '{"id":"a","title":"A","depends_on":[]}\n' > "$WORK/index.jsonl"
  printf '{"id":"b","title":"B","depends_on":["a"]}\n' >> "$WORK/index.jsonl"
  run cli steps-init "$STEPS" "$WORK/index.jsonl" <<EOF
a	1
b	2	zzz
EOF
  [ "$status" -eq 0 ]
  run cat "$STEPS"
  [[ "${lines[0]}" == *'"id":"a"'*'"depends_on":[]'* ]]
  [[ "${lines[1]}" == *'"id":"b"'*'"depends_on":["a"]'* ]]
}

@test "steps-init keeps the stdin deps when the index line has none" {
  printf '{"id":"a","title":"A"}\n' > "$WORK/index.jsonl"
  printf '{"id":"b","title":"B"}\n' >> "$WORK/index.jsonl"
  run cli steps-init "$STEPS" "$WORK/index.jsonl" <<EOF
a	1
b	2	a
c	3	b
EOF
  [ "$status" -eq 0 ]
  run cat "$STEPS"
  [[ "${lines[1]}" == *'"id":"b"'*'"depends_on":["a"]'* ]]
  [[ "${lines[2]}" == *'"id":"c"'*'"depends_on":["b"]'* ]]
}

@test "steps-init rejects a named index that does not exist" {
  run cli steps-init "$STEPS" "$WORK/nope.jsonl" <<EOF
a	1
EOF
  [ "$status" -ne 0 ]
  [ ! -f "$STEPS" ]
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
  ( cd "$WORK/repo"
    git config user.email t@t && git config user.name t
    printf 'a\n' > f.txt && git add f.txt && git commit -qm init
    bash "$REPO_ROOT/lib/radin-backlog.sh" add fix "my task" <<<"body" )
  hash="$(git -C "$WORK/repo" rev-parse HEAD)"
  NS="$WORK/repo/.claude/.radin"
  ( cd "$WORK/repo" && bash "$REPO_ROOT/lib/radin-backlog.sh" add-plan my-task "$NS/plans/my-task.md" ) > /dev/null
  printf '{"id":"my-task","order":1,"status":"pending","depends_on":[],"note":""}\n' > "$NS/state/BACKLOG_STEPS.json"
  cli session-set "$NS" no no
  cli prepare "$NS" my-task > /dev/null
  run cli task-done "$NS" my-task "$hash"
  [ "$status" -eq 0 ]
  run cli completed-get "$NS/state/completed.json" my-task
  [ "$output" = "$hash" ]
  [ ! -f "$NS/backlog/tasks/my-task.md" ]
  run grep my-task "$NS/state/BACKLOG_STEPS.json"
  [ "$status" -ne 0 ]
  # The title is captured before the backlog entry goes away: nothing else
  # can name the task in the final report.
  [[ "$(cat "$NS/state/completed.json")" == *'"title":"my task"'* ]]
  # So is the provenance: the branch prepare recorded, the entry's plan
  # pointer, and the completion instant.
  line="$(cat "$NS/state/completed.json")"
  [[ "$line" == *"\"plan\":\"$NS/plans/my-task.md\""* ]]
  [[ "$line" != *'"branch":""'* ]]
  [[ "$line" == *'"ts":"20'*'Z"'* ]]
  run cli completed-show "$NS/state/completed.json" my-task
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "$(printf 'id\tmy-task')" ]
  [[ "$output" == *"$(printf 'plan\t%s' "$NS/plans/my-task.md")"* ]]
  run cli completed-show "$NS/state/completed.json" nope
  [ "$status" -eq 1 ]
  # A line written before provenance existed reads as unknown, not as itself.
  printf '{"id":"old-task","commit":"cafe","title":"old"}\n' >> "$NS/state/completed.json"
  run cli completed-show "$NS/state/completed.json" old-task
  [ "$status" -eq 0 ]
  [ "${lines[3]}" = "$(printf 'branch\t')" ]
  # completed-list stays two TAB-separated fields: radin tui parses it.
  run cli completed-list "$NS/state/completed.json"
  [ "${lines[0]}" = "$(printf 'my-task\t%s' "$hash")" ]
  # A retry after a partial run must not duplicate or fail.
  run cli task-done "$NS" my-task "$hash"
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


# One git repo with a backlog (`aa task` … `dd task`), built once and copied
# per test: the git init and four `backlog add` runs cost more than every
# assertion that follows them.
setup_file() {
  export STATE_TEMPLATE="$BATS_FILE_TMPDIR/template"
  root="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  git init -q "$STATE_TEMPLATE"
  git -C "$STATE_TEMPLATE" config user.email t@t
  git -C "$STATE_TEMPLATE" config user.name t
  printf 'a\n' > "$STATE_TEMPLATE/f.txt"
  git -C "$STATE_TEMPLATE" add f.txt
  git -C "$STATE_TEMPLATE" commit -qm init
  for t in "aa task" "bb task" "cc task" "dd task"; do
    ( cd "$STATE_TEMPLATE" && bash "$root/lib/radin-backlog.sh" add fix "$t" <<<"body" ) > /dev/null
  done
}

# Sets REPO/NS/ST on a fresh copy of that template.
fixture_repo() {
  REPO="$WORK/repo"
  NS="$REPO/.claude/.radin"
  ST="$NS/state/BACKLOG_STEPS.json"
  cp -R "$STATE_TEMPLATE" "$REPO"
}

@test "steps-init seeds debugged and honours the fourth status field" {
  run cli steps-init "$STEPS" <<EOF
a	1
b	2		deferred
EOF
  [ "$status" -eq 0 ]
  run cat "$STEPS"
  [[ "${lines[0]}" == *'"status":"pending"'*'"debugged":0'* ]]
  [[ "${lines[1]}" == *'"status":"deferred"'*'"depends_on":[]'* ]]
  # deferred is not pending: the loop never picks one up
  run cli next-pending "$STEPS"
  [ "$status" -eq 0 ]
  [[ "$output" == a* ]]
  cli set-status "$STEPS" a failed boom
  run cli next-pending "$STEPS"
  [ "$status" -eq 1 ]
  run cli steps-init "$WORK/other.json" <<EOF
c	1		wat
EOF
  [ "$status" -ne 0 ]
  [[ "$output" == *"pending|deferred"* ]]
}

@test "set-status and start preserve the debugged flag" {
  printf '{"id":"a","order":1,"status":"pending","depends_on":[],"attempts":0,"debugged":1,"note":""}\n' > "$STEPS"
  cli set-status "$STEPS" a failed boom
  run cat "$STEPS"
  [[ "$output" == *'"debugged":1'* ]]
  cli start "$STEPS" a
  run cat "$STEPS"
  [[ "$output" == *'"debugged":1'* ]]
}

@test "task-next picks, gates on dependencies, and blocks what it skips" {
  fixture_repo
  printf 'aa-task\t1\t\nbb-task\t2\taa-task\ncc-task\t3\t\ndd-task\t4\t\tdeferred\n' | cli steps-init "$ST" > /dev/null
  run cat "$NS/state/baseline.json"
  [ "$output" = '{"backlog_count":4,"completed_count":0}' ]

  run cli task-next "$NS"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "$(printf 'id\taa-task')" ]
  [ "${lines[1]}" = "$(printf 'order\t1')" ]

  # bb-task's dependency failed: blocked with the CLI's own message, skipped,
  # and the next ready task returned in the same call
  cli set-status "$ST" aa-task failed boom
  run cli task-next "$NS"
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "$(printf 'blocked\tbb-task\t')"*"which is failed" ]]
  [[ "${lines[0]}" != *"radin-state:"* ]]
  [ "${lines[1]}" = "$(printf 'id\tcc-task')" ]
  [[ "$(cat "$ST")" == *'"id":"bb-task","order":2,"status":"blocked"'* ]]

  # once the dependency is recorded, its commit comes back with the task
  cli completed-add "$NS/state/completed.json" aa-task hash-aa "aa task"
  cli set-status "$ST" bb-task pending ""
  run cli task-next "$NS"
  [ "$status" -eq 0 ]
  [ "${lines[2]}" = "$(printf 'dep\taa-task\thash-aa')" ]

  # nothing pending left, and a deferred entry is never picked up
  cli set-status "$ST" bb-task failed boom
  cli set-status "$ST" cc-task failed boom
  run cli task-next "$NS"
  [ "$status" -eq 1 ]
}

@test "task-done rejects a hash that is not a reachable commit" {
  fixture_repo
  printf 'aa-task\t1\t\n' | cli steps-init "$ST" > /dev/null
  run cli task-done "$NS" aa-task deadbeef
  [ "$status" -eq 3 ]
  [[ "$output" == *"is not a commit"* ]]
  git -C "$REPO" checkout -q -b sideshow
  printf 'b\n' > "$REPO/g.txt"
  git -C "$REPO" add g.txt
  git -C "$REPO" commit -qm elsewhere
  side="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" checkout -q -
  run cli task-done "$NS" aa-task "$side"
  [ "$status" -eq 3 ]
  [[ "$output" == *"is not reachable"* ]]
  # neither attempt recorded anything
  [ ! -s "$NS/state/completed.json" ]
  [[ "$(cat "$ST")" == *'"id":"aa-task"'* ]]
}

@test "task-done validates against the branch prepare recorded" {
  fixture_repo
  printf 'aa-task\t1\t\n' | cli steps-init "$ST" > /dev/null
  cli session-set "$NS" no no
  cli prepare "$NS" aa-task > /dev/null
  # A stale radin/<id> from an abandoned run, without the work commit: the
  # branch prepare recorded is the one that counts.
  git -C "$REPO" branch radin/aa-task
  printf 'work\n' > "$REPO/g.txt"
  git -C "$REPO" add g.txt
  git -C "$REPO" commit -qm work
  hash="$(git -C "$REPO" rev-parse HEAD)"
  run cli task-done "$NS" aa-task "$hash"
  [ "$status" -eq 0 ]
  base="$(git -C "$REPO" rev-parse --abbrev-ref HEAD)"
  [[ "$(cat "$NS/state/completed.json")" == *"\"branch\":\"$base\""* ]]
}

@test "task-fail offers one debug pass per session, then fails the task" {
  fixture_repo
  printf 'aa-task\t1\t\n' | cli steps-init "$ST" > /dev/null
  cli start "$ST" aa-task > /dev/null
  run cli task-fail "$NS" aa-task "the build broke"
  [ "$status" -eq 3 ]
  [ "$output" = "$(printf 'debug\tthe build broke')" ]
  # the debug offer changes nothing but the flag
  [[ "$(cat "$ST")" == *'"status":"in_progress"'*'"attempts":1'*'"debugged":1'* ]]
  run cli task-fail "$NS" aa-task "the build broke"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Task 1 'aa task' failed: the build broke."* ]]
  [[ "$(cat "$ST")" == *'"status":"failed"'*'"note":"the build broke"'* ]]
}

@test "task-diagnosis labels the task file, and task-fail then names it" {
  fixture_repo
  printf 'aa-task\t1\t\nbb-task\t2\t\n' | cli steps-init "$ST" > /dev/null
  echo "the flag was inverted" | cli task-diagnosis "$NS" aa-task
  run cat "$NS/backlog/tasks/aa-task.md"
  [[ "$output" == *"**Root cause:** the flag was inverted"* ]]
  # a diagnosis changes no status: the retry's start bumps attempts instead
  [[ "$(cat "$ST")" == *'"id":"aa-task"'*'"status":"pending"'* ]]
  cli task-fail "$NS" aa-task boom || true
  cli task-fail "$NS" aa-task boom
  [[ "$(cat "$ST")" == *'**Root cause:**'* ]]

  # --no-status never offers a debug pass
  run cli task-fail "$NS" bb-task --no-status "I have a question about"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Task 2 'bb task' failed"* ]]
  [[ "$(cat "$ST")" == *'"id":"bb-task"'*'"status":"failed"'* ]]
  [[ "$(cat "$ST")" == *"last words: I have a question about"* ]]
}

@test "task-report routes a SUCCESS line to task-done and says continue" {
  fixture_repo
  printf 'aa-task\t1\t\n' | cli steps-init "$ST" > /dev/null
  cli start "$ST" aa-task > /dev/null
  hash="$(git -C "$REPO" rev-parse HEAD)"
  run cli task-report "$NS" aa-task "STATUS: SUCCESS — $hash"
  [ "$status" -eq 0 ]
  [[ "$output" == *"recorded at $hash"* ]]
  [ "${lines[${#lines[@]}-1]}" = "$(printf 'next\tcontinue')" ]
  [[ "$(cat "$NS/state/completed.json")" == *'"id":"aa-task"'* ]]
}

@test "task-report fails an unsupported SUCCESS and a hashless one" {
  fixture_repo
  printf 'aa-task\t1\t\nbb-task\t2\t\n' | cli steps-init "$ST" > /dev/null
  run cli task-report "$NS" aa-task "STATUS: SUCCESS — deadbeef"
  [ "$status" -eq 0 ]
  # The first failure of a task is its debug offer, whatever produced it.
  [ "${lines[${#lines[@]}-1]}" = "$(printf 'next\tdebug')" ]
  run cli task-report "$NS" bb-task "STATUS: SUCCESS — no new commit, nothing to do"
  [ "$status" -eq 0 ]
  [ "${lines[${#lines[@]}-1]}" = "$(printf 'next\tdebug')" ]
  [ ! -s "$NS/state/completed.json" ]
}

@test "task-report offers one debug pass, then fails the task" {
  fixture_repo
  printf 'aa-task\t1\t\n' | cli steps-init "$ST" > /dev/null
  cli start "$ST" aa-task > /dev/null
  run cli task-report "$NS" aa-task "STATUS: FAILED — the suite broke"
  [ "$status" -eq 0 ]
  [ "${lines[${#lines[@]}-1]}" = "$(printf 'next\tdebug')" ]
  run cli task-report "$NS" aa-task "STATUS: FAILED — the suite broke"
  [ "$status" -eq 0 ]
  [[ "$output" == *"failed: the suite broke."* ]]
  [ "${lines[${#lines[@]}-1]}" = "$(printf 'next\tcontinue')" ]
  [[ "$(cat "$ST")" == *'"status":"failed"'*'"note":"the suite broke"'* ]]
}

@test "task-report hands a BLOCKED line to the clarify route, touching no state" {
  fixture_repo
  printf 'aa-task\t1\t\nbb-task\t2\t\n' | cli steps-init "$ST" > /dev/null
  run cli task-report "$NS" aa-task "STATUS: BLOCKED (FACT) — does the SDK retry"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'next\tclarify FACT')" ]
  run cli task-report "$NS" bb-task "STATUS: BLOCKED (DECISION) — keep or drop the flag"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'next\tclarify DECISION')" ]
  [[ "$(cat "$ST")" == *'"id":"aa-task"'*'"status":"pending"'* ]]
}

@test "task-report stashes a dirty tree before it believes any status" {
  fixture_repo
  printf 'aa-task\t1\t\n' | cli steps-init "$ST" > /dev/null
  hash="$(git -C "$REPO" rev-parse HEAD)"
  printf 'half done\n' > "$REPO/wip.txt"
  run cli task-report "$NS" aa-task "STATUS: SUCCESS — $hash"
  [ "$status" -eq 0 ]
  [[ "$output" == *"left a dirty tree"* ]]
  [ "${lines[${#lines[@]}-1]}" = "$(printf 'next\tcontinue')" ]
  [ ! -s "$NS/state/completed.json" ]
  [[ "$(cat "$ST")" == *'"status":"failed"'* ]]
}

@test "task-report takes --no-status, and refuses a line with no status word" {
  fixture_repo
  printf 'aa-task\t1\t\nbb-task\t2\t\n' | cli steps-init "$ST" > /dev/null
  run cli task-report "$NS" aa-task --no-status "I have a question about"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Task 1 'aa task' failed"* ]]
  [ "${lines[${#lines[@]}-1]}" = "$(printf 'next\tcontinue')" ]
  run cli task-report "$NS" bb-task "all done, hope that helps"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no SUCCESS/FAILED/BLOCKED"* ]]
}

@test "dirty-recover exits 1 on a clean tree and stashes a dirty one" {
  fixture_repo
  printf 'aa-task\t1\t\n' | cli steps-init "$ST" > /dev/null
  run cli dirty-recover "$NS" aa-task SUCCESS
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  printf 'half done\n' > "$REPO/wip.txt"
  run cli dirty-recover "$NS" aa-task SUCCESS
  [ "$status" -eq 0 ]
  [[ "$output" == *"Task 1 'aa task'"*"reported SUCCESS but left a dirty tree"*"stash@{0}"* ]]
  [ ! -f "$REPO/wip.txt" ]
  [[ "$(cat "$ST")" == *'"status":"failed"'* ]]
  [[ "$(cat "$ST")" == *"stashed as stash@{0}"*"$REPO"* ]]
}

@test "recover acts on triage's facts, and hands back only the commits case" {
  fixture_repo
  printf 'aa-task\t1\t\nbb-task\t2\t\ncc-task\t3\t\ndd-task\t4\t\n' | cli steps-init "$ST" > /dev/null
  hash="$(git -C "$REPO" rev-parse HEAD)"

  # already recorded: finish the bookkeeping the dead session missed
  cli completed-add "$NS/state/completed.json" aa-task "$hash" "aa task"
  run cli recover "$NS" aa-task
  [ "$status" -eq 0 ]
  [[ "$output" == *"bookkeeping completed at $hash"* ]]
  [[ "$(cat "$ST")" != *'"id":"aa-task"'* ]]

  # nothing left behind: straight back to pending
  run cli recover "$NS" bb-task
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing left behind, back to pending"* ]]

  # a dirty tree gets parked first
  printf 'junk\n' > "$REPO/junk.txt"
  run cli recover "$NS" cc-task
  [ "$status" -eq 0 ]
  [[ "$output" == *"stashed stash@{0}, back to pending"* ]]
  [ ! -f "$REPO/junk.txt" ]
  [[ "$(cat "$ST")" == *'"id":"cc-task"'*'"status":"pending"'* ]]

  # commits on the task branch: only the model can judge them
  base="$(git -C "$REPO" rev-parse --abbrev-ref HEAD)"
  cli session-set "$NS" no yes
  cli prepare "$NS" dd-task > /dev/null
  printf 'work\n' > "$REPO/g.txt"
  git -C "$REPO" add g.txt
  git -C "$REPO" commit -qm work
  git -C "$REPO" checkout -q "$base"
  run cli recover "$NS" dd-task
  [ "$status" -eq 3 ]
  [[ "$output" == *"branch_commit"*"radin/dd-task"* ]] || [[ "$output" == *"radin/dd-task"*"branch_commit"* ]]
  run cli recover-reject "$NS" dd-task
  [ "$status" -eq 0 ]
  [[ "$output" == *"do not satisfy the task"* ]]
  [[ "$(cat "$ST")" == *'"status":"blocked"'*"radin/dd-task"* ]]
}

@test "report prints every outcome, scoped to this session and to the recorded modes" {
  fixture_repo
  printf 'aa-task\t1\t\nbb-task\t2\t\ncc-task\t3\t\ndd-task\t4\t\tdeferred\n' | cli steps-init "$ST" > /dev/null
  cli session-set "$NS" no yes
  hash="$(git -C "$REPO" rev-parse HEAD)"
  cli task-done "$NS" aa-task "$hash" > /dev/null
  cli set-status "$ST" bb-task failed "the build broke"
  cli set-status "$ST" cc-task blocked "which API? Options: a, b"

  run cli report "$NS" "bb task — /grilling: asks the user"
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 succeeded, 1 failed, 1 awaiting your decision"* ]]
  [[ "$output" == *"- aa task — $hash on radin/aa-task. Merge: git merge radin/aa-task"* ]]
  [[ "$output" == *"Failed (left in the backlog for retry):"$'\n'"- bb task — the build broke"* ]]
  [[ "$output" == *"- cc task — which API? Options: a, b"* ]]
  [[ "$output" == *"Deferred at your request (left in the backlog):"$'\n'"- dd task"* ]]
  [[ "$output" == *"- bb task — /grilling: asks the user"* ]]
  [[ "$output" == *"Net-new backlog entries this session: 0"* ]]
  [[ "$output" == *"no residual changes"* ]]

  # both modes no: no branch, no worktree, no merge command. And residual
  # changes are parked, never committed.
  cli session-set "$NS" no no
  printf 'stray\n' > "$REPO/stray.txt"
  run cli report "$NS"
  [ "$status" -eq 0 ]
  [[ "$output" == *"- aa task — $hash"* ]]
  [[ "$output" != *"radin/aa-task"* ]]
  [[ "$output" != *"Merge:"* ]]
  [[ "$output" == *"residual changes stashed as stash@{0}"* ]]
  [[ "$output" == *"Stashes created this session:"* ]]
  [ ! -f "$REPO/stray.txt" ]
  [[ "$output" != *"Skills dropped"* ]]
}

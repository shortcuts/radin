#!/usr/bin/env bats
# Exercises lib/radin-state.sh: deterministic operations on radin-execute's
# JSONL state files (BACKLOG_STEPS.json, completed.json). Also covers the
# shared JSON helpers in radin-json.sh from the state side (note escaping,
# field extraction).

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  CLI="$REPO_ROOT/lib/radin-state.sh"
  WORK="$(cd "$(mktemp -d)" && pwd -P)"
  NS="$WORK/.claude/.radin"
  mkdir -p "$NS/state"
  STEPS="$NS/state/BACKLOG_STEPS.json"
  COMPLETED="$NS/state/completed.json"
}

teardown() {
  rm -rf "$WORK"
}

# Every verb resolves the namespace from the current directory: the test's
# repo once it has one, else the scratch dir.
cli() {
  (cd "${REPO:-$WORK}" && bash "$CLI" "$@")
}

@test "set-status updates one line, preserving order, depends_on and attempts" {
  printf '{"id":"a","order":1,"status":"in_progress","depends_on":["b"],"attempts":2,"note":""}\n' > "$STEPS"
  printf '{"id":"c","order":2,"status":"pending","depends_on":[],"attempts":0,"note":""}\n' >> "$STEPS"
  run cli set-status a failed "boom"
  [ "$status" -eq 0 ]
  run cat "$STEPS"
  [[ "${lines[0]}" == '{"id":"a","order":1,"status":"failed","depends_on":["b"],"attempts":2,"debugged":0,"note":"boom"}' ]]
  [[ "${lines[1]}" == '{"id":"c","order":2,"status":"pending","depends_on":[],"attempts":0,"note":""}' ]]
}

@test "stuck lists in_progress entries only, exit 1 when none" {
  printf '{"id":"a","order":1,"status":"pending","depends_on":[],"attempts":0,"note":""}\n' > "$STEPS"
  run cli stuck
  [ "$status" -eq 1 ]
  cli set-status a in_progress "" 
  run cli stuck
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'a\t0\t')" ]
}

@test "every mutation appends a journal event, journal-tail reads them back" {
  printf 'a\t1\t\n' | cli steps-init
  cli set-status a in_progress ""
  cli set-status a failed "boom"
  run cli journal-tail 10
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == *'"event":"steps-init"'* ]]
  [[ "${lines[1]}" == *'"event":"in_progress","id":"a"'* ]]
  [[ "${lines[2]}" == *'"event":"failed","id":"a","detail":"boom"'* ]]
  [[ "${lines[2]}" == *'"ts":"20'* ]]
}

@test "task-dir prefers the task's worktree and falls back to the repo root" {
  REPO="$WORK/repo"
  mkdir -p "$REPO"
  run cli task-dir a
  [ "$status" -eq 0 ]
  [ "$output" = "$WORK/repo" ]
  mkdir -p "$WORK/repo-a"
  run cli task-dir a
  [ "$output" = "$WORK/repo-a" ]
}

@test "session-set persists the worktree/branch answers, session-get reads them back" {
  REPO="$WORK/repo"
  ns="$REPO/.claude/.radin"
  mkdir -p "$ns/state"
  run cli session-get
  [ "$status" -eq 1 ]
  cli session-set yes no
  run cli session-get
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "$(printf 'worktree\tyes')" ]
  [ "${lines[1]}" = "$(printf 'branch\tno')" ]
  run cli session-set maybe no
  [ "$status" -ne 0 ]
}

@test "prepare applies the recorded answers instead of trusting a caller" {
  REPO="$WORK/repo"
  ns="$REPO/.claude/.radin"
  mkdir -p "$ns/state"
  git init -q "$WORK/repo"
  git -C "$WORK/repo" config user.email t@t
  git -C "$WORK/repo" config user.name t
  echo base > "$WORK/repo/f.txt"
  git -C "$WORK/repo" add f.txt
  git -C "$WORK/repo" commit -qm init
  base="$(git -C "$WORK/repo" rev-parse --abbrev-ref HEAD)"

  run cli prepare a
  [ "$status" -ne 0 ]
  [[ "$output" == *"session.json"* ]]

  # both no: the user's checkout and branch, untouched
  cli session-set no no
  run cli prepare a
  [ "$status" -eq 0 ]
  [ "${lines[${#lines[@]}-1]}" = "$WORK/repo" ]
  [ "$(git -C "$WORK/repo" rev-parse --abbrev-ref HEAD)" = "$base" ]
  run ! git -C "$WORK/repo" rev-parse --verify -q radin/a
  [ ! -d "$WORK/repo-a" ]
  # The branch is recorded even here, where no derivation could see it.
  [[ "$(cat "$ns/state/prepared/a.json")" == *"\"branch\":\"$base\""*'"worktree":""'* ]]

  # branch only: task branch in the same checkout, no worktree
  cli session-set no yes
  run cli prepare b
  [ "$status" -eq 0 ]
  [ "${lines[${#lines[@]}-1]}" = "$WORK/repo" ]
  [ "$(git -C "$WORK/repo" rev-parse --abbrev-ref HEAD)" = "radin/b" ]
  [ ! -d "$WORK/repo-b" ]
  [[ "$(cat "$ns/state/prepared/b.json")" == *'"branch":"radin/b"'*'"worktree":""'* ]]
  git -C "$WORK/repo" checkout -q "$base"

  # worktree: its own tree on its own branch, and reusable after a dead run
  cli session-set yes yes
  run cli prepare c
  [ "$status" -eq 0 ]
  [ "${lines[${#lines[@]}-1]}" = "$WORK/repo-c" ]
  [ "$(git -C "$WORK/repo-c" rev-parse --abbrev-ref HEAD)" = "radin/c" ]
  [[ "$(cat "$ns/state/prepared/c.json")" == *'"branch":"radin/c"'*"\"worktree\":\"$WORK/repo-c\""* ]]
  run cli prepare c
  [ "$status" -eq 0 ]
  [ "${lines[${#lines[@]}-1]}" = "$WORK/repo-c" ]
}

@test "set-status escapes quotes in the note (shared json_escape)" {
  printf '{"id":"a","order":1,"status":"pending","depends_on":[],"note":""}\n' > "$STEPS"
  run cli set-status a blocked 'keep "x" or drop?'
  [ "$status" -eq 0 ]
  run cat "$STEPS"
  [[ "$output" == *'"note":"keep \"x\" or drop?"'* ]]
}

@test "set-status rejects an unknown status and a missing id" {
  printf '{"id":"a","order":1,"status":"pending","depends_on":[],"attempts":0,"note":""}\n' > "$STEPS"
  run cli set-status a wat ""
  [ "$status" -ne 0 ]
  run cli set-status nope failed ""
  [ "$status" -ne 0 ]
}

@test "completed-list prints id and commit per line" {
  printf '{"id":"%s","commit":"%s","title":"%s"}\n' first-task hash1 "" >> "$COMPLETED"
  printf '{"id":"%s","commit":"%s","title":"%s"}\n' second-task hash2 "" >> "$COMPLETED"
  run cli completed-list
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "$(printf 'first-task\thash1')" ]
  [ "${lines[1]}" = "$(printf 'second-task\thash2')" ]
}

@test "completed-list exits 1 with no completions" {
  run cli completed-list
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  : >"$COMPLETED"
  run cli completed-list
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "dirty-check excludes radin's own namespace but reports other changes" {
  REPO="$WORK/repo"
  git init -q "$REPO"
  ( cd "$REPO"
    git config user.email t@t && git config user.name t
    mkdir -p .claude/.radin/state
    printf 'x\n' > .claude/.radin/state/BACKLOG_STEPS.json )
  run cli dirty-check
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  printf 'code\n' > "$REPO/app.txt"
  run cli dirty-check
  [[ "$output" == *"app.txt"* ]]
}

@test "unknown command fails" {
  run cli frobnicate
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown command: frobnicate"* ]]
}

@test "steps-init writes schema-shaped JSONL from tab-separated stdin" {
  run cli steps-init <<EOF
task-a	1
task-b	2	task-a,task-c
EOF
  [ "$status" -eq 0 ]
  run cat "$STEPS"
  [[ "${lines[0]}" == '{"id":"task-a","order":1,"status":"pending","depends_on":[],"attempts":0,"debugged":0,"note":""}' ]]
  [[ "${lines[1]}" == '{"id":"task-b","order":2,"status":"pending","depends_on":["task-a","task-c"],"attempts":0,"debugged":0,"note":""}' ]]
}

@test "steps-init takes depends_on from the index line, ignoring stdin" {
  mkdir -p "$NS/backlog"
  printf '{"id":"a","title":"A","depends_on":[]}\n' > "$NS/backlog/index.jsonl"
  printf '{"id":"b","title":"B","depends_on":["a"]}\n' >> "$NS/backlog/index.jsonl"
  run cli steps-init <<EOF
a	1
b	2	zzz
EOF
  [ "$status" -eq 0 ]
  run cat "$STEPS"
  [[ "${lines[0]}" == *'"id":"a"'*'"depends_on":[]'* ]]
  [[ "${lines[1]}" == *'"id":"b"'*'"depends_on":["a"]'* ]]
}

@test "steps-init keeps the stdin deps when the index line has none" {
  mkdir -p "$NS/backlog"
  printf '{"id":"a","title":"A"}\n' > "$NS/backlog/index.jsonl"
  printf '{"id":"b","title":"B"}\n' >> "$NS/backlog/index.jsonl"
  run cli steps-init <<EOF
a	1
b	2	a
c	3	b
EOF
  [ "$status" -eq 0 ]
  run cat "$STEPS"
  [[ "${lines[1]}" == *'"id":"b"'*'"depends_on":["a"]'* ]]
  [[ "${lines[2]}" == *'"id":"c"'*'"depends_on":["b"]'* ]]
}

@test "steps-init rejects a non-numeric order and empty stdin" {
  run cli steps-init <<EOF
task-a	first
EOF
  [ "$status" -ne 0 ]
  run cli steps-init < /dev/null
  [ "$status" -ne 0 ]
  [ ! -f "$STEPS" ]
}

@test "deps-check prints id/hash pairs when every dependency completed" {
  printf '{"id":"c","order":2,"status":"pending","depends_on":["a","b"],"note":""}\n' > "$STEPS"
  printf '{"id":"%s","commit":"%s","title":"%s"}\n' a hash-a "" >> "$COMPLETED"
  printf '{"id":"%s","commit":"%s","title":"%s"}\n' b hash-b "" >> "$COMPLETED"
  run cli deps-check c
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "a"$'\t'"hash-a" ]]
  [[ "${lines[1]}" == "b"$'\t'"hash-b" ]]
}

@test "deps-check is silent for an entry with no deps, fails naming an unresolved one" {
  printf '{"id":"a","order":1,"status":"pending","depends_on":[],"note":""}\n' > "$STEPS"
  printf '{"id":"c","order":2,"status":"pending","depends_on":["a"],"note":""}\n' >> "$STEPS"
  run cli deps-check a
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run cli deps-check c
  [ "$status" -ne 0 ]
  [[ "$output" == *"dependency 'a'"* ]]
  [[ "$output" == *"pending"* ]]
}

@test "task-done records the commit and removes backlog + steps entries, idempotently, and trace reads it back" {
  fixture_repo
  hash="$(git -C "$WORK/repo" rev-parse HEAD)"
  ( cd "$WORK/repo" && bash "$REPO_ROOT/lib/radin-backlog.sh" add-plan aa-task "$NS/plans/aa-task.md" ) > /dev/null
  printf '{"id":"aa-task","order":1,"status":"pending","depends_on":[],"note":""}\n' > "$NS/state/BACKLOG_STEPS.json"
  cli session-set no no
  cli prepare aa-task > /dev/null
  run cli task-done aa-task "$hash"
  [ "$status" -eq 0 ]
  [[ "$(cat "$NS/state/completed.json")" == *"\"id\":\"aa-task\",\"commit\":\"$hash\""* ]]
  [ ! -f "$NS/backlog/tasks/aa-task.md" ]
  run grep aa-task "$NS/state/BACKLOG_STEPS.json"
  [ "$status" -ne 0 ]
  # The title is captured before the backlog entry goes away: nothing else
  # can name the task in the final report.
  [[ "$(cat "$NS/state/completed.json")" == *'"title":"aa task"'* ]]
  # So is the provenance: the branch prepare recorded, the entry's plan
  # pointer, and the completion instant.
  line="$(cat "$NS/state/completed.json")"
  [[ "$line" == *"\"plan\":\"$NS/plans/aa-task.md\""* ]]
  [[ "$line" != *'"branch":""'* ]]
  [[ "$line" == *'"ts":"20'*'Z"'* ]]
  run cli completed-show aa-task
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "$(printf 'id\taa-task')" ]
  [[ "$output" == *"$(printf 'plan\t%s' "$NS/plans/aa-task.md")"* ]]
  run cli completed-show nope
  [ "$status" -eq 1 ]
  branch="$(git -C "$WORK/repo" rev-parse --abbrev-ref HEAD)"
  run cli trace aa-task
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "$(printf 'task\taa-task')" ]
  [[ "$output" == *"$(printf 'commit\t%s' "$hash")"* ]]
  [[ "$output" == *"$(printf 'branch\t%s' "$branch")"* ]]
  [[ "$output" == *"$(printf 'plan\t%s' "$NS/plans/aa-task.md")"* ]]
  [[ "$output" == *"$(printf 'status\tdone')"* ]]
  # A reviewer pastes git log's full 40 while the store may hold a short hash:
  # either side may be the prefix, with a seven-character floor.
  run cli trace "${hash:0:7}"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "$(printf 'task\taa-task')" ]
  # `session-set no no` makes the user's own checkout the recorded branch.
  run cli trace "$branch"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "$(printf 'task\taa-task')" ]
  run cli trace not-a-thing
  [ "$status" -eq 1 ]
  # One token really can read two ways: a task whose id is that branch name.
  printf '{"id":"%s","commit":"cafe1234","title":"x"}\n' "$branch" >> "$NS/state/completed.json"
  run cli trace "$branch"
  [ "$status" -eq 2 ]
  [[ "$output" == *"ambiguous, 2 candidate readings"* ]]
  # A line written before provenance existed reads as unknown, not as itself.
  printf '{"id":"old-task","commit":"cafe","title":"old"}\n' >> "$NS/state/completed.json"
  run cli completed-show old-task
  [ "$status" -eq 0 ]
  [ "${lines[3]}" = "$(printf 'branch\t')" ]
  # completed-list stays two TAB-separated fields: radin tui parses it.
  run cli completed-list
  [ "${lines[0]}" = "$(printf 'aa-task\t%s' "$hash")" ]
  # A retry after a partial run must not duplicate or fail.
  run cli task-done aa-task "$hash"
  [ "$status" -eq 0 ]
  [ "$(grep -c aa-task "$NS/state/completed.json")" -eq 1 ]
}

@test "trace falls back to the journal for a failed task" {
  fixture_repo
  branch="$(git -C "$WORK/repo" rev-parse --abbrev-ref HEAD)"
  printf 'aa-task\t1\t\n' | cli steps-init
  cli session-set no no
  cli prepare aa-task > /dev/null
  cli set-status aa-task failed "boom"
  run cli trace aa-task
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "$(printf 'task\taa-task')" ]
  [[ "$output" == *"$(printf 'status\tfailed')"* ]]
  [ "${lines[1]}" = "$(printf 'commit\t')" ]
  [[ "$output" == *"$(printf 'branch\t%s' "$branch")"* ]]
  # And the reverse lookup finds it too: no completion line pairs it with the
  # branch, so `prepare`'s record is what answers.
  run cli trace "$branch"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "$(printf 'task\taa-task')" ]
  [[ "$output" == *"$(printf 'status\tfailed')"* ]]
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

@test "steps-init honours the fourth status field" {
  run cli steps-init <<EOF
a	1
b	2		deferred
EOF
  [ "$status" -eq 0 ]
  run cat "$STEPS"
  [[ "${lines[0]}" == *'"status":"pending"'* ]]
  [[ "${lines[1]}" == *'"status":"deferred"'*'"depends_on":[]'* ]]
  run cli steps-init <<EOF
c	1		wat
EOF
  [ "$status" -ne 0 ]
  [[ "$output" == *"pending|deferred"* ]]
}

@test "set-status preserves the debugged flag" {
  printf '{"id":"a","order":1,"status":"pending","depends_on":[],"attempts":0,"debugged":1,"note":""}\n' > "$STEPS"
  cli set-status a failed boom
  run cat "$STEPS"
  [[ "$output" == *'"debugged":1'* ]]
}

@test "task-next picks, gates on dependencies, and blocks what it skips" {
  fixture_repo
  printf 'aa-task\t1\t\nbb-task\t2\taa-task\ncc-task\t3\t\ndd-task\t4\t\tdeferred\n' | cli steps-init > /dev/null
  run cat "$NS/state/baseline.json"
  [ "$output" = '{"backlog_count":4,"completed_count":0}' ]

  run cli task-next
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "$(printf 'id\taa-task')" ]
  [ "${lines[1]}" = "$(printf 'order\t1')" ]

  # bb-task's dependency failed: blocked with the CLI's own message, skipped,
  # and the next ready task returned in the same call
  cli set-status aa-task failed boom
  run cli task-next
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "$(printf 'blocked\tbb-task\t')"*"which is failed" ]]
  [[ "${lines[0]}" != *"radin-state:"* ]]
  [ "${lines[1]}" = "$(printf 'id\tcc-task')" ]
  [[ "$(cat "$ST")" == *'"id":"bb-task","order":2,"status":"blocked"'* ]]

  # nothing pending left, and a deferred entry is never picked up
  cli set-status bb-task failed boom
  cli set-status cc-task failed boom
  run cli task-next
  [ "$status" -eq 1 ]
}

@test "task-next claims the task and writes the prompt the leaf reads" {
  fixture_repo
  printf 'aa-task\t1\t\n' | cli steps-init > /dev/null
  run cli task-next
  [ "$status" -eq 0 ]
  [ "${lines[2]}" = "$(printf 'kind\texecution')" ]
  [ "${lines[3]}" = "$(printf 'model\tRADIN_MODEL_EXECUTION')" ]
  [ "${lines[4]}" = "$(printf 'prompt\t%s' "$NS/state/prompts/aa-task-execution.md")" ]
  [ "${#lines[@]}" -eq 5 ]
  [[ "$(cat "$NS/state/prompts/aa-task-execution.md")" == *"body"* ]]
  [[ "$(cat "$ST")" == *'"status":"in_progress","depends_on":[],"attempts":1'* ]]

  # a named id re-claims a task already in flight: the debug and clarify retry
  run cli task-next aa-task
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "$(printf 'id\taa-task')" ]
  [[ "$(cat "$ST")" == *'"attempts":2'* ]]
  cli task-next aa-task > /dev/null
  run cli task-next aa-task
  [ "$status" -eq 1 ]
  [[ "${lines[0]}" == "$(printf 'blocked\taa-task\t')"*"MAX_ATTEMPTS"* ]]
}

@test "task-next --plan-first hands out a planning prompt and claims nothing" {
  fixture_repo
  printf 'aa-task\t1\t\n' | cli steps-init > /dev/null
  run cli task-next --plan-first
  [ "$status" -eq 0 ]
  [ "${lines[2]}" = "$(printf 'kind\tplanning')" ]
  [ "${lines[4]}" = "$(printf 'prompt\t%s' "$NS/state/prompts/aa-task-planning.md")" ]
  [[ "$(cat "$ST")" == *'"status":"pending"'* ]]
  printf '# Plan\n' > "$REPO/plan.md"
  (cd "$REPO" && bash "$REPO_ROOT/lib/radin-backlog.sh" add-plan aa-task "$REPO/plan.md")
  run cli task-next --plan-first
  [ "${lines[2]}" = "$(printf 'kind\texecution')" ]
  [[ "$(cat "$ST")" == *'"status":"in_progress"'* ]]
}

@test "task-next blocks an entry the backlog lost and moves on" {
  fixture_repo
  printf 'aa-task\t1\t\nbb-task\t2\t\n' | cli steps-init > /dev/null
  (cd "$REPO" && bash "$REPO_ROOT/lib/radin-backlog.sh" remove aa-task) > /dev/null
  run cli task-next
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "$(printf 'blocked\taa-task\t')"* ]]
  [ "${lines[1]}" = "$(printf 'id\tbb-task')" ]
}

@test "skills task-next drops reach the report without the router carrying them" {
  fixture_repo
  (cd "$REPO" && bash "$REPO_ROOT/lib/radin-backlog.sh" add fix "ee task" --skill /mattpocock-skills:grilling <<<"body") > /dev/null
  printf 'ee-task\t1\t\n' | cli steps-init > /dev/null
  cli task-next > /dev/null
  cli task-next ee-task > /dev/null
  run cli report
  [[ "$output" == *"Skills dropped as unrunnable by a sub-agent"*$'\n'"- ee task — "*"/mattpocock-skills:grilling"* ]]
  [ "$(printf '%s\n' "$output" | grep -c 'ee task — .*grilling')" -eq 1 ]
}

@test "task-done rejects a hash that is not a reachable commit" {
  fixture_repo
  printf 'aa-task\t1\t\n' | cli steps-init > /dev/null
  run cli task-done aa-task deadbeef
  [ "$status" -eq 3 ]
  [[ "$output" == *"is not a commit"* ]]
  git -C "$REPO" checkout -q -b sideshow
  printf 'b\n' > "$REPO/g.txt"
  git -C "$REPO" add g.txt
  git -C "$REPO" commit -qm elsewhere
  side="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" checkout -q -
  run cli task-done aa-task "$side"
  [ "$status" -eq 3 ]
  [[ "$output" == *"is not reachable"* ]]
  # neither attempt recorded anything
  [ ! -s "$NS/state/completed.json" ]
  [[ "$(cat "$ST")" == *'"id":"aa-task"'* ]]
}

@test "task-done validates against the branch prepare recorded" {
  fixture_repo
  printf 'aa-task\t1\t\n' | cli steps-init > /dev/null
  cli session-set no no
  cli prepare aa-task > /dev/null
  # A stale radin/<id> from an abandoned run, without the work commit: the
  # branch prepare recorded is the one that counts.
  git -C "$REPO" branch radin/aa-task
  printf 'work\n' > "$REPO/g.txt"
  git -C "$REPO" add g.txt
  git -C "$REPO" commit -qm work
  hash="$(git -C "$REPO" rev-parse HEAD)"
  run cli task-done aa-task "$hash"
  [ "$status" -eq 0 ]
  base="$(git -C "$REPO" rev-parse --abbrev-ref HEAD)"
  [[ "$(cat "$NS/state/completed.json")" == *"\"branch\":\"$base\""* ]]
}

@test "task-diagnosis labels the task file, and the failure then names it" {
  fixture_repo
  printf 'aa-task\t1\t\nbb-task\t2\t\n' | cli steps-init > /dev/null
  echo "the flag was inverted" | cli task-diagnosis aa-task
  run cat "$NS/backlog/tasks/aa-task.md"
  [[ "$output" == *"**Root cause:** the flag was inverted"* ]]
  # a diagnosis changes no status: the retry's start bumps attempts instead
  [[ "$(cat "$ST")" == *'"id":"aa-task"'*'"status":"pending"'* ]]
  cli task-report aa-task "STATUS: FAILED — boom" > /dev/null
  cli task-report aa-task "STATUS: FAILED — boom" > /dev/null
  [[ "$(cat "$ST")" == *'**Root cause:**'* ]]
}

@test "task-report routes a SUCCESS line to task-done and says continue" {
  fixture_repo
  printf 'aa-task\t1\t\n' | cli steps-init > /dev/null
  hash="$(git -C "$REPO" rev-parse HEAD)"
  run cli task-report aa-task "STATUS: SUCCESS — $hash"
  [ "$status" -eq 0 ]
  [[ "$output" == *"recorded at $hash"* ]]
  [ "${lines[${#lines[@]}-1]}" = "$(printf 'next\tcontinue')" ]
  [[ "$(cat "$NS/state/completed.json")" == *'"id":"aa-task"'* ]]
}

@test "task-report fails an unsupported SUCCESS and a hashless one" {
  fixture_repo
  printf 'aa-task\t1\t\nbb-task\t2\t\n' | cli steps-init > /dev/null
  run cli task-report aa-task "STATUS: SUCCESS — deadbeef"
  [ "$status" -eq 0 ]
  # The first failure of a task is its debug offer, whatever produced it.
  [ "${lines[${#lines[@]}-1]}" = "$(printf 'next\tdebug')" ]
  run cli task-report bb-task "STATUS: SUCCESS — no new commit, nothing to do"
  [ "$status" -eq 0 ]
  [ "${lines[${#lines[@]}-1]}" = "$(printf 'next\tdebug')" ]
  [ ! -s "$NS/state/completed.json" ]
}

@test "task-report offers one debug pass, then fails the task" {
  fixture_repo
  printf 'aa-task\t1\t\n' | cli steps-init > /dev/null
  cli task-next > /dev/null
  run cli task-report aa-task "STATUS: FAILED — the suite broke"
  [ "$status" -eq 0 ]
  [ "${lines[${#lines[@]}-1]}" = "$(printf 'next\tdebug')" ]
  # the debug offer changes nothing but the flag
  [[ "$(cat "$ST")" == *'"status":"in_progress"'*'"attempts":1'*'"debugged":1'* ]]
  run cli task-report aa-task "STATUS: FAILED — the suite broke"
  [ "$status" -eq 0 ]
  [[ "$output" == *"failed: the suite broke."* ]]
  [ "${lines[${#lines[@]}-1]}" = "$(printf 'next\tcontinue')" ]
  [[ "$(cat "$ST")" == *'"status":"failed"'*'"note":"the suite broke"'* ]]
}

@test "task-report hands a BLOCKED line to the clarify route, touching no state" {
  fixture_repo
  printf 'aa-task\t1\t\nbb-task\t2\t\n' | cli steps-init > /dev/null
  run cli task-report aa-task "STATUS: BLOCKED (FACT) — does the SDK retry"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'next\tclarify FACT')" ]
  run cli task-report bb-task "STATUS: BLOCKED (DECISION) — keep or drop the flag"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'next\tclarify DECISION')" ]
  [[ "$(cat "$ST")" == *'"id":"aa-task"'*'"status":"pending"'* ]]
}

@test "task-report stashes a dirty tree before it believes any status" {
  fixture_repo
  printf 'aa-task\t1\t\n' | cli steps-init > /dev/null
  hash="$(git -C "$REPO" rev-parse HEAD)"
  printf 'half done\n' > "$REPO/wip.txt"
  run cli task-report aa-task "STATUS: SUCCESS — $hash"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Task 1 'aa task'"*"reported SUCCESS but left a dirty tree"*"stash@{0}"* ]]
  [ "${lines[${#lines[@]}-1]}" = "$(printf 'next\tcontinue')" ]
  [ ! -s "$NS/state/completed.json" ]
  [ ! -f "$REPO/wip.txt" ]
  [[ "$(cat "$ST")" == *'"status":"failed"'*"stashed as stash@{0}"*"$REPO"* ]]
}

@test "task-report takes --no-status, and refuses a line with no status word" {
  fixture_repo
  printf 'aa-task\t1\t\nbb-task\t2\t\n' | cli steps-init > /dev/null
  run cli task-report aa-task --no-status "I have a question about"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Task 1 'aa task' failed"* ]]
  [ "${lines[${#lines[@]}-1]}" = "$(printf 'next\tcontinue')" ]
  [[ "$(cat "$ST")" == *"last words: I have a question about"* ]]
  run cli task-report bb-task "all done, hope that helps"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no SUCCESS/FAILED/BLOCKED"* ]]
}

@test "recover finishes what it can, and hands back only the commits case" {
  fixture_repo
  printf 'aa-task\t1\t\nbb-task\t2\t\ncc-task\t3\t\ndd-task\t4\t\n' | cli steps-init > /dev/null
  hash="$(git -C "$REPO" rev-parse HEAD)"

  # already recorded: finish the bookkeeping the dead session missed
  printf '{"id":"%s","commit":"%s","title":"%s"}\n' aa-task "$hash" "aa task" >> "$NS/state/completed.json"
  run cli recover aa-task
  [ "$status" -eq 0 ]
  [[ "$output" == *"bookkeeping completed at $hash"* ]]
  [[ "$(cat "$ST")" != *'"id":"aa-task"'* ]]

  # nothing left behind: straight back to pending
  run cli recover bb-task
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing left behind, back to pending"* ]]

  # a dirty tree gets parked first
  printf 'junk\n' > "$REPO/junk.txt"
  run cli recover cc-task
  [ "$status" -eq 0 ]
  [[ "$output" == *"stashed stash@{0}, back to pending"* ]]
  [ ! -f "$REPO/junk.txt" ]
  [[ "$(cat "$ST")" == *'"id":"cc-task"'*'"status":"pending"'* ]]

  # commits on the task branch: only the model can judge them
  base="$(git -C "$REPO" rev-parse --abbrev-ref HEAD)"
  cli session-set no yes
  cli prepare dd-task > /dev/null
  printf 'work\n' > "$REPO/g.txt"
  git -C "$REPO" add g.txt
  git -C "$REPO" commit -qm work
  git -C "$REPO" checkout -q "$base"
  run cli recover dd-task
  [ "$status" -eq 3 ]
  [[ "$output" == *"branch_commit"*"radin/dd-task"* ]] || [[ "$output" == *"radin/dd-task"*"branch_commit"* ]]
  run cli recover-reject dd-task
  [ "$status" -eq 0 ]
  [[ "$output" == *"do not satisfy the task"* ]]
  [[ "$(cat "$ST")" == *'"status":"blocked"'*"radin/dd-task"* ]]
}

@test "report prints every outcome, scoped to this session and to the recorded modes" {
  fixture_repo
  printf 'aa-task\t1\t\nbb-task\t2\t\ncc-task\t3\t\ndd-task\t4\t\tdeferred\n' | cli steps-init > /dev/null
  cli session-set no yes
  hash="$(git -C "$REPO" rev-parse HEAD)"
  cli task-done aa-task "$hash" > /dev/null
  cli set-status bb-task failed "the build broke"
  cli set-status cc-task blocked "which API? Options: a, b"

  run cli report
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 succeeded, 1 failed, 1 awaiting your decision"* ]]
  [[ "$output" == *"- aa task — $hash on radin/aa-task. Merge: git merge radin/aa-task"* ]]
  [[ "$output" == *"Failed (left in the backlog for retry):"$'\n'"- bb task — the build broke"* ]]
  [[ "$output" == *"- cc task — which API? Options: a, b"* ]]
  [[ "$output" == *"Deferred at your request (left in the backlog):"$'\n'"- dd task"* ]]
  [[ "$output" == *"Net-new backlog entries this session: 0"* ]]
  [[ "$output" == *"no residual changes"* ]]

  # both modes no: no branch, no worktree, no merge command. And residual
  # changes are parked, never committed.
  cli session-set no no
  printf 'stray\n' > "$REPO/stray.txt"
  run cli report
  [ "$status" -eq 0 ]
  [[ "$output" == *"- aa task — $hash"* ]]
  [[ "$output" != *"radin/aa-task"* ]]
  [[ "$output" != *"Merge:"* ]]
  [[ "$output" == *"residual changes stashed as stash@{0}"* ]]
  [[ "$output" == *"Stashes created this session:"* ]]
  [ ! -f "$REPO/stray.txt" ]
  [[ "$output" != *"Skills dropped"* ]]
}

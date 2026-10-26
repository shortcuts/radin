#!/usr/bin/env bats
# Exercises lib/radin-state.sh task-done against a real throwaway repo.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  WORK="$(cd "$(mktemp -d)" && pwd -P)"
  P="$WORK/proj"
  git init -q "$P"
  git -C "$P" config user.email t@t
  git -C "$P" config user.name t
  git -C "$P" commit -q --allow-empty -m init
  (cd "$P" && bash "$REPO_ROOT/lib/radin-backlog.sh" add fix "t one" <<<"body")
}

teardown() {
  rm -rf "$WORK"
}

@test "task-done exits 3 for a commit that changes a file under .claude/.radin/" {
  mkdir -p "$P/.claude/.radin/state"
  echo x >"$P/.claude/.radin/state/leak"
  git -C "$P" add -f .claude/.radin/state/leak
  git -C "$P" commit -q -m leak
  run bash -c "cd '$P' && bash '$REPO_ROOT/lib/radin-state.sh' task-done t-one HEAD"
  [ "$status" -eq 3 ]
  [[ "$output" == *".claude/.radin/"* ]]
}

state() { (cd "$P" && bash "$REPO_ROOT/lib/radin-state.sh" "$@"); }

@test "task-fact keeps the evidence token and records the long-form path" {
  state task-fact t-one "STATUS: FOUND — [measured] lib/x.sh sets A=1; long form: /p/state/facts/t-one.md"
  run bash -c "cd '$P' && cat .claude/.radin/backlog/tasks/*t-one.md; bash '$REPO_ROOT/lib/radin-backlog.sh' meta t-one"
  [[ "$output" == *"**Fact:** [measured] lib/x.sh sets A=1"* ]]
  [[ "$output" != *"long form"* ]]
  [[ "$output" == *$'facts\t/p/state/facts/t-one.md'* ]]
}

@test "task-fact labels a tokenless answer a guess, and NOT FOUND exits non-zero" {
  state task-fact t-one "STATUS: FOUND — no token here"
  run bash -c "cd '$P' && cat .claude/.radin/backlog/tasks/*t-one.md"
  [[ "$output" == *"**Fact:** [guess] no token here"* ]]
  run state task-fact t-one "STATUS: NOT FOUND — looked"
  [ "$status" -ne 0 ]
}

@test "task-diagnosis records a Root cause from the DIAGNOSED line; NOT DIAGNOSED exits non-zero" {
  state task-diagnosis t-one "STATUS: DIAGNOSED — [inferred] off by one in f; no siblings"
  run bash -c "cd '$P' && cat .claude/.radin/backlog/tasks/*t-one.md"
  [[ "$output" == *"**Root cause:** [inferred] off by one in f; no siblings"* ]]
  run state task-diagnosis t-one "STATUS: NOT DIAGNOSED — nothing"
  [ "$status" -ne 0 ]
}

@test "steps-waiting prints id<TAB>note for each deferred entry and skips MAX_ATTEMPTS blocks" {
  mkdir -p "$P/.claude/.radin/state"
  cat >"$P/.claude/.radin/state/BACKLOG_STEPS.json" <<'JSON'
{"id":"t-one","order":1,"status":"blocked","depends_on":[],"attempts":1,"debugged":0,"note":"deferred: which db?"}
{"id":"t-two","order":2,"status":"blocked","depends_on":[],"attempts":3,"debugged":0,"note":"MAX_ATTEMPTS: crashed"}
JSON
  run state steps-waiting
  [ "$status" -eq 0 ]
  [ "$output" = $'t-one\tdeferred: which db?' ]
}

@test "preflight prints one tagged line per applicable branch and only empty on an empty backlog" {
  mkdir -p "$P/.claude/.radin/state"
  cat >"$P/.claude/.radin/state/BACKLOG_STEPS.json" <<'JSON'
{"id":"t-one","order":1,"status":"blocked","depends_on":[],"attempts":1,"debugged":0,"note":"deferred: which db?"}
{"id":"t-two","order":2,"status":"in_progress","depends_on":[],"attempts":2,"debugged":0,"note":"dispatched"}
JSON
  run state preflight
  [ "$status" -eq 0 ]
  [[ "$output" == *$'session\tmissing'* ]]
  [[ "$output" == *$'stuck\tt-two\t2\tdispatched'* ]]
  [[ "$output" == *$'waiting\tt-one\tdeferred: which db?'* ]]
  [[ "$output" == *$'rank\tt-one'* ]]
  (cd "$P" && bash "$REPO_ROOT/lib/radin-backlog.sh" remove t-one) || true
  run state preflight
  [ "$status" -eq 0 ]
  [ "$output" = "empty" ]
}

@test "resume moves failed and retryable blocked entries to pending and keeps waiting and MAX_ATTEMPTS blocks" {
  mkdir -p "$P/.claude/.radin/state"
  cat >"$P/.claude/.radin/state/BACKLOG_STEPS.json" <<'JSON'
{"id":"t-one","order":1,"status":"failed","depends_on":[],"attempts":2,"debugged":1,"note":"tests red"}
{"id":"t-two","order":2,"status":"blocked","depends_on":[],"attempts":1,"debugged":0,"note":"crashed"}
{"id":"t-three","order":3,"status":"blocked","depends_on":[],"attempts":1,"debugged":0,"note":"deferred: which db?"}
{"id":"t-four","order":4,"status":"blocked","depends_on":[],"attempts":3,"debugged":0,"note":"dispatched 3 times without finishing (MAX_ATTEMPTS) -- needs a human look"}
JSON
  run state resume
  [ "$status" -eq 0 ]
  [ "$output" = $'t-one\tfailed\nt-two\tblocked' ]
  run state steps-list
  [[ "$output" == *$'t-one\t1\tpending\t2\t\n'* ]]
  [[ "$output" == *$'t-two\t2\tpending\t1\t\n'* ]]
  [[ "$output" == *$'t-three\t3\tblocked\t1\tdeferred: which db?\n'* ]]
  [[ "$output" == *$'t-four\t4\tblocked\t3\t'* ]]
}

@test "an unknown state command lists every subcommand in its usage line, steps-open included" {
  run state no-such-command
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown command: no-such-command"* ]]
  for name in steps-open steps-list steps-waiting answered retry; do
    [[ "$output" == *"$name"* ]]
  done
}

@test "reconcile merges only a done, clean leftover and keeps the rest" {
  base="$(git -C "$P" branch --show-current)"
  for b in a b c; do
    git -C "$P" checkout -q -b "radin/$b" "$base"
    echo "$b" >"$P/$b.txt"
    git -C "$P" add "$b.txt"
    git -C "$P" commit -q -m "feat: $b"
  done
  git -C "$P" checkout -q "$base"
  git -C "$P" worktree add -q "$WORK/wt-c" radin/c
  echo dirt >"$WORK/wt-c/dirt.txt"
  mkdir -p "$P/.claude/.radin/state"
  printf '{"ts":"t","event":"done","id":"a","detail":""}\n{"ts":"t","event":"unproven","id":"b","detail":""}\n{"ts":"t","event":"done","id":"c","detail":""}\n' >"$P/.claude/.radin/state/journal.jsonl"
  run state reconcile
  [ "$status" -eq 0 ]
  [[ "$output" == *$'merged\tradin/a\t'* ]]
  [[ "$output" == *$'skipped\tradin/b\tnot done (unproven)'* ]]
  [[ "$output" == *$'skipped\tradin/c\tdirty'* ]]
  [ -z "$(git -C "$P" branch --list radin/a)" ]
  [ -n "$(git -C "$P" branch --list radin/b)" ]
  [ -n "$(git -C "$P" branch --list radin/c)" ]
  [ -f "$P/a.txt" ]
  run state reconcile
  [[ "$output" != *merged* ]]
}

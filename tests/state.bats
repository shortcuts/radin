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

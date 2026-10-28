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

@test "reconcile lands every leftover branch but a live one and files a follow-up for unfinished work" {
  base="$(git -C "$P" branch --show-current)"
  (cd "$P" && bash "$REPO_ROOT/lib/radin-backlog.sh" add fix "t two" --deps t-one <<<"body" && bash "$REPO_ROOT/lib/radin-backlog.sh" add fix "t three" <<<"body") >/dev/null
  printf 't-one\t1\t\tpending\nt-two\t2\tt-one\tpending\nt-three\t3\t\tpending\n' | state steps-init >/dev/null
  state set-status t-one failed "tests red"
  state set-status t-three in_progress ""
  for b in t-one t-three b c; do
    git -C "$P" checkout -q -b "radin/$b" "$base"
    echo "$b" >"$P/$b.txt"
    git -C "$P" add "$b.txt"
    git -C "$P" commit -q -m "feat: $b"
  done
  git -C "$P" checkout -q "$base"
  git -C "$P" branch radin/e
  git -C "$P" worktree add -q "$WORK/proj-c" radin/c
  git -C "$P" worktree add -q "$WORK/proj-e" radin/e
  echo dirt >"$WORK/proj-c/dirt.txt"
  run state preflight
  [[ "$output" == *leftovers* ]]
  run state reconcile
  [ "$status" -eq 0 ]
  [[ "$output" == *$'merged\tradin/t-one\t'* ]]
  [[ "$output" == *$'merged\tradin/b\t'* ]]
  [[ "$output" == *$'merged\tradin/c\t'* ]]
  [[ "$output" == *$'skipped\tradin/t-three\tin progress'* ]]
  [[ "$output" == *$'removed\tradin/e'* ]]
  for b in t-one b c e; do [ -z "$(git -C "$P" branch --list "radin/$b")" ]; done
  [ -n "$(git -C "$P" branch --list radin/t-three)" ]
  [ ! -d "$WORK/proj-c" ] && [ ! -d "$WORK/proj-e" ]
  [ -f "$P/t-one.txt" ] && [ -f "$P/dirt.txt" ]
  state completed-list | grep -q '^t-one	'
  fu="$(cd "$P" && bash "$REPO_ROOT/lib/radin-backlog.sh" find "Finish: t one" | cut -f1)"
  [ -n "$fu" ]
  run bash -c "cd '$P' && cat \"\$(bash '$REPO_ROOT/lib/radin-backlog.sh' field '$fu' TASK_FILE)\""
  [[ "$output" == *"t-one"* ]] && [[ "$output" == *"tests red"* ]]
  [ "$(cd "$P" && bash "$REPO_ROOT/lib/radin-backlog.sh" find t-two | cut -f6)" = "$fu" ]
  run state reconcile
  [[ "$output" != *merged* ]]
}

@test "a done task whose branch is gone is recorded done once its work is on the base, else its branch comes back and lands" {
  base="$(git -C "$P" branch --show-current)"
  (cd "$P" && bash "$REPO_ROOT/lib/radin-backlog.sh" add fix "t two" <<<"body") >/dev/null
  mkdir -p "$P/.claude/.radin/state/unmerged"
  for t in t-one t-two; do
    git -C "$P" checkout -q -b "radin/$t" "$base"
    echo "$t" >"$P/$t.txt"
    git -C "$P" add "$t.txt"
    git -C "$P" commit -q -m "feat: $t"
    git -C "$P" rev-parse --short=12 HEAD >"$P/.claude/.radin/state/unmerged/$t"
    git -C "$P" checkout -q "$base"
    git -C "$P" branch -q -D "radin/$t"
  done
  # t-one landed under another hash; t-two never landed.
  echo t-one >"$P/t-one.txt"
  git -C "$P" add t-one.txt
  git -C "$P" commit -q -m "feat: t-one again"
  run state reconcile
  [ "$status" -eq 0 ]
  [[ "$output" == *$'adopted\tradin/t-one'* ]]
  [[ "$output" == *$'merged\tradin/t-two\t'* ]]
  [ -f "$P/t-two.txt" ]
  [ "$(state completed-list | cut -f1 | sort | paste -sd, -)" = "t-one,t-two" ]
  run state unlanded
  [ "$status" -eq 1 ]
}

@test "a task done on a side branch stays on the backlog until its merge lands" {
  base="$(git -C "$P" branch --show-current)"
  printf 't-one\t1\t\tpending\n' | state steps-init >/dev/null
  git -C "$P" checkout -q -b radin/t-one
  echo x >"$P/x.txt"
  git -C "$P" add x.txt
  git -C "$P" commit -q -m "feat: x"
  h="$(git -C "$P" rev-parse --short=12 HEAD)"
  git -C "$P" checkout -q "$base"
  mkdir -p "$P/.claude/.radin/state/prepared"
  printf '{"branch":"radin/t-one","worktree":""}\n' >"$P/.claude/.radin/state/prepared/t-one.json"
  run state task-done t-one "$h"
  [ "$status" -eq 0 ]
  [[ "$output" == *unmerged* ]]
  run bash -c "cd '$P' && bash '$REPO_ROOT/lib/radin-backlog.sh' find t-one"
  [ "$status" -eq 0 ]
  run state completed-list
  [ "$status" -ne 0 ]
  run state unlanded
  [[ "$output" == *$'t-one\t'"$h"$'\tradin/t-one\tpending'* ]]
  run state reconcile
  [ "$status" -eq 0 ]
  run state completed-list
  [[ "$output" == t-one$'\t'* ]]
  [ "$(state completed-list | cut -f2)" != "$h" ]
  git -C "$P" merge-base --is-ancestor "$(state completed-list | cut -f2)" "$base"
  run bash -c "cd '$P' && bash '$REPO_ROOT/lib/radin-backlog.sh' find t-one"
  [ "$status" -ne 0 ]
  run state unlanded
  [ "$status" -eq 1 ]
}

@test "a claimed stash is applied in the task's tree and kept; a conflicting one leaves a clean tree" {
  base="$(git -C "$P" branch --show-current)"
  echo one >"$P/a.txt"
  git -C "$P" add a.txt
  git -C "$P" commit -q -m "add a"
  echo "touch a.txt" >>"$(cd "$P" && bash "$REPO_ROOT/lib/radin-backlog.sh" field t-one TASK_FILE)"
  mkdir -p "$P/.claude/.radin/state"
  state session-set yes no
  echo draft >"$P/a.txt"
  echo new >"$P/b.txt"
  git -C "$P" stash push -u -q -m "radin-batch: uncommitted changes found before task other" -- . ':(exclude).claude/.radin'
  h="$(git -C "$P" rev-parse 'stash@{0}')"
  run state stash-triage
  [ "$status" -eq 0 ]
  [[ "$output" == *$'candidate\t'"$h"$'\tt-one'* ]]
  [[ "$output" == *$'left\t1'* ]]
  run state stash-claim "$h" t-one
  [ "$status" -eq 0 ]
  run state stash-claim "$h" t-one
  [ "$status" -ne 0 ]
  [[ "$output" == *"already triaged"* ]]
  run state prepare t-one
  [ "$status" -eq 0 ]
  dir="${lines[${#lines[@]}-1]}"
  [ "$(cat "$dir/a.txt")" = draft ]
  [ "$(git -C "$P" stash list | grep -c .)" -eq 1 ]
  # a second claim whose apply conflicts leaves a clean tree and keeps the stash
  echo other >"$P/a.txt"
  git -C "$P" stash push -q -m "radin-batch: uncommitted changes found before task other" -- . ':(exclude).claude/.radin'
  h2="$(git -C "$P" rev-parse 'stash@{0}')"
  state stash-claim "$h2" t-two
  git -C "$P" worktree add -q "$WORK/proj-t-two" -b radin/t-two "$base"
  echo clash >"$WORK/proj-t-two/a.txt"
  git -C "$WORK/proj-t-two" commit -qam clash
  run state prepare t-two
  [ "$status" -eq 0 ]
  [[ "$output" == *"did not apply"* ]]
  [ -z "$(git -C "$WORK/proj-t-two" status --porcelain)" ]
  [ "$(git -C "$P" stash list | grep -c .)" -eq 2 ]
}

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

@test "task-done exits 3 for a commit that changes a file under .radin/" {
  mkdir -p "$P/.radin/state"
  echo x >"$P/.radin/state/leak"
  git -C "$P" add -f .radin/state/leak
  git -C "$P" commit -q -m leak
  run bash -c "cd '$P' && bash '$REPO_ROOT/lib/radin-state.sh' task-done t-one HEAD"
  [ "$status" -eq 3 ]
  [[ "$output" == *".radin/"* ]]
}

state() { (cd "$P" && bash "$REPO_ROOT/lib/radin-state.sh" "$@"); }

@test "task-fact keeps the evidence token and records the long-form path" {
  state task-fact t-one "STATUS: FOUND — [measured] lib/x.sh sets A=1; long form: /p/state/facts/t-one.md"
  run bash -c "cd '$P' && cat .radin/backlog/tasks/*t-one.md; bash '$REPO_ROOT/lib/radin-backlog.sh' meta t-one"
  [[ "$output" == *"**Fact:** [measured] lib/x.sh sets A=1"* ]]
  [[ "$output" != *"long form"* ]]
  [[ "$output" == *$'facts\t/p/state/facts/t-one.md'* ]]
}

@test "task-fact labels a tokenless answer a guess, and NOT FOUND exits non-zero" {
  state task-fact t-one "STATUS: FOUND — no token here"
  run bash -c "cd '$P' && cat .radin/backlog/tasks/*t-one.md"
  [[ "$output" == *"**Fact:** [guess] no token here"* ]]
  run state task-fact t-one "STATUS: NOT FOUND — looked"
  [ "$status" -ne 0 ]
}

@test "task-diagnosis records a Root cause from the DIAGNOSED line; NOT DIAGNOSED exits non-zero" {
  state task-diagnosis t-one "STATUS: DIAGNOSED — [inferred] off by one in f; no siblings"
  run bash -c "cd '$P' && cat .radin/backlog/tasks/*t-one.md"
  [[ "$output" == *"**Root cause:** [inferred] off by one in f; no siblings"* ]]
  run state task-diagnosis t-one "STATUS: NOT DIAGNOSED — nothing"
  [ "$status" -ne 0 ]
}

@test "steps-waiting prints id<TAB>note for each deferred entry and skips MAX_ATTEMPTS blocks" {
  mkdir -p "$P/.radin/state"
  cat >"$P/.radin/state/BACKLOG_STEPS.json" <<'JSON'
{"id":"t-one","order":1,"status":"blocked","depends_on":[],"attempts":1,"debugged":0,"note":"deferred: which db?"}
{"id":"t-two","order":2,"status":"blocked","depends_on":[],"attempts":3,"debugged":0,"note":"MAX_ATTEMPTS: crashed"}
JSON
  run state steps-waiting
  [ "$status" -eq 0 ]
  [ "$output" = $'t-one\tdeferred: which db?' ]
}

@test "preflight prints one tagged line per applicable branch and only empty on an empty backlog" {
  mkdir -p "$P/.radin/state"
  cat >"$P/.radin/state/BACKLOG_STEPS.json" <<'JSON'
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
  mkdir -p "$P/.radin/state"
  cat >"$P/.radin/state/BACKLOG_STEPS.json" <<'JSON'
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
  mkdir -p "$P/.radin/state/unmerged"
  for t in t-one t-two; do
    git -C "$P" checkout -q -b "radin/$t" "$base"
    echo "$t" >"$P/$t.txt"
    git -C "$P" add "$t.txt"
    git -C "$P" commit -q -m "feat: $t"
    git -C "$P" rev-parse --short=12 HEAD >"$P/.radin/state/unmerged/$t"
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
  # An old date keeps the squash commit's hash from matching "$h" when both land in the same second.
  GIT_AUTHOR_DATE="2020-01-01T00:00:00" GIT_COMMITTER_DATE="2020-01-01T00:00:00" git -C "$P" commit -q -m "feat: x"
  h="$(git -C "$P" rev-parse --short=12 HEAD)"
  git -C "$P" checkout -q "$base"
  mkdir -p "$P/.radin/state/prepared"
  printf '{"branch":"radin/t-one","worktree":""}\n' >"$P/.radin/state/prepared/t-one.json"
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
  mkdir -p "$P/.radin/state"
  state session-set yes no
  echo draft >"$P/a.txt"
  echo new >"$P/b.txt"
  git -C "$P" stash push -u -q -m "radin-batch: uncommitted changes found before task other" -- a.txt b.txt
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
  git -C "$P" stash push -q -m "radin-batch: uncommitted changes found before task other" -- a.txt
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

@test "report prints the unverified line when the session gate never ran" {
  printf 't-one\t1\t\tpending\n' | state steps-init >/dev/null
  run state report
  [ "$status" -eq 0 ]
  [[ "$output" == *"Net-new backlog entries this session: 0. Nothing verified these commits yet"* ]]
}

@test "report says the session gate reviewed the session once gate-done is set" {
  printf 't-one\t1\t\tpending\n' | state steps-init >/dev/null
  state gate-done
  run state report
  [ "$status" -eq 0 ]
  [[ "$output" == *"Net-new backlog entries this session: 0. Reviewed by the session gate."* ]]
  [[ "$output" != *"Nothing verified"* ]]
}

@test "steps-init clears gate-done, so the next session prints the unverified line again" {
  printf 't-one\t1\t\tpending\n' | state steps-init >/dev/null
  state gate-done
  printf 't-one\t1\t\tpending\n' | state steps-init >/dev/null
  run state report
  [[ "$output" == *"Nothing verified these commits yet"* ]]
}

# t-one done on radin/t-one (unmerged); t-two depends on it. Both write shared.txt.
stack_setup() {
  base="$(git -C "$P" branch --show-current)"
  (cd "$P" && bash "$REPO_ROOT/lib/radin-backlog.sh" add fix "t two" --deps t-one <<<"body") >/dev/null
  printf 'one\n' >"$P/shared.txt"
  git -C "$P" add shared.txt
  git -C "$P" commit -q -m "add shared"
  git -C "$P" checkout -q -b radin/t-one
  printf 'one\nfrom-one\n' >"$P/shared.txt"
  git -C "$P" commit -qam "feat: t-one"
  git -C "$P" checkout -q "$base"
  mkdir -p "$P/.radin/state/unmerged"
  git -C "$P" rev-parse --short=12 radin/t-one >"$P/.radin/state/unmerged/t-one"
  printf 't-one\t1\t\tpending\nt-two\t2\tt-one\tpending\n' | state steps-init >/dev/null
  state session-set yes no
}

@test "deps-check resolves an unmerged dependency to its branch tip; two unmerged siblings still block" {
  stack_setup
  run state deps-check t-two
  [ "$status" -eq 0 ]
  [ "$output" = "t-one"$'\t'"$(git -C "$P" rev-parse --short=12 radin/t-one)" ]
  (cd "$P" && bash "$REPO_ROOT/lib/radin-backlog.sh" add fix "t three" <<<"body" &&
    bash "$REPO_ROOT/lib/radin-backlog.sh" add fix "t four" --deps t-one,t-three <<<"body") >/dev/null
  git -C "$P" checkout -q -b radin/t-three "$base"
  git -C "$P" commit -q --allow-empty -m "feat: t-three"
  git -C "$P" checkout -q "$base"
  : >"$P/.radin/state/unmerged/t-three"
  printf 't-one\t1\t\tpending\nt-three\t2\t\tpending\nt-four\t3\tt-one,t-three\tpending\n' | state steps-init >/dev/null
  run state deps-check t-four
  [ "$status" -ne 0 ]
  [[ "$output" == *"waiting on dependency"* ]]
}

@test "prepare starts a dependent on its unmerged dependency's branch and records the stack" {
  stack_setup
  run state prepare t-two
  [ "$status" -eq 0 ]
  dir="${lines[${#lines[@]}-1]}"
  [ "$(git -C "$dir" show HEAD:shared.txt)" = "$(printf 'one\nfrom-one')" ]
  [ "$(cat "$P/.radin/state/stacked/t-two")" = "t-one $(git -C "$P" rev-parse --short=12 radin/t-one)" ]
}

@test "reconcile lands a stack in dependency order, one squash per task, even when both edit the same line" {
  stack_setup
  run state prepare t-two
  dir="${lines[${#lines[@]}-1]}"
  printf 'one\nfrom-two\n' >"$dir/shared.txt"
  git -C "$dir" commit -qam "feat: t-two"
  git -C "$P" rev-parse --short=12 radin/t-two >"$P/.radin/state/unmerged/t-two"
  run state reconcile
  [ "$status" -eq 0 ]
  [[ "$output" == *$'merged\tradin/t-one\t'*$'\n'*$'merged\tradin/t-two\t'* ]]
  [ "$(git -C "$P" log --format=%s "$base" | sed -n '1,2p' | paste -sd, -)" = "feat: t-two,feat: t-one" ]
  [ "$(cat "$P/shared.txt")" = "$(printf 'one\nfrom-two')" ]
  [ "$(state completed-list | cut -f1 | sort | paste -sd, -)" = "t-one,t-two" ]
  [ -z "$(git -C "$P" branch --list 'radin/*')" ]
  [ ! -e "$P/.radin/state/stacked/t-two" ]
}

@test "reconcile leaves a dependent waiting while its parent branch conflicts" {
  stack_setup
  run state prepare t-two
  dir="${lines[${#lines[@]}-1]}"
  echo two >"$dir/two.txt"
  git -C "$dir" add two.txt
  git -C "$dir" commit -qm "feat: t-two"
  git -C "$P" rev-parse --short=12 radin/t-two >"$P/.radin/state/unmerged/t-two"
  printf 'clash\n' >"$P/shared.txt"
  git -C "$P" commit -qam "base clash"
  run state reconcile
  [ "$status" -eq 3 ]
  [[ "$output" == *$'conflict\tradin/t-one'* ]]
  [[ "$output" == *$'skipped\tradin/t-two\twaiting on radin/t-one'* ]]
  [ -n "$(git -C "$P" branch --list radin/t-two)" ]
}

@test "prepare wip-commits a dirty tree while the default .gitignore hides .radin" {
  echo draft >"$P/a.txt"
  run bash -c "cd '$P' && bash '$REPO_ROOT/lib/radin-state.sh' session-set no no && bash '$REPO_ROOT/lib/radin-state.sh' prepare t-one"
  [ "$status" -eq 0 ]
  [ "$(git -C "$P" log -1 --format=%s)" = "wip: update .gitignore, a.txt" ]
  [ -z "$(git -C "$P" status --porcelain)" ]
  [[ "$output" != *"ignored by one of your"* ]]
}

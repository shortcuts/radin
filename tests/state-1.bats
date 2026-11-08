#!/usr/bin/env bats
# Exercises lib/radin-state.sh against a real throwaway repo. One of three shards so the files run side by side.

# The repo every test starts from, built once per file: a copy costs one cp where
# git init, two configs, a commit and a backlog add cost ~10 process spawns.
setup_file() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export SEED_REPO="$BATS_FILE_TMPDIR/proj"
  git init -q "$SEED_REPO"
  git -C "$SEED_REPO" config user.email t@t
  git -C "$SEED_REPO" config user.name t
  git -C "$SEED_REPO" commit -q --allow-empty -m init
  (cd "$SEED_REPO" && bash "$REPO_ROOT/lib/radin-backlog.sh" add fix "t one" <<<"body" >/dev/null)
}

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  WORK="$(cd "$(mktemp -d)" && pwd -P)"
  P="$WORK/proj"
  cp -a "$SEED_REPO" "$P"
  load helpers/isolate
  isolate_env "$WORK/home"
  # Most tests want a wide wave; the cap tests unset it.
  export RADIN_WAVE_CAP=4
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

plan_with() {
  mkdir -p "$P/.radin/plans"
  { printf '# Plan\n\n## Changes\n\n'; for x in "$@"; do printf -- '- `%s` — x\n' "$x"; done; printf '\n## Testing\n\n- [ ] x\n'; } >"$P/.radin/plans/t-one.md"
  (cd "$P" && bash "$REPO_ROOT/lib/radin-backlog.sh" set-meta t-one plan "$P/.radin/plans/t-one.md" >/dev/null)
  printf 't-one\t1\t\tpending\n' | state steps-init >/dev/null
}

commit_files() {
  git -C "$P" add .gitignore && git -C "$P" commit -q -m ignore || true
  for f in "$@"; do mkdir -p "$P/$(dirname "$f")"; echo x >"$P/$f"; done
  git -C "$P" add -- "$@"
  git -C "$P" commit -q -m c
  HASH="$(git -C "$P" rev-parse --short=12 HEAD)"
}

report_success() { state task-report t-one "STATUS: SUCCESS — $HASH; built: x"; }
# The first miss gets a debug pass; the second prints the failure reason.
report_failed() { report_success >/dev/null; report_success; }
TELE() { printf '%s' "$HOME/.radin/telemetry/parallel.jsonl"; }

@test "task-report accepts a commit inside the plan paths" {
  plan_with lib/a.sh
  commit_files lib/a.sh
  run report_success
  [ "$status" -eq 0 ]
  [[ "$output" == *"recorded at $HASH"* ]]
  [ ! -e "$(TELE)" ]
}

@test "task-report fails a commit with a file outside the plan and records out-of-bounds" {
  plan_with lib/a.sh
  commit_files lib/a.sh lib/other.sh
  run report_success
  [ "$status" -eq 0 ]
  [[ "$output" == *"next"*"debug"* ]]
  [ "$(grep -c out-of-bounds "$(TELE)")" -eq 1 ]
  line="$(cat "$(TELE)")"
  [[ "$line" == *'"plan":"lib/a.sh"'* ]]
  [[ "$line" == *'"extra":"lib/other.sh"'* ]]
  run report_success
  [[ "$output" == *"❌ Task 1 't one' failed: commit $HASH changes files outside its plan paths: lib/other.sh (plan: lib/a.sh)"* ]]
}

@test "a directory plan path matches by prefix" {
  plan_with lib/
  commit_files lib/x.sh
  run report_success
  [[ "$output" == *"recorded at"* ]]
}

@test "a directory plan path rejects a sibling name sharing its prefix" {
  plan_with lib/
  commit_files libx.sh
  run report_failed
  [[ "$output" == *"outside its plan paths: libx.sh"* ]]
}

@test "a plan path that is an existing directory without a slash matches by prefix" {
  mkdir -p "$P/lib" && echo x >"$P/lib/old.sh" && git -C "$P" add lib && git -C "$P" commit -q -m old
  plan_with lib
  commit_files lib/new.sh
  run report_success
  [[ "$output" == *"recorded at"* ]]
}

@test "a plan file path does not accept a longer sibling name" {
  plan_with lib/a
  commit_files lib/a lib/ab.sh
  run report_failed
  [[ "$output" == *"outside its plan paths: lib/ab.sh"* ]]
}

@test "a test file outside the plan is exempt" {
  plan_with lib/a.sh
  commit_files lib/a.sh tests/a.bats
  run report_success
  [[ "$output" == *"recorded at"* ]]
}

@test "a commit touching .radin/ still exits through task-done's message" {
  plan_with lib/a.sh
  git -C "$P" add .gitignore && git -C "$P" commit -q -m ignore
  mkdir -p "$P/.radin/state"
  echo x >"$P/.radin/state/leak"
  git -C "$P" add -f .radin/state/leak
  git -C "$P" commit -q -m leak
  HASH="$(git -C "$P" rev-parse --short=12 HEAD)"
  run report_failed
  [[ "$output" == *"changes a file under .radin/"* ]]
  [[ "$output" != *"outside its plan paths"* ]]
}

@test "generated install.sh passes when SHIPPED is in the plan" {
  plan_with SHIPPED
  commit_files SHIPPED install.sh
  run report_success
  [[ "$output" == *"recorded at"* ]]
}

@test "generated install.sh fails when SHIPPED is not in the plan" {
  plan_with lib/a.sh
  commit_files lib/a.sh install.sh
  run report_failed
  [[ "$output" == *"outside its plan paths: install.sh"* ]]
}

@test "generated svg passes with its mmd in the plan" {
  plan_with docs/agents/lifecycle/f.mmd
  commit_files docs/agents/lifecycle/f.mmd docs/agents/lifecycle/f.svg
  run report_success
  [[ "$output" == *"recorded at"* ]]
}

@test "generated svg fails without its mmd in the plan" {
  plan_with lib/a.sh
  commit_files lib/a.sh docs/agents/lifecycle/f.svg
  run report_failed
  [[ "$output" == *"outside its plan paths: docs/agents/lifecycle/f.svg"* ]]
}

@test "a task with no plan paths passes" {
  commit_files lib/any.sh
  printf 't-one\t1\t\tpending\n' | state steps-init >/dev/null
  run report_success
  [[ "$output" == *"recorded at"* ]]
}

@test "a missing telemetry script still fails the task with the reason" {
  cp -R "$REPO_ROOT/lib" "$WORK/lib2"
  rm "$WORK/lib2/radin-telemetry.sh"
  plan_with lib/a.sh
  commit_files lib/other.sh
  run bash -c "cd '$P' && bash '$WORK/lib2/radin-state.sh' task-report t-one 'STATUS: SUCCESS — $HASH; built: x'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"next"*"debug"* ]]
  [ ! -e "$(TELE)" ]
}

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
  for name in steps-open steps-list wave steps-waiting answered retry; do
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
  state group-set t-one t-two
}

prep_dir() { state prepare "$1" 2>/dev/null | tail -n 1; }

# planned <title> <path>...: adds a task whose plan lists the paths under ## Changes.
planned() {
  local title="$1" f
  shift
  (cd "$P" && bash "$REPO_ROOT/lib/radin-backlog.sh" add fix "$title" <<<"body") >/dev/null
  [ "$#" -gt 0 ] || return 0
  f="$WORK/${title// /-}.md"
  { printf '## Changes\n\n'; for p in "$@"; do printf -- '- `%s` — edit\n' "$p"; done; } >"$f"
  (cd "$P" && bash "$REPO_ROOT/lib/radin-backlog.sh" set-meta "$title" plan "$f") >/dev/null
}

wave_wp() { bash -c "cd '$P' && bash '$REPO_ROOT/lib/radin-state.sh' wave | bash '$REPO_ROOT/lib/radin-state.sh' wave-partition $*"; }

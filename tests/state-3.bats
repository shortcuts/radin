#!/usr/bin/env bats
# Exercises lib/radin-state.sh task-done against a real throwaway repo.

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

@test "wave-partition puts tasks with disjoint paths in one group and prints no apart line" {
  planned "w a" lib/a.sh
  planned "w b" lib/b.sh
  planned "w c" docs/c.md
  run bash -c "printf 'w-a\nw-b\nw-c\n' | (cd '$P' && bash '$REPO_ROOT/lib/radin-state.sh' wave-partition)"
  [ "$status" -eq 0 ]
  [ "$output" = $'group\t3\tw-a,w-b,w-c' ]
}

@test "wave-partition keeps a directory apart from a file under it and prints the shared path" {
  planned "w a" lib/x.sh
  planned "w b" lib/
  planned "w c" docs/y.md
  run bash -c "printf 'w-a\nw-b\nw-c\n' | (cd '$P' && bash '$REPO_ROOT/lib/radin-state.sh' wave-partition)"
  [ "$status" -eq 0 ]
  [ "$output" = $'group\t2\tw-a,w-c\ngroup\t1\tw-b\napart\tw-a\tw-b\tlib/x.sh' ]
}

@test "wave-partition does not match a file name by string prefix" {
  mkdir -p "$P/lib/a"
  planned "w a" lib/a
  planned "w b" lib/ab.sh
  planned "w c" lib/a/z.sh
  run bash -c "printf 'w-a\nw-b\nw-c\n' | (cd '$P' && bash '$REPO_ROOT/lib/radin-state.sh' wave-partition)"
  [ "$status" -eq 0 ]
  [ "$output" = $'group\t2\tw-a,w-b\ngroup\t1\tw-c\napart\tw-a\tw-c\tlib/a/z.sh' ]
}

@test "wave-partition makes a task with no plan paths a closed group of 1 and names it" {
  planned "w a" lib/a.sh
  planned "w b"
  planned "w c" lib/c.sh
  run bash -c "printf 'w-a\nw-b\nw-c\n' | (cd '$P' && bash '$REPO_ROOT/lib/radin-state.sh' wave-partition)"
  [ "$status" -eq 0 ]
  [ "$output" = $'group\t2\tw-a,w-c\ngroup\t1\tw-b\nunplanned\tw-b' ]
}

@test "wave-partition splits a wave larger than --cap and rejects a bad cap" {
  for n in 1 2 3 4 5 6; do planned "w $n" "lib/$n.sh"; done
  ids='w-1\nw-2\nw-3\nw-4\nw-5\nw-6\n'
  run bash -c "printf '$ids' | (cd '$P' && bash '$REPO_ROOT/lib/radin-state.sh' wave-partition)"
  [ "$output" = $'group\t4\tw-1,w-2,w-3,w-4\ngroup\t2\tw-5,w-6' ]
  run bash -c "printf '$ids' | (cd '$P' && bash '$REPO_ROOT/lib/radin-state.sh' wave-partition --cap 3)"
  [ "$output" = $'group\t3\tw-1,w-2,w-3\ngroup\t3\tw-4,w-5,w-6' ]
  for bad in 0 x -1; do
    run bash -c "printf '$ids' | (cd '$P' && bash '$REPO_ROOT/lib/radin-state.sh' wave-partition --cap $bad)"
    [ "$status" -eq 1 ]
  done
}

@test "wave-partition exits 1 on empty input, reads the first TAB field, and counts a repeated id once" {
  run bash -c "printf '' | (cd '$P' && bash '$REPO_ROOT/lib/radin-state.sh' wave-partition)"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  planned "w a" lib/a.sh
  planned "w b" lib/b.sh
  run bash -c "printf 'w-a\t1\nw-b\t2\nw-a\t1\n' | (cd '$P' && bash '$REPO_ROOT/lib/radin-state.sh' wave-partition)"
  [ "$status" -eq 0 ]
  [ "$output" = $'group\t2\tw-a,w-b' ]
}

wave_wp() { bash -c "cd '$P' && bash '$REPO_ROOT/lib/radin-state.sh' wave | bash '$REPO_ROOT/lib/radin-state.sh' wave-partition $*"; }

@test "wave into wave-partition --wave puts three independent planned tasks in one group and records no serialization" {
  planned "w a" lib/a.sh
  planned "w b" lib/b.sh
  planned "w c" docs/c.md
  printf 'w-a\t1\t\tpending\nw-b\t2\t\tpending\nw-c\t3\t\tpending\n' | state steps-init >/dev/null
  run wave_wp --wave 1
  [ "$status" -eq 0 ]
  [ "$output" = $'group\t3\tw-a,w-b,w-c' ]
  [ ! -e "$(TELE)" ]
}

@test "wave-partition --wave records one serialized event per shared-path pair" {
  planned "w a" lib/x.sh
  planned "w b" lib/
  run bash -c "printf 'w-a\nw-b\n' | (cd '$P' && bash '$REPO_ROOT/lib/radin-state.sh' wave-partition --wave 2)"
  [ "$status" -eq 0 ]
  [ "$(grep -c serialized "$(TELE)")" -eq 1 ]
  line="$(cat "$(TELE)")"
  [[ "$line" == *'"task":"w-b"'* ]]
  [[ "$line" == *'"with":"w-a"'* ]]
  [[ "$line" == *'"wave":"2"'* ]]
  [[ "$line" == *'"reason":"shared-paths"'* ]]
  [[ "$line" == *'"paths":"lib/x.sh"'* ]]
}

@test "wave-partition --wave records a no-plan event, and none without --wave" {
  planned "w a" lib/a.sh
  planned "w b"
  run bash -c "printf 'w-a\nw-b\n' | (cd '$P' && bash '$REPO_ROOT/lib/radin-state.sh' wave-partition)"
  [ ! -e "$(TELE)" ]
  run bash -c "printf 'w-a\nw-b\n' | (cd '$P' && bash '$REPO_ROOT/lib/radin-state.sh' wave-partition --wave 1)"
  [ "$(grep -c serialized "$(TELE)")" -eq 1 ]
  line="$(cat "$(TELE)")"
  [[ "$line" == *'"task":"w-b"'* ]]
  [[ "$line" == *'"reason":"no-plan"'* ]]
}

@test "wave leaves a task with an unmet dependency out of the partition" {
  planned "w a" lib/a.sh
  planned "w b" lib/b.sh
  printf 'w-a\t1\t\tpending\nw-b\t2\tw-a\tpending\n' | state steps-init >/dev/null
  run wave_wp --wave 1
  [ "$output" = $'group\t1\tw-a' ]
}

@test "wave-partition reads RADIN_WAVE_CAP, --cap beats it, and each cap-split task records a cap event" {
  for n in 1 2 3 4 5 6; do planned "w $n" "lib/$n.sh"; done
  ids='w-1\nw-2\nw-3\nw-4\nw-5\nw-6\n'
  run bash -c "printf '$ids' | (cd '$P' && RADIN_WAVE_CAP=3 bash '$REPO_ROOT/lib/radin-state.sh' wave-partition --wave 1)"
  [ "$output" = $'group\t3\tw-1,w-2,w-3\ngroup\t3\tw-4,w-5,w-6' ]
  [ "$(grep -c '"reason":"cap"' "$(TELE)")" -eq 3 ]
  [[ "$(sed -n 1p "$(TELE)")" == *'"task":"w-4"'* ]]
  run bash -c "printf '$ids' | (cd '$P' && RADIN_WAVE_CAP=3 bash '$REPO_ROOT/lib/radin-state.sh' wave-partition --cap 2)"
  [ "$output" = $'group\t2\tw-1,w-2\ngroup\t2\tw-3,w-4\ngroup\t2\tw-5,w-6' ]
  run bash -c "printf '$ids' | (cd '$P' && RADIN_WAVE_CAP=0 bash '$REPO_ROOT/lib/radin-state.sh' wave-partition)"
  [ "$status" -eq 1 ]
}

@test "wave-partition rejects a bad --wave" {
  planned "w a" lib/a.sh
  run bash -c "printf 'w-a\n' | (cd '$P' && bash '$REPO_ROOT/lib/radin-state.sh' wave-partition --wave 0)"
  [ "$status" -eq 1 ]
}

@test "group-set --wave records a dispatched event; without --wave the event has no wave key" {
  state group-set --wave 2 t-one t-two
  [ "$(cat "$P/.radin/state/groups/t-one")" = 2 ]
  line="$(cat "$(TELE)")"
  [[ "$line" == *'"ids":"t-one,t-two"'* ]]
  [[ "$line" == *'"size":"2"'* ]]
  [[ "$line" == *'"wave":"2"'* ]]
  rm "$(TELE)"
  state group-set t-one
  line="$(cat "$(TELE)")"
  [[ "$line" == *'"size":"1"'* ]]
  [[ "$line" != *'"wave"'* ]]
}

@test "task-next prints no overlap line" {
  plan_with lib/a.sh
  run state task-next
  [ "$status" -eq 0 ]
  [[ "$output" != *overlap* ]]
}

@test "plan-discard drops the plan, flags planning needed, and records the planning tokens" {
  plan_with lib/a.sh
  state task-report t-one "STATUS: PLANNED — ok; complexity low: x" --usage "planning 1234 5 6" >/dev/null
  run state plan-discard t-one 1 lib/a.sh
  [ "$status" -eq 0 ]
  [ "$output" = $'plan-discarded\tt-one\t1\t1234' ]
  run bash -c "cd '$P' && bash '$REPO_ROOT/lib/radin-backlog.sh' meta t-one"
  [[ "$output" == *$'planning\tneeded'* ]]
  [[ "$output" != *$'plan\t'* ]]
  [ "$(grep -c plan-discarded "$(TELE)")" -eq 1 ]
  line="$(cat "$(TELE)")"
  [[ "$line" == *'"task":"t-one"'* ]]
  [[ "$line" == *'"wave":"1"'* ]]
  [[ "$line" == *'"paths":"lib/a.sh"'* ]]
  [[ "$line" == *'"tokens":"1234"'* ]]
  run state task-next
  [[ "$output" == *$'kind\tplanning'* ]]
}

@test "plan-discard records tokens unknown when no planning usage was reported" {
  plan_with lib/a.sh
  state task-report t-one "STATUS: PLANNED — ok; complexity low: x" >/dev/null
  run state plan-discard t-one 1 lib/a.sh
  [ "$status" -eq 0 ]
  [ "$output" = $'plan-discarded\tt-one\t1\tunknown' ]
  [[ "$(cat "$(TELE)")" == *'"tokens":"unknown"'* ]]
}

@test "plan-discard refuses a task that is not pending or has no plan, and writes nothing" {
  plan_with lib/a.sh
  state set-status t-one in_progress "running" >/dev/null
  run state plan-discard t-one 1 lib/a.sh
  [ "$status" -eq 1 ]
  [[ "$output" == *"plan-discard: t-one is not pending"* ]]
  [ ! -e "$(TELE)" ]
  run bash -c "cd '$P' && bash '$REPO_ROOT/lib/radin-backlog.sh' meta t-one"
  [[ "$output" == *$'plan\t'* ]]
  state set-status t-one pending "" >/dev/null
  (cd "$P" && bash "$REPO_ROOT/lib/radin-backlog.sh" set-meta t-one plan --none >/dev/null)
  run state plan-discard t-one 1 lib/a.sh
  [ "$status" -eq 1 ]
  [[ "$output" == *"plan-discard: t-one has no plan"* ]]
  [ ! -e "$(TELE)" ]
}

@test "plan-discard rejects a wave that is not a positive integer and an empty path list" {
  plan_with lib/a.sh
  for args in "0 lib/a.sh" "x lib/a.sh" "1"; do
    run state plan-discard t-one $args
    [ "$status" -eq 1 ]
    [[ "$output" == *"plan-discard: "* ]]
  done
  [ ! -e "$(TELE)" ]
}

@test "plan-discard counts only planning tokens since the previous discard" {
  plan_with lib/a.sh
  state task-report t-one "STATUS: PLANNED — ok; complexity low: x" --usage "planning 100 5 6" >/dev/null
  state plan-discard t-one 1 lib/a.sh >/dev/null
  (cd "$P" && bash "$REPO_ROOT/lib/radin-backlog.sh" set-meta t-one plan "$P/.radin/plans/t-one.md" >/dev/null)
  state task-report t-one "STATUS: PLANNED — ok; complexity low: x" --usage "planning 50 5 6" --usage "execution 9 1 1" >/dev/null
  run state plan-discard t-one 2 lib/a.sh
  [ "$status" -eq 0 ]
  [ "$output" = $'plan-discarded\tt-one\t2\t50' ]
}

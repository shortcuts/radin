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
  state group-set t-one t-two
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
  state group-set t-one t-two
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

@test "wave prints only the pending task whose dependencies are all resolved, exit 0" {
  printf 't-one\t1\t\tpending\nt-two\t2\tt-one\tpending\n' | state steps-init >/dev/null
  run state wave
  [ "$status" -eq 0 ]
  [ "$output" = $'t-one\t1' ]
}

@test "wave prints every independent pending task in order, and reading it twice changes nothing" {
  printf 't-one\t1\t\tpending\nt-two\t2\t\tpending\nt-three\t3\t\tpending\n' | state steps-init >/dev/null
  before="$(state steps-list)"
  run state wave
  first="$output"
  run state wave
  [ "$output" = $'t-one\t1\nt-two\t2\nt-three\t3' ]
  [ "$first" = "$output" ]
  [ "$(state steps-list)" = "$before" ]
}

@test "wave prints at most 2 ready tasks by default, the first by order" {
  unset RADIN_WAVE_CAP
  for i in 1 2 3 4 5 6; do printf 't-%s\t%s\t\tpending\n' "$i" "$i"; done | state steps-init >/dev/null
  run state wave
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[1]}" = $'t-2\t2' ]
  [ "$(state wave-cap)" = 2 ]
}

@test "the wave cap comes from RADIN_WAVE_CAP, else the install manifest, and must be positive" {
  unset RADIN_WAVE_CAP
  for i in 1 2 3 4 5 6; do printf 't-%s\t%s\t\tpending\n' "$i" "$i"; done | state steps-init >/dev/null
  mkdir -p "$HOME/.radin"
  printf '{\n  "wave_cap": 3,\n  "version": "x"\n}\n' >"$HOME/.radin/manifest.json"
  run state wave
  [ "${#lines[@]}" -eq 3 ]
  [ "$(state wave-cap)" = 3 ]
  RADIN_WAVE_CAP=4 run state wave
  [ "${#lines[@]}" -eq 4 ]
  RADIN_WAVE_CAP=0 run state wave
  [ "$status" -ne 0 ]
  RADIN_WAVE_CAP=0 run state wave-cap
  [ "$status" -ne 0 ]
}

@test "wave spawns a few processes per task when completed.json holds hundreds of tasks" {
  for i in $(seq 1 400); do printf '{"id":"done-%s","commit":"abc%s"}\n' "$i" "$i"; done >"$P/.radin/state/completed.json"
  for i in $(seq 1 30); do printf 't-%s\t%s\tdone-%s,done-%s\tpending\n' "$i" "$i" "$((i * 10))" "$((i * 12))"; done | state steps-init >/dev/null
  # Wall time depends on the machine; the count of spawned tools does not. A json_get
  # that forks sed, or a per-dependency git call, shows up here: it was 781 before.
  (cd "$P" && env SHELLOPTS=xtrace BASH_XTRACEFD=9 PS4='+X ' RADIN_WAVE_CAP=30 \
    bash "$REPO_ROOT/lib/radin-state.sh" wave 9>"$WORK/trace" >"$WORK/out" 2>&1)
  [ "$(wc -l <"$WORK/out" | tr -d ' ')" -eq 30 ]
  spawns="$(sed 's/^+*X //' "$WORK/trace" | awk '$1 ~ /^(git|awk|sed|cut|paste|grep|tr|head|sort|bash|date|wc|cat)$/' | wc -l | tr -d ' ')"
  [ "$spawns" -le 130 ]
}

@test "wave counts a done dependency as resolved" {
  printf '{"id":"t-one","commit":"abc123def456"}\n' >"$P/.radin/state/completed.json"
  printf 't-two\t2\tt-one\tpending\n' | state steps-init >/dev/null
  run state wave
  [ "$status" -eq 0 ]
  [ "$output" = $'t-two\t2' ]
}

@test "wave skips a pending task that carries an unmerged marker" {
  stack_setup
  run state wave
  [ "$status" -eq 0 ]
  [ "$output" = $'t-two\t2' ]
}

@test "wave skips deferred, blocked and in_progress tasks" {
  printf 't-one\t1\t\tdeferred\nt-two\t2\t\tpending\nt-three\t3\t\tpending\nt-four\t4\t\tpending\n' | state steps-init >/dev/null
  state set-status t-two blocked "waiting" >/dev/null
  state set-status t-three in_progress >/dev/null
  run state wave
  [ "$status" -eq 0 ]
  [ "$output" = $'t-four\t4' ]
}

@test "wave prints nothing and exits 1 when every pending task waits on an unresolved dependency" {
  printf 't-one\t1\tt-zero\tpending\nt-two\t2\tt-one\tpending\n' | state steps-init >/dev/null
  run state wave
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "prepare starts a dependent on its unmerged dependency's branch and records the stack" {
  stack_setup
  run state prepare t-two
  [ "$status" -eq 0 ]
  dir="${lines[${#lines[@]}-1]}"
  [ "$(git -C "$dir" show HEAD:shared.txt)" = "$(printf 'one\nfrom-one')" ]
  [ "$(cat "$P/.radin/state/stacked/t-two")" = "t-one $(git -C "$P" rev-parse --short=12 radin/t-one)" ]
}

prep_dir() { state prepare "$1" 2>/dev/null | tail -n 1; }

@test "prepare without a recorded group makes no worktree: branch yes cuts radin/<id> in the checkout" {
  state session-set yes yes
  [ "$(prep_dir t-one)" = "$P" ]
  [ "$(git -C "$P" branch --show-current)" = radin/t-one ]
  [ "$(git -C "$P" worktree list | grep -c .)" -eq 1 ]
}

@test "prepare without a recorded group commits to the base when branch is no" {
  before="$(git -C "$P" branch --show-current)"
  state session-set yes no
  [ "$(prep_dir t-one)" = "$P" ]
  [ "$(git -C "$P" branch --show-current)" = "$before" ]
  [ -z "$(git -C "$P" branch --list radin/t-one)" ]
}

@test "prepare makes a worktree for a recorded group of two and group-set writes the size" {
  state session-set yes no
  state group-set t-one t-two
  [ "$(cat "$P/.radin/state/groups/t-one")" = 2 ]
  [ "$(prep_dir t-one)" = "$P-t-one" ]
  [ "$(git -C "$P-t-one" branch --show-current)" = radin/t-one ]
}

@test "prepare makes no worktree for a group when the worktree answer is no" {
  state session-set no yes
  state group-set t-one t-two
  [ "$(prep_dir t-one)" = "$P" ]
  [ "$(git -C "$P" worktree list | grep -c .)" -eq 1 ]
}

@test "prepare reuses the worktree a dead attempt left for a task that runs alone" {
  base="$(git -C "$P" branch --show-current)"
  git -C "$P" worktree add -q "$P-t-one" -b radin/t-one "$base"
  state session-set yes yes
  [ "$(prep_dir t-one)" = "$P-t-one" ]
}

@test "group-set rejects no id and a path character, and steps-init drops recorded groups" {
  run state group-set
  [ "$status" -ne 0 ]
  run state group-set ../x
  [ "$status" -ne 0 ]
  [ ! -e "$P/.radin/state/groups" ]
  state group-set t-one t-two
  [ -e "$P/.radin/state/groups/t-one" ]
  printf 't-one\t1\t\tpending\n' | state steps-init >/dev/null
  [ ! -e "$P/.radin/state/groups" ]
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

wave_wp() { bash -c "cd '$P' && bash '$REPO_ROOT/lib/radin-state.sh' wave | bash '$REPO_ROOT/lib/radin-state.sh' wave-partition $*"; }

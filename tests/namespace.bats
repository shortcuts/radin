#!/usr/bin/env bats
# Exercises lib/radin-namespace.sh: all state lands in <repo-root>/.radin,
# with $PWD taking the repo root's place outside any git repo.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  NS_SCRIPT="$REPO_ROOT/lib/radin-namespace.sh"
  # pwd -P: mktemp on macOS returns a /var/... path that git resolves to
  # /private/var/..., which would break string comparison against its output.
  WORK="$(cd "$(mktemp -d)" && pwd -P)"
}

teardown() {
  rm -rf "$WORK"
}

@test "resolves to <repo-root>/.radin from anywhere inside a git repo" {
  git init -q "$WORK/proj"
  mkdir -p "$WORK/proj/sub"
  run bash -c "cd '$WORK/proj/sub' && bash '$NS_SCRIPT'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"BACKLOG_INDEX=$WORK/proj/.radin/backlog/index.jsonl"* ]]
  [[ "$output" == *"BACKLOG_TASKS_DIR=$WORK/proj/.radin/backlog/tasks"* ]]
  [ -d "$WORK/proj/.radin/state" ]
  [ -d "$WORK/proj/.radin/plans" ]
  [ -d "$WORK/proj/.radin/reviews" ]
  [ -d "$WORK/proj/.radin/backlog/tasks" ]
}

# Each checkout the user works in owns its backlog: their uncommitted edits
# live only there, so a sub-agent sent to another checkout cannot see them.
@test "a user's linked worktree keeps its own namespace" {
  git init -q "$WORK/proj"
  git -C "$WORK/proj" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  mkdir -p "$WORK/proj/.radin"
  git -C "$WORK/proj" worktree add -q "$WORK/proj-wt" -b feature
  run bash -c "cd '$WORK/proj-wt' && bash '$NS_SCRIPT'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"REPO_ROOT=$WORK/proj-wt"$'\n'* ]]
  [[ "$output" == *"BACKLOG_INDEX=$WORK/proj-wt/.radin/backlog/index.jsonl"* ]]
}

# A worktree-mode sub-agent runs in <checkout>-<id> on radin/<id> and must
# reach the backlog of the checkout that prepared it, itself maybe a worktree.
@test "a radin task worktree resolves to the checkout that prepared it" {
  git init -q "$WORK/proj"
  git -C "$WORK/proj" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  git -C "$WORK/proj" worktree add -q "$WORK/proj-wt" -b feature
  mkdir -p "$WORK/proj-wt/.radin"
  git -C "$WORK/proj-wt" worktree add -q "$WORK/proj-wt-fix-a" -b radin/fix-a
  run bash -c "cd '$WORK/proj-wt-fix-a' && bash '$NS_SCRIPT'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"BACKLOG_INDEX=$WORK/proj-wt/.radin/backlog/index.jsonl"* ]]
  [ ! -e "$WORK/proj-wt-fix-a/.claude" ]
}

@test "falls back to \$PWD outside any git repo" {
  mkdir -p "$WORK/plain"
  run bash -c "cd '$WORK/plain' && bash '$NS_SCRIPT'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"BACKLOG_INDEX=$WORK/plain/.radin/backlog/index.jsonl"* ]]
  [ -d "$WORK/plain/.radin/state" ]
}

@test "output stays source-able when the repo path contains spaces" {
  git init -q "$WORK/my proj"
  run bash -c "cd '$WORK/my proj' && source <(bash '$NS_SCRIPT' 2>/dev/null | sed 's/^/export /') && printf '%s' \"\$BACKLOG_INDEX\""
  [ "$status" -eq 0 ]
  [ "$output" = "$WORK/my proj/.radin/backlog/index.jsonl" ]
}

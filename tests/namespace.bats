#!/usr/bin/env bats
# Exercises lib/radin-namespace.sh: all state lands in <repo-root>/.claude/.radin,
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

@test "resolves to <repo-root>/.claude/.radin from anywhere inside a git repo" {
  git init -q "$WORK/proj"
  mkdir -p "$WORK/proj/sub"
  run bash -c "cd '$WORK/proj/sub' && bash '$NS_SCRIPT'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"BACKLOG_INDEX=$WORK/proj/.claude/.radin/backlog/index.jsonl"* ]]
  [[ "$output" == *"BACKLOG_TASKS_DIR=$WORK/proj/.claude/.radin/backlog/tasks"* ]]
  [ -d "$WORK/proj/.claude/.radin/state" ]
  [ -d "$WORK/proj/.claude/.radin/plans" ]
  [ -d "$WORK/proj/.claude/.radin/reviews" ]
  [ -d "$WORK/proj/.claude/.radin/backlog/tasks" ]
}

# A worktree-mode sub-agent runs in <repo>-<id> and must reach the one backlog.
@test "a linked worktree resolves to its main checkout" {
  git init -q "$WORK/proj"
  git -C "$WORK/proj" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  git -C "$WORK/proj" worktree add -q "$WORK/proj-a"
  run bash -c "cd '$WORK/proj-a' && bash '$NS_SCRIPT'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"BACKLOG_INDEX=$WORK/proj/.claude/.radin/backlog/index.jsonl"* ]]
  [ ! -e "$WORK/proj-a/.claude" ]
}

@test "falls back to \$PWD outside any git repo" {
  mkdir -p "$WORK/plain"
  run bash -c "cd '$WORK/plain' && bash '$NS_SCRIPT'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"BACKLOG_INDEX=$WORK/plain/.claude/.radin/backlog/index.jsonl"* ]]
  [ -d "$WORK/plain/.claude/.radin/state" ]
}

@test "output stays source-able when the repo path contains spaces" {
  git init -q "$WORK/my proj"
  run bash -c "cd '$WORK/my proj' && source <(bash '$NS_SCRIPT' | sed 's/^/export /') && printf '%s' \"\$BACKLOG_INDEX\""
  [ "$status" -eq 0 ]
  [ "$output" = "$WORK/my proj/.claude/.radin/backlog/index.jsonl" ]
}

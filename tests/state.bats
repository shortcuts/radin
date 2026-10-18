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

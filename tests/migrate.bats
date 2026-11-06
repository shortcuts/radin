#!/usr/bin/env bats
# Exercises lib/radin-migrate.sh through lib/radin-namespace.sh: legacy per-host
# state directories move into <repo>/.radin, and .gitignore gains .radin/ once.

setup() {
  SRC="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  NS="$SRC/lib/radin-namespace.sh"
  WORK="$(cd "$(mktemp -d)" && pwd -P)"
  export HOME="$WORK/home"
  load helpers/isolate
  isolate_env "$HOME"
  mkdir -p "$HOME" "$WORK/proj"
  cd "$WORK/proj"
  git init -q .
}

teardown() {
  rm -rf "$WORK"
}

seed() { # host id [dep]
  local d=".$1/.radin"
  mkdir -p "$d/backlog/tasks" "$d/plans" "$d/state"
  printf '{"id":"%s","file":"tasks/%s.md","title":"%s task"%s}\n' "$2" "$2" "$1" "${3:+,\"depends_on\":[\"$3\"]}" >>"$d/backlog/index.jsonl"
  echo "$1 body" >"$d/backlog/tasks/$2.md"
  echo "$1 plan" >"$d/plans/$2.md"
}

@test "one legacy directory moves into .radin and the source is renamed" {
  seed claude solo
  run bash "$NS"
  [ "$status" -eq 0 ]
  [[ "$output" == *"NAMESPACE_DIR=$WORK/proj/.radin"* ]]
  [ "$(cat .radin/backlog/tasks/solo.md)" = "claude body" ]
  [ -d .claude/.radin.migrated ]
  [ ! -e .claude/.radin ]
}

@test "two legacy directories merge and a colliding id takes the -agents suffix" {
  seed claude same
  seed claude other
  seed agents same
  seed agents child same
  run bash "$NS"
  [ "$status" -eq 0 ]
  [ "$(grep -c . .radin/backlog/index.jsonl)" -eq 4 ]
  grep -q '"id":"same-agents","file":"tasks/same-agents.md"' .radin/backlog/index.jsonl
  grep -q '"id":"child".*"depends_on":\["same-agents"\]' .radin/backlog/index.jsonl
  [ "$(cat .radin/backlog/tasks/same.md)" = "claude body" ]
  [ "$(cat .radin/backlog/tasks/same-agents.md)" = "agents body" ]
  [ "$(cat .radin/plans/same-agents.md)" = "agents plan" ]
  [ -d .agents/.radin.migrated ]
}

@test "absolute plan paths in the index follow the move" {
  seed claude solo
  printf '{"id":"p","file":"tasks/p.md","plan":["%s/.claude/.radin/plans/p.md"]}\n' "$WORK/proj" >>.claude/.radin/backlog/index.jsonl
  run bash "$NS"
  [ "$status" -eq 0 ]
  grep -q "\"plan\":\[\"$WORK/proj/.radin/plans/p.md\"\]" .radin/backlog/index.jsonl
}

@test "a second run migrates nothing" {
  seed claude solo
  bash "$NS" >/dev/null
  echo late >.claude/.radin.migrated/late
  run bash "$NS"
  [ "$status" -eq 0 ]
  [ ! -e .radin/late ]
}

@test ".gitignore gets .radin/ once, and a deleted line stays deleted" {
  seed claude solo
  printf 'node_modules' >.gitignore
  run bash "$NS"
  [[ "$output" == *"added .radin/ to .gitignore"* ]]
  [ "$(cat .gitignore)" = "$(printf 'node_modules\n.radin/')" ]
  : >.gitignore
  bash "$NS" >/dev/null 2>&1
  [ ! -s .gitignore ]
}

@test "a fresh repo creates .radin and ignores it" {
  run bash "$NS"
  [ "$status" -eq 0 ]
  [ -d .radin/backlog/tasks ]
  [ "$(cat .gitignore)" = ".radin/" ]
}

@test ".gitignore is left alone when a legacy file is tracked, and git records a rename" {
  seed claude solo
  git add -f .claude/.radin
  git -c user.email=t@t -c user.name=t commit -q -m seed
  run bash "$NS"
  [ "$status" -eq 0 ]
  [ ! -e .gitignore ]
  git status --porcelain | grep -q '^R.*\.claude/\.radin'
}

@test ".gitignore is left alone when .radin is already ignored" {
  printf '.radin\n' >.gitignore
  run bash "$NS"
  [ "$status" -eq 0 ]
  [ "$(cat .gitignore)" = ".radin" ]
}

@test "outside git no .gitignore is written" {
  cd "$WORK"
  mkdir plain
  cd plain
  seed claude solo
  run bash "$NS"
  [ "$status" -eq 0 ]
  [ ! -e .gitignore ]
  [ -f .radin/backlog/tasks/solo.md ]
}

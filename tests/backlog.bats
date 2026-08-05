#!/usr/bin/env bats
# Exercises lib/radin-backlog.sh: deterministic backlog operations against
# a JSONL index + one markdown file per task.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  CLI="$REPO_ROOT/lib/radin-backlog.sh"
  WORK="$(cd "$(mktemp -d)" && pwd -P)"
  git init -q "$WORK/proj"
  INDEX="$WORK/proj/.claude/.radin/backlog/index.jsonl"
  TASKS="$WORK/proj/.claude/.radin/backlog/tasks"
}

teardown() {
  rm -rf "$WORK"
}

cli() {
  (cd "$WORK/proj" && bash "$CLI" "$@")
}

@test "add creates an index line and a task file" {
  run cli add fix "broken auth" <<<"Auth times out after 5s."
  [ "$status" -eq 0 ]
  [[ "$output" == *"id: broken-auth"* ]]
  run cat "$INDEX"
  [[ "$output" == *'"id":"broken-auth"'* ]]
  [[ "$output" == *'"category":"fix"'* ]]
  [[ "$output" == *'"title":"broken auth"'* ]]
  run cat "$TASKS/broken-auth.md"
  [[ "$output" == *"Auth times out after 5s."* ]]
}

@test "add dedupes ids from identical titles" {
  cli add fix "dup title" <<<"body 1"
  cli add chore "dup title" <<<"body 2"
  [ -f "$TASKS/dup-title.md" ]
  [ -f "$TASKS/dup-title-2.md" ]
}

@test "add rejects unknown category and empty body" {
  run cli add wat "title" <<<"body"
  [ "$status" -ne 0 ]
  run cli add fix "title" <<<""
  [ "$status" -ne 0 ]
}

@test "list prints id, category, title, file for every task" {
  cli add feat "f thing" <<<"body f"
  cli add fix "b thing" <<<"body b"
  run cli list
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [[ "${lines[0]}" == "f-thing"$'\t'"feat"$'\t'"f thing"$'\t'"tasks/f-thing.md" ]]
  [[ "${lines[1]}" == "b-thing"$'\t'"fix"$'\t'"b thing"$'\t'"tasks/b-thing.md" ]]
}

@test "find matches by exact id first" {
  cli add fix "auth bug" <<<"body a"
  run cli find "auth-bug"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "${lines[0]}" == "auth-bug"* ]]
}

@test "find falls back to exact title, then case-insensitive substring" {
  cli add feat "Add OAuth support" <<<"body"
  run cli find "Add OAuth support"
  [ "${#lines[@]}" -eq 1 ]
  run cli find "oauth"
  [[ "$output" == *"Add OAuth support"* ]]
}

@test "find fails when nothing matches" {
  cli add feat "something" <<<"body"
  run cli find "nope"
  [ "$status" -ne 0 ]
}

@test "add-plan appends the pointer to the task's own file only" {
  cli add feat "planned thing" <<<"the body"
  cli add feat "next thing" <<<"other body"
  run cli add-plan "planned thing" ".claude/.radin/plans/planned-thing.md"
  [ "$status" -eq 0 ]
  run cat "$TASKS/planned-thing.md"
  [[ "$output" == *"the body"* ]]
  [[ "$output" == *"**Plan:** .claude/.radin/plans/planned-thing.md"* ]]
  run cat "$TASKS/next-thing.md"
  [[ "$output" != *"**Plan:**"* ]]
}

@test "remove deletes the task file and its index line" {
  cli add fix "keep me" <<<"body keep"
  cli add fix "drop me" <<<"body drop"
  run cli remove "drop me"
  [ "$status" -eq 0 ]
  [ ! -f "$TASKS/drop-me.md" ]
  [ -f "$TASKS/keep-me.md" ]
  run cat "$INDEX"
  [[ "$output" != *"drop-me"* ]]
  [[ "$output" == *"keep-me"* ]]
}

@test "remove refuses ambiguous titles" {
  cli add fix "dup title" <<<"body 1"
  cli add chore "dup title" <<<"body 2"
  run cli remove "dup"
  [ "$status" -ne 0 ]
  [[ "$output" == *"2 entries"* ]]
}

@test "show renders grouped-by-category markdown from the index and task files" {
  cli add feat "f thing" <<<"body f"
  cli add fix "b thing" <<<"body b"
  run cli show
  [[ "$output" == *"# Backlog"* ]]
  [[ "$output" == *"## feat"* ]]
  [[ "$output" == *"### f thing"* ]]
  [[ "$output" == *"body f"* ]]
  [[ "$output" == *"## fix"* ]]
  [[ "$output" == *"### b thing"* ]]
}

@test "show <category> prints only that section" {
  cli add feat "f thing" <<<"body f"
  cli add fix "b thing" <<<"body b"
  run cli show fix
  [[ "$output" == *"## fix"* ]]
  [[ "$output" == *"b thing"* ]]
  [[ "$output" != *"f thing"* ]]
}

@test "reconcile drops entries whose id is in completed.json, keeps the rest" {
  cli add fix "done task" <<<"body done"
  cli add feat "still open" <<<"body open"
  mkdir -p "$WORK/proj/.claude/.radin/state"
  printf '{"id":"done-task","commit":"abc123"}\n' > "$WORK/proj/.claude/.radin/state/completed.json"
  run cli reconcile "$WORK/proj/.claude/.radin/state/completed.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"done-task"* ]]
  [ ! -f "$TASKS/done-task.md" ]
  [ -f "$TASKS/still-open.md" ]
  run cat "$INDEX"
  [[ "$output" != *"done-task"* ]]
  [[ "$output" == *"still-open"* ]]
}

@test "reconcile is a no-op when completed.json is absent or lists nothing in the backlog" {
  cli add feat "keep me" <<<"body"
  run cli reconcile "$WORK/proj/.claude/.radin/state/completed.json"
  [ "$status" -eq 0 ]
  [ -f "$TASKS/keep-me.md" ]
  mkdir -p "$WORK/proj/.claude/.radin/state"
  printf '{"id":"never-added","commit":"x"}\n' > "$WORK/proj/.claude/.radin/state/completed.json"
  run cli reconcile "$WORK/proj/.claude/.radin/state/completed.json"
  [ "$status" -eq 0 ]
  [ -f "$TASKS/keep-me.md" ]
}

@test "works outside a git repo (PWD fallback)" {
  mkdir -p "$WORK/plain"
  run bash -c "cd '$WORK/plain' && bash '$CLI' add chore 'note' <<<'a note'"
  [ "$status" -eq 0 ]
  [ -s "$WORK/plain/.claude/.radin/backlog/index.jsonl" ]
  [ -s "$WORK/plain/.claude/.radin/backlog/tasks/note.md" ]
}

#!/usr/bin/env bats
# Exercises lib/radin-backlog.sh: deterministic BACKLOG.md operations.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  CLI="$REPO_ROOT/lib/radin-backlog.sh"
  WORK="$(cd "$(mktemp -d)" && pwd -P)"
  git init -q "$WORK/proj"
  BACKLOG="$WORK/proj/.claude/.radin/BACKLOG.md"
}

teardown() {
  rm -rf "$WORK"
}

cli() {
  (cd "$WORK/proj" && bash "$CLI" "$@")
}

@test "add creates file, section, and entry" {
  run cli add fix "broken auth" <<<"Auth times out after 5s."
  [ "$status" -eq 0 ]
  run cat "$BACKLOG"
  [[ "$output" == *"# Backlog"* ]]
  [[ "$output" == *"## fix"* ]]
  [[ "$output" == *"### broken auth"* ]]
  [[ "$output" == *"Auth times out after 5s."* ]]
}

@test "add keeps canonical section order feat -> fix -> chore -> refactor" {
  cli add refactor "restructure x" <<<"body r"
  cli add feat "new thing" <<<"body f"
  cli add fix "bug thing" <<<"body b"
  run awk '/^## /{print substr($0,4)}' "$BACKLOG"
  [ "${lines[0]}" = "feat" ]
  [ "${lines[1]}" = "fix" ]
  [ "${lines[2]}" = "refactor" ]
}

@test "add appends to the end of an existing section" {
  cli add fix "first bug" <<<"body 1"
  cli add fix "second bug" <<<"body 2"
  run awk '/^### /{print substr($0,5)}' "$BACKLOG"
  [ "${lines[0]}" = "first bug" ]
  [ "${lines[1]}" = "second bug" ]
}

@test "add rejects unknown category and empty body" {
  run cli add wat "title" <<<"body"
  [ "$status" -ne 0 ]
  run cli add fix "title" <<<""
  [ "$status" -ne 0 ]
}

@test "list prints every entry span across sections" {
  cli add feat "f thing" <<<"body f"
  cli add fix "b thing" <<<"body b"
  run cli list
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [[ "${lines[0]}" == *"f thing" ]]
  [[ "${lines[1]}" == *"b thing" ]]
}

@test "find prints span lines, exact match wins over substring" {
  cli add fix "auth bug" <<<"body a"
  cli add fix "auth bug in login auth bug flow" <<<"body b"
  run cli find "auth bug"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "${lines[0]}" == *"auth bug" ]]
}

@test "find falls back to case-insensitive substring" {
  cli add feat "Add OAuth support" <<<"body"
  run cli find "oauth"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Add OAuth support"* ]]
}

@test "find fails when nothing matches" {
  cli add feat "something" <<<"body"
  run cli find "nope"
  [ "$status" -ne 0 ]
}

@test "add-plan inserts pointer after the entry body" {
  cli add feat "planned thing" <<<"the body"
  cli add feat "next thing" <<<"other body"
  run cli add-plan "planned thing" ".claude/.radin/plans/planned-thing.md"
  [ "$status" -eq 0 ]
  run grep -n -A1 '^the body' "$BACKLOG"
  [[ "$output" == *"**Plan:** .claude/.radin/plans/planned-thing.md"* ]]
  # pointer sits inside the entry span, before the next heading
  run cli find "planned thing"
  start="${output%%$'\t'*}"
  end="$(printf '%s' "$output" | cut -f2)"
  run sed -n "${start},${end}p" "$BACKLOG"
  [[ "$output" == *"**Plan:**"* ]]
}

@test "remove deletes exactly the entry span" {
  cli add fix "keep me" <<<"body keep"
  cli add fix "drop me" <<<"body drop"
  run cli remove "drop me"
  [ "$status" -eq 0 ]
  run cat "$BACKLOG"
  [[ "$output" == *"keep me"* ]]
  [[ "$output" != *"drop me"* ]]
  [[ "$output" != *"body drop"* ]]
}

@test "remove refuses ambiguous titles" {
  cli add fix "dup title" <<<"body 1"
  cli add chore "dup title" <<<"body 2"
  run cli remove "dup"
  [ "$status" -ne 0 ]
  [[ "$output" == *"2 entries"* ]]
}

@test "show prints one section including its header" {
  cli add feat "f thing" <<<"body f"
  cli add fix "b thing" <<<"body b"
  run cli show fix
  [[ "$output" == *"## fix"* ]]
  [[ "$output" == *"b thing"* ]]
  [[ "$output" != *"f thing"* ]]
}

@test "works outside a git repo (PWD fallback)" {
  mkdir -p "$WORK/plain"
  run bash -c "cd '$WORK/plain' && bash '$CLI' add chore 'note' <<<'a note'"
  [ "$status" -eq 0 ]
  [ -s "$WORK/plain/.claude/.radin/BACKLOG.md" ]
}

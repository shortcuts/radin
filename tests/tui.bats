#!/usr/bin/env bats
# Exercises lib/radin-tui.sh on a real pty: navigation, the mutating keys, and
# the non-terminal guard. Every mutation is asserted on the backlog store,
# never on the drawn frame, so the assertions survive a layout change.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TUI="$REPO_ROOT/lib/radin-tui.sh"
  BACKLOG="$REPO_ROOT/lib/radin-backlog.sh"
  WORK="$(cd "$(mktemp -d)" && pwd -P)"
  git init -q "$WORK/proj"
  INDEX="$WORK/proj/.claude/.radin/backlog/index.jsonl"
  TASKS="$WORK/proj/.claude/.radin/backlog/tasks"
  NS="$WORK/proj/.claude/.radin"
  SCREEN="$WORK/screen.txt"
  # An $EDITOR that types for us: writes a fixed body and exits.
  printf '#!/bin/sh\nprintf "typed body\\n" >"$1"\n' >"$WORK/editor.sh"
  chmod +x "$WORK/editor.sh"
  command -v python3 >/dev/null 2>&1 || skip "python3 needed to drive a pty"
}

teardown() {
  rm -rf "$WORK"
}

seed() {
  (cd "$WORK/proj" && printf 'Auth times out.\n' | bash "$BACKLOG" add fix "broken auth" >/dev/null)
  (cd "$WORK/proj" && printf 'Add dark mode.\n' | bash "$BACKLOG" add feat "dark mode" >/dev/null)
}

snapshot() {
  cp "$INDEX" "$WORK/index.before"
}

unchanged() {
  cmp -s "$INDEX" "$WORK/index.before"
}

bl() {
  (cd "$WORK/proj" && bash "$BACKLOG" "$@")
}

two_epics() {
  bl epic-add aaa-epic <<<"aaa ctx"
  bl epic-add bbb-epic <<<"bbb ctx"
  bl add feat "aaa child" --epic aaa-epic <<<"aaa body" >/dev/null
  bl add feat "bbb child" --epic bbb-epic <<<"bbb body" >/dev/null
}

tui() {
  local keys="$1"
  (cd "$WORK/proj" && EDITOR="$WORK/editor.sh" PAGER=cat \
    python3 "$REPO_ROOT/tests/helpers/pty-run.py" "$SCREEN" "$keys" bash "$TUI")
}

@test "refuses to draw when stdout is not a terminal" {
  cd "$WORK/proj"
  run bash "$TUI" </dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *"interactive terminal"* ]]
}

@test "lists every task and quits on q" {
  seed
  run tui "q"
  [ "$status" -eq 0 ]
  run cat "$SCREEN"
  [[ "$output" == *"dark mode"* ]]
  [[ "$output" == *"broken auth"* ]]
  [[ "$output" == *"2 task(s)"* ]]
}

@test "runs with an empty backlog" {
  run tui "q"
  [ "$status" -eq 0 ]
  run cat "$SCREEN"
  [[ "$output" == *"no tasks"* ]]
}

@test "e opens the task body in EDITOR and keeps the edit" {
  seed
  run tui "e|q"
  [ "$status" -eq 0 ]
  run cat "$TASKS/dark-mode.md"
  [ "$output" = "typed body" ]
}

@test "n creates a task from the category key, title and EDITOR body" {
  run tui "n|x|from tui\r|q"
  [ "$status" -eq 0 ]
  run cat "$INDEX"
  [[ "$output" == *'"id":"from-tui"'* ]]
  [[ "$output" == *'"category":"fix"'* ]]
  run cat "$TASKS/from-tui.md"
  [ "$output" = "typed body" ]
}

@test "n cancels on an unknown category key" {
  run tui "n|z|q"
  [ "$status" -eq 0 ]
  [ ! -s "$INDEX" ]
}

@test "d deletes only after a y confirmation" {
  seed
  run tui "d|n\r|q"
  [ "$status" -eq 0 ]
  [ -f "$TASKS/dark-mode.md" ]
  run tui "d|y\r|q"
  [ "$status" -eq 0 ]
  [ ! -f "$TASKS/dark-mode.md" ]
  run cat "$INDEX"
  [[ "$output" != *'"id":"dark-mode"'* ]]
}

@test "c moves the selected task to the next category" {
  seed
  run tui "c|q"
  [ "$status" -eq 0 ]
  run grep dark-mode "$INDEX"
  [[ "$output" == *'"category":"fix"'* ]]
}

@test "r retitles the selected task without changing its id" {
  seed
  run tui "r|night mode\r|q"
  [ "$status" -eq 0 ]
  run grep dark-mode "$INDEX"
  [[ "$output" == *'"id":"dark-mode"'* ]]
  [[ "$output" == *'"title":"night mode"'* ]]
  [ -f "$TASKS/dark-mode.md" ]
}

@test "/ filters the list by title" {
  seed
  run tui "/|auth\r|q"
  [ "$status" -eq 0 ]
  run cat "$SCREEN"
  [[ "$output" == *"1 task(s)"* ]]
  [[ "$output" == *'filter:"auth"'* ]]
}

@test "j moves the selection down" {
  seed
  run tui "j|q"
  [ "$status" -eq 0 ]
  run cat "$SCREEN"
  [[ "$output" == *"[2/2]"* ]]
}

@test "marks a planned task with P" {
  seed
  (cd "$WORK/proj" && bash "$BACKLOG" add-plan dark-mode "plans/dark-mode.md" >/dev/null)
  run tui "q"
  [ "$status" -eq 0 ]
  run cat "$SCREEN"
  [[ "$output" == *"P feat"* ]]
}

@test "epic children render under their epic header" {
  bl epic-add ui-polish <<<"epic ctx line"
  bl add feat "nested task" --epic ui-polish <<<"body" >/dev/null
  bl add feat "loose task" <<<"body" >/dev/null
  run tui "q"
  [ "$status" -eq 0 ]
  run cat "$SCREEN"
  [[ "$output" == *"epic: ui-polish"* ]]
  [[ "$output" == *"nested task"* ]]
  [[ "$output" == *"loose task"* ]]
}

@test "enter collapses an epic and navigation skips its children" {
  two_epics
  run tui "\r|j|j|e|q"
  [ "$status" -eq 0 ]
  run cat "$TASKS/bbb-epic/bbb-child.md"
  [ "$output" = "typed body" ]
  run cat "$TASKS/aaa-epic/aaa-child.md"
  [ "$output" = "aaa body" ]
}

@test "enter on an epic header edits nothing" {
  two_epics
  snapshot
  run tui "\r|e|q"
  [ "$status" -eq 0 ]
  run cat "$TASKS/aaa-epic/aaa-child.md"
  [ "$output" = "aaa body" ]
  run cat "$TASKS/bbb-epic/bbb-child.md"
  [ "$output" = "bbb body" ]
  unchanged
}

@test "v composes body, epic description, plan and dependency title" {
  bl add feat "dep target" <<<"target body" >/dev/null
  bl epic-add ctx-epic <<<"epic ctx line"
  bl add feat "needs dep" --epic ctx-epic --depends-on dep-target --priority 40 <<<"needs body" >/dev/null
  mkdir -p "$NS/plans"
  printf 'plan body line\n' >"$NS/plans/needs-dep.md"
  bl add-plan needs-dep "$NS/plans/needs-dep.md" >/dev/null
  snapshot
  run tui "j|j|v|q"
  [ "$status" -eq 0 ]
  run cat "$SCREEN"
  [[ "$output" == *"plan body line"* ]]
  [[ "$output" == *"epic ctx line"* ]]
  [[ "$output" == *"priority: 40"* ]]
  [[ "$output" == *"dep-target -- dep target"* ]]
  unchanged
}

@test "Tab shows the Done view from completed.json" {
  seed
  mkdir -p "$NS/state"
  bash "$REPO_ROOT/lib/radin-state.sh" completed-add "$NS/state/completed.json" shipped-thing abc1234
  snapshot
  run tui "\t|q"
  [ "$status" -eq 0 ]
  run cat "$SCREEN"
  [[ "$output" == *"shipped-thing"* ]]
  [[ "$output" == *"abc1234"* ]]
  unchanged
}

@test "the Done view says so when nothing is completed" {
  seed
  run tui "\t|q"
  [ "$status" -eq 0 ]
  run cat "$SCREEN"
  [[ "$output" == *"nothing completed yet"* ]]
}

@test "Tab toggles back to the list" {
  seed
  run tui "\t|\t|d|y\r|q"
  [ "$status" -eq 0 ]
  [ ! -f "$TASKS/dark-mode.md" ]
}

@test "the Done view ignores mutating keys" {
  seed
  snapshot
  run tui "\t|d|y\r|n|x|nope\r|q"
  [ "$status" -eq 0 ]
  unchanged
  [ -f "$TASKS/dark-mode.md" ]
}

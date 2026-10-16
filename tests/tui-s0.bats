#!/usr/bin/env bats
# Exercises lib/radin-tui.c on a real pty: navigation, the mutating keys, and
# the non-terminal guard. Every mutation is asserted on the backlog store,
# never on the drawn frame, so the assertions survive a layout change.

bats_require_minimum_version 1.5.0
load helpers/tui

@test "refuses to draw when stdout is not a terminal" {
  cd "$WORK/proj"
  run "$TUI" </dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *"interactive terminal"* ]]
}

@test "a cancels on an unknown category key" {
  run tui "a|z|q"
  [ "$status" -eq 0 ]
  [ ! -s "$INDEX" ]
}

@test "/ marks matching rows and hides nothing" {
  seed
  run tui "/|auth\r|q"
  [ "$status" -eq 0 ]
  output="$(plain <"$SCREEN")"
  [[ "$output" == *"2 task(s)"* ]]
  [[ "$output" == *'search:"auth"'* ]]
  [[ "$output" == *"dark mode"* ]]
  [[ "$output" == *"broken auth"* ]]
  [[ "$output" =~ \*[[:space:]]+fix ]]
}

@test "an epic's children render as a tree, ungrouped tasks without connectors" {
  bl epic-add ui-polish <<<"epic ctx line"
  bl add feat "first child" <<<"body" >/dev/null
  bl epic-move first-child ui-polish >/dev/null
  bl add feat "second child" <<<"body" >/dev/null
  bl epic-move second-child ui-polish >/dev/null
  bl add feat "third child" <<<"body" >/dev/null
  bl epic-move third-child ui-polish >/dev/null
  bl add feat "loose task" <<<"body" >/dev/null
  run tui "q"
  [ "$status" -eq 0 ]
  output="$(last_frame | grep -c '├── ')"
  [ "$output" = "2" ]
  output="$(last_frame | grep -c '└── ')"
  [ "$output" = "1" ]
  output="$(last_frame | grep 'loose task')"
  [[ "$output" != *"├"* ]]
  [[ "$output" != *"└"* ]]
  run cat "$SCREEN"
  [[ "$output" == *"epic: ui-polish"* ]]
  [[ "$output" == *"first child"* ]]
}

@test "a task key on an epic header reports no task and changes nothing" {
  two_epics
  snapshot
  run tui "d|c|r|p|q"
  [ "$status" -eq 0 ]
  run cat "$SCREEN"
  [[ "$output" == *"no task here"* ]]
  unchanged
}

@test "Tab shows the Done view from completed.json" {
  seed
  mkdir -p "$NS/state"
  printf '{"id":"shipped-thing","commit":"abc1234","title":""}\n' >> "$NS/state/completed.json"
  snapshot
  run tui "\t|q"
  [ "$status" -eq 0 ]
  run cat "$SCREEN"
  [[ "$output" == *"shipped-thing"* ]]
  [[ "$output" == *"abc1234"* ]]
  unchanged
}

@test "Shift-P sorts by priority, Shift-A returns to creation order" {
  seed
  bl set-priority broken-auth 21 >/dev/null
  run tui "P|q"
  [ "$status" -eq 0 ]
  [ "$(row_titles)" = "broken auth dark mode " ]
  run last_frame
  [[ "$output" == *"sort:priority"* ]]
  run tui "P|A|q"
  [ "$status" -eq 0 ]
  [ "$(row_titles)" = "dark mode broken auth " ]
  run last_frame
  [[ "$output" == *"sort:created"* ]]
  # Session-only: a restart is back to creation order whatever was pressed.
  run tui "P|q"
  run tui "q"
  [ "$status" -eq 0 ]
  [ "$(row_titles)" = "dark mode broken auth " ]
  run last_frame
  [[ "$output" == *"sort:created"* ]]
}

@test "E creates the epic and writes DESCRIPTION.md in EDITOR" {
  seed
  run tui "E|ui-polish\r|q"
  [ "$status" -eq 0 ]
  run cat "$TASKS/ui-polish/DESCRIPTION.md"
  [ "$output" = "typed body" ]
}

@test "D offers a task a collapsed epic is hiding" {
  bl epic-add ui-polish <<<"epic ctx"
  bl add feat "nested task" <<<"body" >/dev/null
  bl epic-move nested-task ui-polish >/dev/null
  bl add chore "loose task" <<<"body" >/dev/null
  # Row 1 is the loose task, row 2 the epic header. Collapse it, so the nested
  # task has no row at all, then make it a dependency of the loose task: the
  # candidate list must still hold every task.
  run tui "j|\r|g|D| |\r|q"
  [ "$status" -eq 0 ]
  run grep loose-task "$INDEX"
  [[ "$output" == *'"depends_on":["nested-task"]'* ]]
}

@test "a motion key runs no CLI in either detail view" {
  seed
  planned_body dark-mode dark-mode "plan step one"
  # A lib dir whose radin-backlog.sh logs each call, then runs the real one.
  mkdir "$WORK/lib"
  printf '#!/bin/sh\necho "$*" >>"%s"\nexec bash "%s" "$@"\n' "$WORK/calls" "$BACKLOG" \
    >"$WORK/lib/radin-backlog.sh"
  export RADIN_LIB="$WORK/lib"
  run wide "q"
  [ "$status" -eq 0 ]
  local startup
  startup="$(wc -l <"$WORK/calls")"
  : >"$WORK/calls"
  run wide "j|k|G|g|\x04|\x15|l|j|k|h|q"
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$WORK/calls")" -eq "$startup" ]
}

@test "h and l on an epic header row change nothing" {
  two_epics
  # Row 1 is the aaa-epic header, row 2 its child. The view sticks as the
  # selection moves, so the child shows which view the epic row left behind.
  run wide "l|j|q"
  [ "$status" -eq 0 ]
  run last_frame
  [[ "$output" == *"aaa body"* ]]
  run wide "j|l|k|h|j|q"
  [ "$status" -eq 0 ]
  run last_frame
  [[ "$output" == *"no plan yet"* ]]
}

@test "a tab in the detail does not widen the row" {
  seed
  printf 'X\tY\n' >"$TASKS/dark-mode.md"
  run wide "q"
  [ "$status" -eq 0 ]
  run last_frame
  [[ "$output" == *"X Y"* ]]
  [[ "$output" != *"$(printf 'X\tY')"* ]]
}

@test "enter on a task row does nothing at 120 columns" {
  md_body
  run wide "\r|q"
  [ "$status" -eq 0 ]
  [ "$(last_pos)" = "[1/2]" ]
  run cat "$SCREEN"
  [[ "$output" != *"q/esc close"* ]]
  run head -1 "$TASKS/dark-mode.md"
  [ "$output" = "# Heading" ]
}

@test "an unchanged index neither redraws nor clears the footer message" {
  seed
  export RADIN_TUI_POLL_MS=10
  run tui "R|q"
  [ "$status" -eq 0 ]
  # A poll that reloaded would have repainted the frame without the message.
  run last_frame
  [[ "$output" == *"reloaded"* ]]
}


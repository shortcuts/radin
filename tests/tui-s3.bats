#!/usr/bin/env bats
# Exercises lib/radin-tui.c on a real pty: navigation, the mutating keys, and
# the non-terminal guard. Every mutation is asserted on the backlog store,
# never on the drawn frame, so the assertions survive a layout change.

bats_require_minimum_version 1.5.0
load helpers/tui

@test "a creates a task from the category key, title and EDITOR body" {
  run tui "a|x|from tui\r|q"
  [ "$status" -eq 0 ]
  run cat "$INDEX"
  [[ "$output" == *'"id":"from-tui"'* ]]
  [[ "$output" == *'"category":"fix"'* ]]
  run cat "$TASKS/from-tui.md"
  [ "$output" = "typed body" ]
}

@test "r retitles the selected task without changing its id" {
  seed
  run tui "r|night mode\r|q"
  [ "$status" -eq 0 ]
  run grep dark-mode "$INDEX"
  [[ "$output" == *'"title":"night mode"'* ]]
}

@test "a keypress burst applies every motion and keeps the key after them" {
  seed
  bl add chore "third thing" <<<"third body" >/dev/null
  run tui "jjd|y\r|q"
  [ "$status" -eq 0 ]
  [ ! -f "$TASKS/third-thing.md" ]
  [ -f "$TASKS/dark-mode.md" ]
  [ -f "$TASKS/broken-auth.md" ]
}

@test "e on an epic header edits that epic's DESCRIPTION.md" {
  two_epics
  run tui "e|q"
  [ "$status" -eq 0 ]
  run cat "$TASKS/aaa-epic/DESCRIPTION.md"
  [ "$output" = "typed body" ]
  # The other epic and the children are untouched.
  run cat "$TASKS/bbb-epic/DESCRIPTION.md"
  [ "$output" = "bbb ctx" ]
}

@test "o on an empty backlog reports the failure and does not page" {
  run tui "o|q"
  [ "$status" -eq 0 ]
  run cat "$SCREEN"
  [[ "$output" == *"order failed"* ]]
}

@test "a mutation leaves the row where it was, and a creates at the bottom" {
  seed
  # Raising the second row's priority above the first's reorders nothing.
  run tui "j|p|\r|q"
  [ "$status" -eq 0 ]
  run grep broken-auth "$INDEX"
  [[ "$output" == *'"priority":21'* ]]
  run tui "q"
  [ "$(row_titles)" = "dark mode broken auth " ]
  # And a category change keeps its row too.
  # The trailing j only redraws with an empty footer: a mutation's message
  # names the task, and row_titles reads the whole frame.
  run tui "c|j|q"
  [ "$status" -eq 0 ]
  [ "$(row_titles)" = "dark mode broken auth " ]
  run tui "a|f|later thing\r|j|q"
  [ "$status" -eq 0 ]
  [ "$(row_titles)" = "dark mode broken auth later thing " ]
}

@test "m moves a task into another epic" {
  two_epics
  run tui "j|m|j|j|\r|q"
  [ "$status" -eq 0 ]
  [ -f "$TASKS/bbb-epic/aaa-child.md" ]
  [ ! -f "$TASKS/aaa-epic/aaa-child.md" ]
  run grep aaa-child "$INDEX"
  [[ "$output" == *'"file":"tasks/bbb-epic/aaa-child.md"'* ]]
}

@test "D marks two candidates and writes both dependencies" {
  seed
  bl add chore "slow tests" <<<"tests are slow" >/dev/null
  run tui "G|D| |j| |\r|q"
  [ "$status" -eq 0 ]
  run grep slow-tests "$INDEX"
  # The chooser lists the tasks in the order the list draws them (creation
  # order), because it reads the same loaded arrays; depends_on records the
  # order they were marked in.
  [[ "$output" == *'"depends_on":["dark-mode","broken-auth"]'* ]]
}

@test "the detail view sticks as the selection moves" {
  seed
  planned_body dark-mode dark-mode "first plan text"
  planned_body broken-auth broken-auth "second plan text"
  run wide "l|j|q"
  [ "$status" -eq 0 ]
  run last_frame
  [[ "$output" == *"second plan text"* ]]
  [ "$(last_pos)" = "[2/2]" ]
}

@test "the narrow-terminal overlay switches views with the same keys" {
  seed
  planned_body dark-mode dark-mode "plan step one"
  run tui "\r|l|q|q"
  [ "$status" -eq 0 ]
  output="$(plain <"$SCREEN")"
  [[ "$output" == *"plan step one"* ]]
  [[ "$output" == *"q/esc close"* ]]
}

@test "an over-wide token is cut at the pane's edge and continues on the next row" {
  seed
  # 200 'A' then five two-byte 'é': the é's sit past the first cut, so a width
  # counted in bytes lets the surviving ASCII run five columns past the pane.
  printf '%s%s\n' "$(printf 'A%.0s' $(seq 200))" \
    "$(printf '\303\251%.0s' $(seq 5))" >"$TASKS/dark-mode.md"
  run wide "q"
  [ "$status" -eq 0 ]
  run last_frame
  # 120 columns: the list takes 48, the divider and its padding 2, so the
  # pane is 70 wide.
  [[ "$output" == *"$(printf 'A%.0s' $(seq 70))"* ]]
  [[ "$output" != *"$(printf 'A%.0s' $(seq 71))"* ]]
  # The tail no longer falls past the cut: it wraps onto a following row.
  [[ "$output" == *"$(printf '\303\251%.0s' $(seq 5))"* ]]
}

@test "enter opens the detail overlay below 100 columns and q dismisses it" {
  md_body
  run tui "\r|q|q"
  [ "$status" -eq 0 ]
  output="$(plain <"$SCREEN")"
  [[ "$output" == *"q/esc close"* ]]
  [[ "$output" == *"quoted"* ]]
  run last_frame
  [[ "$output" == *"2 task(s)"* ]]
  # enter is no longer the edit key, so $EDITOR never ran.
  run head -1 "$TASKS/dark-mode.md"
  [ "$output" = "# Heading" ]
}

@test "a refresh keeps the selected task selected when a row above it goes" {
  seed
  bl add feat "third task" <<<"third body" >/dev/null
  # Cursor on row 2 (broken auth), then dark mode disappears under it: the row
  # index it was selected by now points at third task, the id does not.
  outside_editor 'remove dark-mode'
  run tui "j|e|||q"
  [ "$status" -eq 0 ]
  [ "$(last_pos)" = "[1/2]" ]
  run last_frame
  [[ "$output" == *"broken auth"* ]]
}


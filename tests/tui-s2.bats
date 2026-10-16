#!/usr/bin/env bats
# Exercises lib/radin-tui.c on a real pty: navigation, the mutating keys, and
# the non-terminal guard. Every mutation is asserted on the backlog store,
# never on the drawn frame, so the assertions survive a layout change.

bats_require_minimum_version 1.5.0
load helpers/tui

@test "e opens the task body in EDITOR and keeps the edit" {
  seed
  run tui "e|q"
  [ "$status" -eq 0 ]
  run cat "$TASKS/dark-mode.md"
  [ "$output" = "typed body" ]
}

@test "c moves the selected task to the next category" {
  seed
  run tui "c|q"
  [ "$status" -eq 0 ]
  run grep dark-mode "$INDEX"
  [[ "$output" == *'"category":"fix"'* ]]
}

@test "n and N do nothing without an active search, and n creates no task" {
  seed
  snapshot
  run tui "n|N|q"
  [ "$status" -eq 0 ]
  [ "$(last_pos)" = "[1/2]" ]
  run cat "$SCREEN"
  [[ "$output" != *"[2/2]"* ]]
  unchanged
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

@test "o pages the execution order with its dependency overrides" {
  bl add feat "first dep" <<<"a body" >/dev/null
  bl set-priority first-dep 1 >/dev/null
  bl add feat "later blocked" <<<"b body" >/dev/null
  bl set-priority later-blocked 8 >/dev/null
  bl set-deps later-blocked first-dep >/dev/null
  run tui "o|q"
  [ "$status" -eq 0 ]
  run cat "$SCREEN"
  # backlog.bats owns the report's format; this only proves o pages it.
  [[ "$output" == *"dependency override:"* ]]
}

@test "p picks a Fibonacci priority and then clears it" {
  seed
  # The picker lists 21 13 8 5 3 2 1 then the clear entry: enter takes the
  # top value, G jumps to the clear entry. Typed digits are no longer read.
  run tui "p|\r|q"
  [ "$status" -eq 0 ]
  run grep dark-mode "$INDEX"
  [[ "$output" == *'"priority":21'* ]]
  run tui "p|j|\r|q"
  [ "$status" -eq 0 ]
  run grep dark-mode "$INDEX"
  [[ "$output" == *'"priority":13'* ]]
  run tui "p|G|\r|q"
  [ "$status" -eq 0 ]
  run grep dark-mode "$INDEX"
  [[ "$output" != *'"priority"'* ]]
}

@test "a rejected set-deps cycle shows a message and changes nothing" {
  seed
  bl set-deps dark-mode broken-auth >/dev/null
  snapshot
  run tui "j|D| |\r|q"
  [ "$status" -eq 0 ]
  unchanged
  run cat "$SCREEN"
  [[ "$output" == *"cycle"* ]]
}

@test "NO_COLOR disables the priority colours" {
  bl add feat "low one" <<<"low body" >/dev/null
  bl set-priority low-one 1 >/dev/null
  bl add feat "high one" <<<"high body" >/dev/null
  bl set-priority high-one 13 >/dev/null
  export NO_COLOR=1
  run tui "q"
  [ "$status" -eq 0 ]
  run cat -v "$SCREEN"
  [[ "$output" != *"^[[31m"* ]]
  [[ "$output" != *"^[[32m"* ]]
  [[ "$output" != *"^[[33m"* ]]
  [[ "$output" != *"^[[36m"* ]]
}

@test "l or arrow right shows the task's plan, h or arrow left returns to the body" {
  seed
  planned_body dark-mode dark-mode "plan step one"
  run wide "l|q"
  [ "$status" -eq 0 ]
  run last_frame
  [[ "$output" == *"plan step one"* ]]
  [[ "$output" == *"plans/dark-mode.md"* ]]
  [[ "$output" != *"Add dark mode."* ]]
  run wide "l|h|q"
  run last_frame
  [[ "$output" == *"Add dark mode."* ]]
  [[ "$output" != *"plan step one"* ]]
  run wide "\x1b[C|q"
  run last_frame
  [[ "$output" == *"plan step one"* ]]
  run wide "\x1b[C|\x1b[D|q"
  run last_frame
  [[ "$output" == *"Add dark mode."* ]]
  [[ "$output" != *"plan step one"* ]]
}

@test "a plan pointer whose file is gone reads as missing" {
  seed
  planned_body dark-mode dark-mode "plan step one"
  rm "$NS/plans/dark-mode.md"
  run wide "l|q"
  [ "$status" -eq 0 ]
  run last_frame
  [[ "$output" == *"plan file missing"* ]]
}

@test "^d scrolls the detail pane and leaves the selection alone" {
  long_body
  run wide "\x04|q"
  [ "$status" -eq 0 ]
  run last_frame
  [[ "$output" == *"line 20"* ]]
  [[ "$output" != *"line 01"* ]]
  [ "$(last_pos)" = "[1/2]" ]
}

@test "j moves the tree selection and does not scroll the detail" {
  long_body
  awk 'BEGIN{for(i=1;i<=60;i++)printf "auth %02d\n", i}' >"$TASKS/broken-auth.md"
  run wide "\x04|j|q"
  [ "$status" -eq 0 ]
  [ "$(last_pos)" = "[2/2]" ]
  run last_frame
  # The other task's body, from its first line: ^d's offset stays behind.
  [[ "$output" == *"auth 01"* ]]
}

@test "polling drops a task another shell removed" {
  seed
  outside_editor 'remove broken-auth'
  run tui "e|||q"
  [ "$status" -eq 0 ]
  run last_frame
  [[ "$output" != *"broken auth"* ]]
  [[ "$output" == *"1 task(s)"* ]]
}


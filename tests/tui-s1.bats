#!/usr/bin/env bats
# Exercises lib/radin-tui.c on a real pty: navigation, the mutating keys, and
# the non-terminal guard. Every mutation is asserted on the backlog store,
# never on the drawn frame, so the assertions survive a layout change.

bats_require_minimum_version 1.5.0
load helpers/tui

@test "runs with an empty backlog" {
  run tui "q"
  [ "$status" -eq 0 ]
  run cat "$SCREEN"
  [[ "$output" == *"no tasks"* ]]
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

@test "n walks the search matches forwards, N backwards, both wrap" {
  seed
  bl add chore "dark chore" <<<"body" >/dev/null
  run tui "/|dark\r|n|q"
  [ "$status" -eq 0 ]
  [ "$(last_pos)" = "[3/3]" ]
  run tui "/|dark\r|n|n|q"
  [ "$status" -eq 0 ]
  [ "$(last_pos)" = "[1/3]" ]
  run tui "/|dark\r|N|q"
  [ "$status" -eq 0 ]
  [ "$(last_pos)" = "[3/3]" ]
}

@test "a collapsed epic hides its children and keeps its marker" {
  bl epic-add ui-polish <<<"epic ctx line"
  bl add feat "nested task" <<<"body" >/dev/null
  bl epic-move nested-task ui-polish >/dev/null
  run tui "g|\r|q"
  [ "$status" -eq 0 ]
  # Only the last frame: the frames before the collapse still list the child.
  run last_frame
  # No child row is drawn (the preview pane still names the child), and the
  # epic row's collapse marker is still there.
  [[ "$output" != *"└── "* ]]
  [[ "$output" == *"+ epic: ui-polish"* ]]
}

@test "v composes body, epic description, plan and dependency title" {
  bl add feat "dep target" <<<"target body" >/dev/null
  bl epic-add ctx-epic <<<"epic ctx line"
  bl add feat "needs dep" <<<"needs body" >/dev/null
  bl epic-move needs-dep ctx-epic >/dev/null
  bl set-deps needs-dep dep-target >/dev/null
  bl set-priority needs-dep 8 >/dev/null
  write_plan "$NS/plans/needs-dep.md" "plan body line"
  bl add-plan needs-dep "$NS/plans/needs-dep.md" >/dev/null
  snapshot
  run tui "j|j|v|q"
  [ "$status" -eq 0 ]
  run cat "$SCREEN"
  [[ "$output" == *"plan body line"* ]]
  [[ "$output" == *"epic ctx line"* ]]
  [[ "$output" == *"priority: 8"* ]]
  [[ "$output" == *"dep-target -- dep target"* ]]
  unchanged
}

@test "the Done view ignores mutating keys" {
  seed
  snapshot
  run tui "\t|d|y\r|a|x|nope\r|p|9\r|D| |\r|m|\r|E|nope\r|q"
  [ "$status" -eq 0 ]
  unchanged
  [ -f "$TASKS/dark-mode.md" ]
  [ ! -d "$TASKS/nope" ]
}

@test "D clears depends_on when nothing stays marked" {
  seed
  bl set-deps dark-mode broken-auth >/dev/null
  run tui "D| |\r|q"
  [ "$status" -eq 0 ]
  run grep dark-mode "$INDEX"
  [[ "$output" != *'"depends_on"'* ]]
}

@test "E keeps the epic when the editor writes nothing" {
  seed
  export TUI_EDITOR=true
  run tui "E|ui-polish\r|q"
  unset TUI_EDITOR
  [ "$status" -eq 0 ]
  [ -d "$TASKS/ui-polish" ]
  [ -f "$TASKS/ui-polish/DESCRIPTION.md" ]
  [ ! -s "$TASKS/ui-polish/DESCRIPTION.md" ]
}

@test "G scrolls the Done view past one window" {
  seed
  mkdir -p "$NS/state"
  i=1
  while [ "$i" -le 25 ]; do
    printf '{"id":"done-%s","commit":"hash%s","title":""}\n' "$i" "$i" >> "$NS/state/completed.json"
    i=$((i + 1))
  done
  run tui "\t|G|q"
  [ "$status" -eq 0 ]
  run cat "$SCREEN"
  [[ "$output" == *"done-25"* ]]
}

@test "the plan view of an unplanned task says so" {
  seed
  run wide "l|q"
  [ "$status" -eq 0 ]
  run last_frame
  [[ "$output" == *"no plan yet"* ]]
}

@test "no detail pane below 100 columns" {
  md_body
  run tui "q"
  [ "$status" -eq 0 ]
  run last_frame
  [[ "$output" != *"quoted"* ]]
}

@test "a wide glyph in a title does not overflow the list row" {
  seed
  bl add fix "cjk $(printf '\343\201\202%.0s' $(seq 60))" <<<"body" >/dev/null
  # 80 columns: no right pane, so every glyph in the frame is the list row's.
  run tui "q"
  [ "$status" -eq 0 ]
  run last_frame
  # 80 columns cannot hold 41 two-column glyphs, whatever the row's margin is.
  [[ "$output" != *"$(printf '\343\201\202%.0s' $(seq 41))"* ]]
}

@test "polling picks up a task another shell added, with no keypress" {
  seed
  outside_editor 'add feat "from elsewhere"'
  run tui "e|||q"
  [ "$status" -eq 0 ]
  run last_frame
  [[ "$output" == *"from elsewhere"* ]]
  [[ "$output" == *"3 task(s)"* ]]
}


@test "w and b persist the worktree and branch answers" {
  seed
  run tui "w|q"
  [ "$status" -eq 0 ]
  run cat "$NS/state/session.json"
  [ "$output" = '{"worktree":"yes","branch":"no"}' ]
  run tui "b|w|q"
  [ "$status" -eq 0 ]
  run cat "$NS/state/session.json"
  [ "$output" = '{"worktree":"no","branch":"yes"}' ]
}

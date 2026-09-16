#!/usr/bin/env bats
# Exercises lib/radin-tui.c on a real pty: navigation, the mutating keys, and
# the non-terminal guard. Every mutation is asserted on the backlog store,
# never on the drawn frame, so the assertions survive a layout change.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TUI="$REPO_ROOT/lib/radin-tui"
  BACKLOG="$REPO_ROOT/lib/radin-backlog.sh"
  WORK="$(cd "$(mktemp -d)" && pwd -P)"
  # No git init: namespace resolution falls back to PWD, and the TUI always
  # runs with cwd at this directory, so a repo would only cost a fork per test.
  mkdir -p "$WORK/proj"
  INDEX="$WORK/proj/.claude/.radin/backlog/index.jsonl"
  TASKS="$WORK/proj/.claude/.radin/backlog/tasks"
  NS="$WORK/proj/.claude/.radin"
  SCREEN="$WORK/screen.txt"
  # An $EDITOR that types for us: writes a fixed body and exits.
  printf '#!/bin/sh\nprintf "typed body\\n" >"$1"\n' >"$WORK/editor.sh"
  chmod +x "$WORK/editor.sh"
  load helpers/pty
  pty_build || skip "a C compiler is needed to build the pty driver"
  cc_build "$TUI.c" "$TUI" || skip "a C compiler is needed to build the TUI"
}

teardown() {
  rm -rf "$WORK"
}

# The two-task store every test starts from, built once per file: the index
# holds relative paths, so a copy works from any directory. dark mode is added
# first because the list draws creation order, so it is always row 1.
setup_file() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export SEED_TREE="$BATS_FILE_TMPDIR/seed"
  mkdir -p "$SEED_TREE"
  (cd "$SEED_TREE" &&
    printf 'Add dark mode.\n' | bash "$REPO_ROOT/lib/radin-backlog.sh" add feat "dark mode" >/dev/null &&
    printf 'Auth times out.\n' | bash "$REPO_ROOT/lib/radin-backlog.sh" add fix "broken auth" >/dev/null)
}

seed() {
  rm -rf "$WORK/proj/.claude"
  cp -a "$SEED_TREE/.claude" "$WORK/proj/.claude"
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

# Everything the TUI drew after its last screen clear, so an assertion about
# what a keypress removed is not satisfied by an earlier frame.
last_frame() {
  awk 'BEGIN{RS="\033[[]H\033[[]2J"}{f=$0}END{print f}' "$SCREEN"
}

# The last frame's [sel/total] header, so a wrap back to row 1 is not
# confused with the frame the TUI opened on.
last_pos() {
  grep -ao '\[[0-9]*/[0-9]*\]' "$SCREEN" | tail -1
}

two_epics() {
  bl epic-add aaa-epic <<<"aaa ctx"
  bl epic-add bbb-epic <<<"bbb ctx"
  bl add feat "aaa child" --epic aaa-epic <<<"aaa body" >/dev/null
  bl add feat "bbb child" --epic bbb-epic <<<"bbb body" >/dev/null
}

tui() {
  local keys="$1"
  (cd "$WORK/proj" && EDITOR="${TUI_EDITOR:-$WORK/editor.sh}" PAGER=cat \
    "$PTY_RUN" "$SCREEN" "$keys" "$TUI")
}

@test "refuses to draw when stdout is not a terminal" {
  cd "$WORK/proj"
  run "$TUI" </dev/null
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

@test "a creates a task from the category key, title and EDITOR body" {
  run tui "a|x|from tui\r|q"
  [ "$status" -eq 0 ]
  run cat "$INDEX"
  [[ "$output" == *'"id":"from-tui"'* ]]
  [[ "$output" == *'"category":"fix"'* ]]
  run cat "$TASKS/from-tui.md"
  [ "$output" = "typed body" ]
}

@test "a cancels on an unknown category key" {
  run tui "a|z|q"
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

@test "/ marks matching rows and hides nothing" {
  seed
  run tui "/|auth\r|q"
  [ "$status" -eq 0 ]
  run cat "$SCREEN"
  [[ "$output" == *"2 task(s)"* ]]
  [[ "$output" == *'search:"auth"'* ]]
  [[ "$output" == *"dark mode"* ]]
  [[ "$output" == *"broken auth"* ]]
  [[ "$output" =~ \*[[:space:]]+fix ]]
}

@test "n walks the search matches and wraps at the end" {
  seed
  bl add chore "dark chore" <<<"body" >/dev/null
  run tui "/|dark\r|n|q"
  [ "$status" -eq 0 ]
  [ "$(last_pos)" = "[3/3]" ]
  run tui "/|dark\r|n|n|q"
  [ "$status" -eq 0 ]
  [ "$(last_pos)" = "[1/3]" ]
}

@test "N walks the search matches backwards and wraps at the start" {
  seed
  bl add chore "dark chore" <<<"body" >/dev/null
  run tui "/|dark\r|N|q"
  [ "$status" -eq 0 ]
  [ "$(last_pos)" = "[3/3]" ]
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

@test "g and G select the first and last row" {
  seed
  run tui "G|q"
  [ "$status" -eq 0 ]
  [ "$(last_pos)" = "[2/2]" ]
  run tui "G|g|q"
  [ "$status" -eq 0 ]
  [ "$(last_pos)" = "[1/2]" ]
}

@test "j moves the selection down" {
  seed
  run tui "j|q"
  [ "$status" -eq 0 ]
  run cat "$SCREEN"
  [[ "$output" == *"[2/2]"* ]]
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

@test "marks a planned task with P" {
  seed
  (cd "$WORK/proj" && bash "$BACKLOG" add-plan dark-mode "plans/dark-mode.md" >/dev/null)
  run tui "q"
  [ "$status" -eq 0 ]
  run cat "$SCREEN"
  [[ "$output" =~ P[[:space:]]+feat ]]
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

@test "an epic's children render as a tree, ungrouped tasks without connectors" {
  bl epic-add ui-polish <<<"epic ctx line"
  bl add feat "first child" --epic ui-polish <<<"body" >/dev/null
  bl add feat "second child" --epic ui-polish <<<"body" >/dev/null
  bl add feat "third child" --epic ui-polish <<<"body" >/dev/null
  bl add feat "loose task" <<<"body" >/dev/null
  run tui "q"
  [ "$status" -eq 0 ]
  run bash -c "grep -c '├── ' '$SCREEN'"
  [ "$output" = "2" ]
  run bash -c "grep -c '└── ' '$SCREEN'"
  [ "$output" = "1" ]
  run bash -c "grep 'loose task' '$SCREEN'"
  [[ "$output" != *"├"* ]]
  [[ "$output" != *"└"* ]]
}

@test "a collapsed epic hides its children and keeps its marker" {
  bl epic-add ui-polish <<<"epic ctx line"
  bl add feat "nested task" --epic ui-polish <<<"body" >/dev/null
  run tui "g|\r|q"
  [ "$status" -eq 0 ]
  # Only the last frame: the frames before the collapse still list the child.
  run last_frame
  # No child row is drawn (the preview pane still names the child), and the
  # epic row's collapse marker is still there.
  [[ "$output" != *"└── "* ]]
  [[ "$output" == *"+ epic: ui-polish"* ]]
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

@test "a task key on an epic header reports no task and changes nothing" {
  two_epics
  snapshot
  run tui "d|c|r|p|q"
  [ "$status" -eq 0 ]
  run cat "$SCREEN"
  [[ "$output" == *"no task here"* ]]
  unchanged
}

@test "v composes body, epic description, plan and dependency title" {
  bl add feat "dep target" <<<"target body" >/dev/null
  bl epic-add ctx-epic <<<"epic ctx line"
  bl add feat "needs dep" --epic ctx-epic --depends-on dep-target --priority 8 <<<"needs body" >/dev/null
  mkdir -p "$NS/plans"
  printf 'plan body line\n' >"$NS/plans/needs-dep.md"
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

@test "o pages the execution order with its dependency overrides" {
  bl add feat "first dep" --priority 1 <<<"a body" >/dev/null
  bl add feat "later blocked" --priority 8 --depends-on first-dep <<<"b body" >/dev/null
  snapshot
  run tui "o|q"
  [ "$status" -eq 0 ]
  run cat "$SCREEN"
  [[ "$output" == *"1. first dep (id: first-dep)"* ]]
  [[ "$output" == *"dependency override: first-dep moved above later-blocked (priority 8)"* ]]
  unchanged
}

@test "o on an empty backlog reports the failure and does not page" {
  run tui "o|q"
  [ "$status" -eq 0 ]
  run cat "$SCREEN"
  [[ "$output" == *"order failed"* ]]
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



@test "the Done view ignores mutating keys" {
  seed
  snapshot
  run tui "\t|d|y\r|a|x|nope\r|p|9\r|D| |\r|m|\r|E|nope\r|q"
  [ "$status" -eq 0 ]
  unchanged
  [ -f "$TASKS/dark-mode.md" ]
  [ ! -d "$TASKS/nope" ]
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


# The task titles in the order the last frame drew them.
row_titles() {
  last_frame | grep -oE 'dark mode|broken auth|later thing' | tr '\n' ' '
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

@test "D clears depends_on when nothing stays marked" {
  seed
  bl set-deps dark-mode broken-auth >/dev/null
  run tui "D| |\r|q"
  [ "$status" -eq 0 ]
  run grep dark-mode "$INDEX"
  [[ "$output" != *'"depends_on"'* ]]
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

@test "m moves a task into another epic" {
  two_epics
  run tui "j|m|j|j|\r|q"
  [ "$status" -eq 0 ]
  [ -f "$TASKS/bbb-epic/aaa-child.md" ]
  [ ! -f "$TASKS/aaa-epic/aaa-child.md" ]
  run grep aaa-child "$INDEX"
  [[ "$output" == *'"file":"tasks/bbb-epic/aaa-child.md"'* ]]
}


@test "E creates the epic and writes DESCRIPTION.md in EDITOR" {
  seed
  run tui "E|ui-polish\r|q"
  [ "$status" -eq 0 ]
  run cat "$TASKS/ui-polish/DESCRIPTION.md"
  [ "$output" = "typed body" ]
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


@test "the priority column is coloured by the fixed Fibonacci map" {
  bl add feat "low one" --priority 3 <<<"low body" >/dev/null
  bl add feat "mid one" --priority 8 <<<"mid body" >/dev/null
  bl add feat "high one" --priority 21 <<<"high body" >/dev/null
  run tui "q"
  [ "$status" -eq 0 ]
  run cat -v "$SCREEN"
  [[ "$output" == *"^[[31m21^[[0m"* ]]
  [[ "$output" == *"^[[33m8 ^[[0m"* ]]
  [[ "$output" == *"^[[32m3 ^[[0m"* ]]
  # Only the cell is painted: one red escape on the frame, and the title that
  # follows the reset is not inside it.
  run bash -c "cat -v '$SCREEN' | grep -c '\\^\\[\\[31m'"
  [ "$output" -eq 1 ]
}

@test "a task with no priority gets an empty cell and no escape codes" {
  bl add feat "high one" --priority 21 <<<"high body" >/dev/null
  bl add feat "no prio" <<<"none body" >/dev/null
  run tui "q"
  [ "$status" -eq 0 ]
  run bash -c "cat -v '$SCREEN' | grep 'no prio'"
  [ "$status" -eq 0 ]
  [[ "$output" != *"^[["* ]]
}

@test "an off-scale legacy priority renders uncoloured" {
  bl add feat "legacy one" --priority 21 <<<"legacy body" >/dev/null
  bl add feat "high one" --priority 21 <<<"high body" >/dev/null
  # 70 is off the bounded scale, so only a pre-scale index can carry it.
  sed '/legacy-one/s/"priority":21/"priority":70/' "$INDEX" >"$INDEX.new"
  mv "$INDEX.new" "$INDEX"
  grep -q '"priority":70' "$INDEX"
  run tui "q"
  [ "$status" -eq 0 ]
  run bash -c "cat -v '$SCREEN' | grep 'legacy one'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"70"* ]]
  [[ "$output" != *"^[[31m"* ]]
}

@test "an epic child keeps its priority colour, the epic header is cyan" {
  bl epic-add ui-polish <<<"ctx"
  bl add feat "low one" --priority 3 <<<"low body" >/dev/null
  bl add feat "high child" --epic ui-polish --priority 21 <<<"high body" >/dev/null
  run tui "q"
  [ "$status" -eq 0 ]
  run cat -v "$SCREEN"
  [[ "$output" == *"^[[31m21^[[0m"* ]]
  run bash -c "cat -v '$SCREEN' | grep 'epic: ui-polish'"
  [ "$status" -eq 0 ]
  # Cyan is the structural colour, so a header can never read as a priority.
  [[ "$output" == *"^[[36m"* ]]
  [[ "$output" != *"^[[31m"* ]]
}

@test "NO_COLOR disables the priority colours" {
  bl add feat "low one" --priority 1 <<<"low body" >/dev/null
  bl add feat "high one" --priority 13 <<<"high body" >/dev/null
  export NO_COLOR=1
  run tui "q"
  [ "$status" -eq 0 ]
  run cat -v "$SCREEN"
  [[ "$output" != *"^[[31m"* ]]
  [[ "$output" != *"^[[32m"* ]]
  [[ "$output" != *"^[[33m"* ]]
  [[ "$output" != *"^[[36m"* ]]
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

@test "D offers a task a collapsed epic is hiding" {
  bl epic-add ui-polish <<<"epic ctx"
  bl add feat "nested task" --epic ui-polish <<<"body" >/dev/null
  bl add chore "loose task" <<<"body" >/dev/null
  # Row 1 is the loose task, row 2 the epic header. Collapse it, so the nested
  # task has no row at all, then make it a dependency of the loose task: the
  # candidate list must still hold every task.
  run tui "j|\r|g|D| |\r|q"
  [ "$status" -eq 0 ]
  run grep loose-task "$INDEX"
  [[ "$output" == *'"depends_on":["nested-task"]'* ]]
}

@test "G scrolls the Done view past one window" {
  seed
  mkdir -p "$NS/state"
  i=1
  while [ "$i" -le 25 ]; do
    bash "$REPO_ROOT/lib/radin-state.sh" completed-add "$NS/state/completed.json" "done-$i" "hash$i"
    i=$((i + 1))
  done
  run tui "\t|G|q"
  [ "$status" -eq 0 ]
  run cat "$SCREEN"
  [[ "$output" == *"done-25"* ]]
}


# --- the split detail pane ---

# 120 columns: wide enough for the TUI to draw its right-hand detail pane.
wide() {
  (cd "$WORK/proj" && EDITOR="${TUI_EDITOR:-$WORK/editor.sh}" PAGER=cat \
    PTY_COLS=120 "$PTY_RUN" "$SCREEN" "$1" "$TUI")
}

# The selected row is dark mode (row 1 in creation order), so these two
# rewrite dark-mode's body.
md_body() {
  seed
  printf '# Heading\n\n> quoted\n\n- item\n\n**bold** text\n' >"$TASKS/dark-mode.md"
}

long_body() {
  seed
  awk 'BEGIN{for(i=1;i<=60;i++)printf "line %02d\n", i}' >"$TASKS/dark-mode.md"
}

@test "the detail pane renders markdown beside the tree at 120 columns" {
  md_body
  run wide "q"
  [ "$status" -eq 0 ]
  run last_frame
  [[ "$output" == *"Heading"* ]]
  [[ "$output" == *"quoted"* ]]
  [[ "$output" == *"item"* ]]
  [[ "$output" == *"bold text"* ]]
  [[ "$output" != *"# Heading"* ]]
  [[ "$output" != *"> quoted"* ]]
  [[ "$output" != *"**bold**"* ]]
}

@test "the detail pane is fenced by a divider and a rule under the metadata" {
  md_body
  run wide "q"
  [ "$status" -eq 0 ]
  run last_frame
  [[ "$output" == *"feat · dark-mode · priority unset"* ]]
  [[ "$output" == *"│"* ]]
  [[ "$output" == *"───"* ]]
}

@test "no detail pane below 100 columns" {
  md_body
  run tui "q"
  [ "$status" -eq 0 ]
  run last_frame
  [[ "$output" != *"quoted"* ]]
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
  run wide "j|q"
  [ "$status" -eq 0 ]
  [ "$(last_pos)" = "[2/2]" ]
  run last_frame
  # The other task's body, from its first line: the pane rebuilt from the top.
  [[ "$output" == *"Auth times out."* ]]
}

@test "enter opens the detail overlay below 100 columns and q dismisses it" {
  md_body
  run tui "\r|q|q"
  [ "$status" -eq 0 ]
  run cat "$SCREEN"
  [[ "$output" == *"q/esc close"* ]]
  [[ "$output" == *"quoted"* ]]
  run last_frame
  [[ "$output" == *"2 task(s)"* ]]
  # enter is no longer the edit key, so $EDITOR never ran.
  run head -1 "$TASKS/dark-mode.md"
  [ "$output" = "# Heading" ]
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

# ---------- polling index.jsonl ----------

# The external write runs from inside $EDITOR: the TUI is parked in a key
# handler, so the write lands with no keypress left to process, and the frame
# after it can only come from the poll. RADIN_TUI_POLL_MS shortens the 5s
# interval so the suite does not sit one out. The two empty key chunks are the
# wait: an empty chunk writes nothing and pumps the pty until it sees output,
# so the first absorbs $EDITOR's own repaint and the second waits out the poll
# interval for the refresh frame -- no fixed sleep, and no 5s test.
outside_editor() {
  printf '#!/bin/sh\nprintf "typed body\\n" >"$1"\ncd %s && printf "x\\n" | bash %s %s >/dev/null 2>&1\n' \
    "$WORK/proj" "$BACKLOG" "$1" >"$WORK/outside.sh"
  chmod +x "$WORK/outside.sh"
  export TUI_EDITOR="$WORK/outside.sh"
  export RADIN_TUI_POLL_MS=10
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

@test "polling drops a task another shell removed" {
  seed
  outside_editor 'remove broken-auth'
  run tui "e|||q"
  [ "$status" -eq 0 ]
  run last_frame
  [[ "$output" != *"broken auth"* ]]
  [[ "$output" == *"1 task(s)"* ]]
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

@test "an unchanged index neither redraws nor clears the footer message" {
  seed
  export RADIN_TUI_POLL_MS=10
  run tui "R|q"
  [ "$status" -eq 0 ]
  # A poll that reloaded would have repainted the frame without the message.
  run last_frame
  [[ "$output" == *"reloaded"* ]]
}

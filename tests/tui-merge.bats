#!/usr/bin/env bats
# lib/radin-tui.c --merge on a real pty: both backlogs read as one read-only
# list, one backlog keeps today's writable single-host view.

bats_require_minimum_version 1.5.0
load helpers/tui

merge_tui() {
  (cd "$WORK/proj" && PAGER=cat "$PTY_RUN" "$SCREEN" "$1" "$TUI" --merge)
}

seed_agents() {
  (cd "$WORK/proj" && printf 'agents body line\n' | RADIN_HOST=agents bash "$BACKLOG" add feat "agents task" >/dev/null)
}

@test "both backlogs merge read-only, and d changes neither index" {
  seed
  seed_agents
  AGENTS_INDEX="$WORK/proj/.agents/.radin/backlog/index.jsonl"
  cat "$INDEX" "$AGENTS_INDEX" >"$WORK/before"
  run merge_tui "d|q"
  [ "$status" -eq 0 ]
  output="$(last_frame | plain)"
  [[ "$output" == *"host:merged (read-only)"* ]]
  [[ "$output" == *"3 task(s)"* ]]
  [[ "$output" == *"merged view is read-only"* ]]
  cat "$INDEX" "$AGENTS_INDEX" | cmp - "$WORK/before"
}

@test "one backlog shows no merged tag and d still deletes" {
  seed
  run merge_tui "d|y\r|q"
  [ "$status" -eq 0 ]
  output="$(last_frame | plain)"
  [[ "$output" != *"host:merged"* ]]
  [ ! -f "$TASKS/dark-mode.md" ]
}

@test "only an agents backlog opens as the agents host" {
  seed_agents
  run merge_tui "q"
  [ "$status" -eq 0 ]
  output="$(last_frame | plain)"
  [[ "$output" == *"host:agents"* ]]
  [[ "$output" == *"agents task"* ]]
}

@test "the detail pane reads an agents task body from the agents namespace" {
  seed
  seed_agents
  run bash -c "cd '$WORK/proj' && PAGER=cat PTY_COLS=120 '$PTY_RUN' '$SCREEN' 'j|j|q' '$TUI' --merge"
  [ "$status" -eq 0 ]
  output="$(last_frame | plain)"
  [[ "$output" == *"agents body line"* ]]
}

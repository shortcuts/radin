# Shared by tests/tui-*.bats: the pty fixture and its helper functions.

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
  # The palette follows TERM/COLORTERM, so pin the 16-colour one: escape
  # assertions must not depend on the terminal the suite runs in.
  export TERM=xterm
  unset COLORTERM
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

# The screen as the TUI left it, one line per row, so an assertion about what
# a keypress removed is not satisfied by an earlier frame. A frame repaints
# only the rows that changed, each opened by `ESC[<row>;1H ESC[K`, so the
# screen is the latest text drawn per row since the last clear.
last_frame() {
  awk 'BEGIN{RS="\001"} {
    s = $0; r = 0; max = 0
    while (match(s, /\033[[]([0-9]+;1H\033[[]K|H\033[[]2J)/)) {
      row[r] = row[r] substr(s, 1, RSTART - 1)
      m = substr(s, RSTART + 2, RLENGTH - 2)
      s = substr(s, RSTART + RLENGTH)
      if (m ~ /2J$/) { for (k in row) delete row[k]; r = 0; max = 0 }
      else { r = m + 0; row[r] = ""; if (r > max) max = r }
    }
    row[r] = row[r] s
    for (k = 0; k <= max; k++) print row[k]
  }' "$SCREEN"
}

# Text with its styling stripped, for an assertion on words a style span may
# split: a coloured badge or a dim label sits between them.
plain() {
  sed $'s/\033\\[[0-9;]*m//g'
}

# The last frame's [sel/total] header, so a wrap back to row 1 is not
# confused with the frame the TUI opened on.
last_pos() {
  grep -ao '\[[0-9]*/[0-9]*\]' "$SCREEN" | tail -1
}

two_epics() {
  bl epic-add aaa-epic <<<"aaa ctx"
  bl epic-add bbb-epic <<<"bbb ctx"
  bl add feat "aaa child" <<<"aaa body" >/dev/null
  bl epic-move aaa-child aaa-epic >/dev/null
  bl add feat "bbb child" <<<"bbb body" >/dev/null
  bl epic-move bbb-child bbb-epic >/dev/null
}

tui() {
  local keys="$1"
  (cd "$WORK/proj" && EDITOR="${TUI_EDITOR:-$WORK/editor.sh}" PAGER=cat \
    "$PTY_RUN" "$SCREEN" "$keys" "$TUI")
}

# The task titles in the order the last frame drew them.
row_titles() {
  last_frame | grep -oE 'dark mode|broken auth|later thing' | tr '\n' ' '
}

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

# A plan that passes plan-lint. $1 is the path, $2 the Outcome line.
write_plan() {
  mkdir -p "$(dirname "$1")"
  {
    printf '## Outcome\n%s\n' "$2"
    for s in Decisions "Alternatives rejected"; do printf '## %s\nn/a: test\n' "$s"; done
    printf '## Changes\n- `a.txt` - edit\n  You see: a\n'
    for s in "Reach and reuse" "Rubrics triggered" "Modes and states" Order; do printf '## %s\nn/a: test\n' "$s"; done
    printf '## Testing\n- [ ] run it\n- [ ] Live: run it\n'
    for s in Risks "Out of scope"; do printf '## %s\nn/a: test\n' "$s"; done
  } >"$1"
}

# A plan file plus the pointer that makes `backlog meta` report it. $1 is the
# task id, $2 the plan slug, $3 the line the plan body carries.
planned_body() {
  write_plan "$NS/plans/$2.md" "$3"
  bl add-plan "$1" "$NS/plans/$2.md" >/dev/null
}

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

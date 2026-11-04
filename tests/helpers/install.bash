# Shared by tests/install*.bats: the mocks, the recorded install and the install helpers.
# shellcheck shell=bash
# Exercises install.sh against an isolated $HOME with stubbed brew/curl/claude
# so the suite runs offline and never touches the real ~/.claude. PATH is
# reduced to MOCK_BIN + core system dirs so real rtk/codebase-memory-mcp/brew
# installs on the dev machine can't leak into "not installed" assertions.


setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

  TEST_HOME="$(mktemp -d)"
  MOCK_BIN="$(mktemp -d)"
  load helpers/isolate
  isolate_env "$TEST_HOME"
  export PATH="$MOCK_BIN:/usr/bin:/bin:/usr/sbin:/sbin"
  load helpers/pty
  MOCK_SRC_BIN="$BATS_FILE_TMPDIR/mock"

  make_mocks
}

# One real install.sh run for the whole file, recorded so every test that only
# asserts on the installed tree can replay it instead of paying ~1.1s again.
setup_file() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export TEMPLATE="$BATS_FILE_TMPDIR/template"
  TEST_HOME="$TEMPLATE/home"
  MOCK_BIN="$TEMPLATE/bin"
  mkdir -p "$TEST_HOME" "$MOCK_BIN"
  load helpers/isolate
  isolate_env "$TEST_HOME"
  load helpers/pty
  MOCK_SRC_BIN="$BATS_FILE_TMPDIR/mock"
  make_mocks
  # The one run that compiles the TUI for real: every other live run gets the
  # mock cc, because cc costs ~0.3s.
  rm -f "$MOCK_BIN/cc" "$MOCK_BIN/gcc" "$MOCK_BIN/clang"

  local st=0
  (cd "$REPO_ROOT" && printf '2\n' |
    env HOME="$TEST_HOME" PATH="$MOCK_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
      bash ./install.sh) >"$TEMPLATE/output" 2>&1 || st=$?
  printf '%s\n' "$st" >"$TEMPLATE/status"
}

# Stubs every binary install.sh reaches for, so no test makes a network
# request. One compiled mock (tests/helpers/mock.c) hardlinked under each
# command name: a shell script per command cost ~20ms of /bin/sh startup per
# call, ~0.5s per install run. Uses $TEST_HOME/$MOCK_BIN from the caller:
# setup() per test, and setup_file() once for the recorded install.
make_mocks() {
  BREW_LOG="$TEST_HOME/brew.log"
  export MOCK_BIN MOCK_LOG_DIR="$TEST_HOME"
  # CI runners set it; the mock records it, which would hide a leak from install.sh.
  unset HOMEBREW_NO_AUTO_UPDATE
  cc_build "$BATS_TEST_DIRNAME/helpers/mock.c" "$MOCK_SRC_BIN" ||
    skip "a C compiler is needed to build the command mocks"
  cp "$MOCK_SRC_BIN" "$MOCK_BIN/mock"
  for c in brew curl claude npx python3 node gh cc gcc clang; do
    ln "$MOCK_BIN/mock" "$MOCK_BIN/$c" 2>/dev/null || ln -s "$MOCK_BIN/mock" "$MOCK_BIN/$c"
  done
}

teardown() {
  rm -rf "$TEST_HOME" "$MOCK_BIN"
}

# Replays setup_file's recorded install: the tree, its stdout and its exit
# status. Only a test whose subject is install-time behaviour should run
# install.sh itself -- see AGENTS.md's "Before committing".
replay_install() {
  rm -rf "$TEST_HOME/.claude" "$TEST_HOME/.radin" "$TEST_HOME/.local"
  cp -a "$TEMPLATE/home/.claude" "$TEST_HOME/.claude"
  cp -a "$TEMPLATE/home/.radin" "$TEST_HOME/.radin"
  # A kept build stamp would skip the next run's (mocked) cc, so the real helper
  # binary from setup_file would replace the stub these tests expect.
  rm -f "$TEST_HOME"/.radin/bin/.*.sum
  [ -d "$TEMPLATE/home/.local" ] && cp -a "$TEMPLATE/home/.local" "$TEST_HOME/.local"
  for log in brew.log; do
    [ -f "$TEMPLATE/home/$log" ] && cp "$TEMPLATE/home/$log" "$TEST_HOME/$log"
  done
  cat "$TEMPLATE/output"
  return "$(cat "$TEMPLATE/status")"
}

# The install-time-behaviour exception: a test whose subject is what install.sh
# does while running (a missing binary, a pre-existing file, a second run)
# cannot use the replay, and costs the suite ~1.1s. See AGENTS.md.
real_install() {
  cd "$REPO_ROOT" && printf '2\n' | bash ./install.sh "$@"
}

# Two questions, in this order: 1 sub-agent models, 2 package manager. Each is
# a numbered picker where 1 is the first option (yes / first detected manager)
# and 2 the second, so one 2 takes the default models and leaves the manager
# pick at its own.
# No companion tool is asked about beyond that one manager -- the stubs on
# MOCK_BIN absorb those calls.
run_install_defaults() {
  replay_install
}

# The arrow-key picker only draws on a real terminal, so it gets driven through
# a pty helper. Extracting the functions from install.sh keeps the picker itself
# single-sourced there.
pick_with_keys() {
  load helpers/pty
  pty_build || skip "a C compiler is needed to build the pty driver"
  local snippet="$TEST_HOME/picker.sh" out="$TEST_HOME/picked"
  sed -n '/^_pick_nth() {/,/^# A terminal can answer a question/p' "$REPO_ROOT/install.sh" | sed '$d' > "$snippet"
  rm -f "$out"
  "$PTY_RUN" "$TEST_HOME/pick-screen" "$1" bash -c \
    "YES=''; RAT=''; BOLD=''; DIM=''; CYAN=''; YELLOW=''; RED=''; RESET=''; \
     source '$snippet'; prompt_pick 'pick one' 1 alpha beta gamma > '$out'" \
    >/dev/null 2>&1 && PICK_STATUS=0 || PICK_STATUS="$?"
  PICKED="$(cat "$out" 2>/dev/null || true)"
}


# The layout before ~/.radin: the radin home inside ~/.claude. $1 is the
# directory ~/.claude points at (a symlink target), or empty for a plain one.
seed_old_layout() {
  local real="${1:-$TEST_HOME/.claude}" old
  if [ -n "$1" ]; then
    mkdir -p "$1"
    ln -s "$1" "$TEST_HOME/.claude"
  fi
  old="$real/.radin"
  mkdir -p "$old/lib" "$old/bin" "$old/backups/snap" "$TEST_HOME/.local/bin"
  printf '{"installed_at": "2026-01-01T00:00:00Z", "companion_tools": {}}\n' >"$old/manifest.json"
  echo stale >"$old/lib/radin-run.md"
  echo stale >"$old/lib/radin-tui.sh"
  echo sentinel >"$old/backups/snap/settings.json"
  echo "$REPO_ROOT" >"$old/install_root"
  printf '#!/bin/sh\n' >"$old/bin/radin"
  chmod +x "$old/bin/radin"
  ln -s "$old/bin/radin" "$TEST_HOME/.local/bin/radin"
  cat >"$real/settings.json" <<JSON
{"permissions": {"allow": ["Read(//x/**)", "Read(/$TEST_HOME/.claude/.radin/**)", "Read(/$(cd "$real" && pwd -P)/.radin/**)"]}}
JSON
}

# setup_file builds radin-cbm-json for real; so must every run whose subject
# is the settings.json edit.
use_real_cc() {
  rm -f "$MOCK_BIN/cc" "$MOCK_BIN/gcc" "$MOCK_BIN/clang"
}

assert_migrated() {
  [ ! -e "$TEST_HOME/.claude/.radin" ]
  [ "$(cat "$TEST_HOME/.radin/backups/snap/settings.json")" = sentinel ]
  [ ! -e "$TEST_HOME/.radin/lib/radin-run.md" ]
  [ ! -e "$TEST_HOME/.radin/lib/radin-tui.sh" ]
  [ -f "$TEST_HOME/.radin/hosts/claude/lib/radin-run.md" ]
  [ "$(readlink "$TEST_HOME/.local/bin/radin")" = "$TEST_HOME/.radin/bin/radin" ]
  grep -qF "Read(/$TEST_HOME/.radin/**)" "$TEST_HOME/.claude/settings.json"
  grep -qF 'Read(//x/**)' "$TEST_HOME/.claude/settings.json"
  run grep -cF '/.claude/.radin' "$TEST_HOME/.claude/settings.json"
  [ "$output" = 0 ]
}

# Host selection: --only, the manifest, a terminal prompt, or claude alone.

mock_cli() {
  ln "$MOCK_BIN/mock" "$MOCK_BIN/$1" 2>/dev/null || ln -s "$MOCK_BIN/mock" "$MOCK_BIN/$1"
}

# A manifest array as written: `"a", "b"`.
manifest_array() {
  sed -n 's/.*"'"$1"'": *\[\([^]]*\)\].*/\1/p' "$TEST_HOME/.radin/manifest.json"
}

# Keys of the manifest `files` map.
manifest_file_keys() {
  sed -n '/"files": {/,/^  }/p' "$TEST_HOME/.radin/manifest.json" | sed -n 's/^    "\([^"]*\)": ".*/\1/p'
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# A copy of the repo to install from. skills/radin-uninstall still fails every agents
# install: it holds the baselined "~/.claude" (hosts/forbid-baseline.txt). The sed
# stands in for the host block that will wrap it.
agents_root() {
  AROOT="$BATS_TEST_TMPDIR/root"
  mkdir -p "$AROOT"
  (cd "$REPO_ROOT" && cp -R install.sh bin lib skills scripts hosts "$AROOT/")
  sed 's|~/\.claude|the host skills dir|g' "$AROOT/skills/radin-uninstall/SKILL.md" >"$AROOT/tmp.md"
  mv "$AROOT/tmp.md" "$AROOT/skills/radin-uninstall/SKILL.md"
}

install_from() {
  local root="$1"
  shift
  (cd "$root" && bash ./install.sh "$@" </dev/null)
}

assert_no_agents_marker() {
  run grep -rlE '<!-- host|@@skill:|RADIN_LIB|RADIN_CLI|RADIN_MODEL_|RADIN_EFFORT_' \
    "$TEST_HOME/.agents/skills" "$TEST_HOME/.radin/hosts/agents/lib"
  [ "$status" -eq 1 ]
}

# A new line in the copied root's lib/radin-run.md must reach exactly the renders of the manifest hosts.
update_marker() {
  printf '\nUPDATE-MARKER\n' >>"$AROOT/lib/radin-run.md"
}

# Forbidden in the agents render only: the claude render of the same line is fine.
break_agents_render() {
  printf '\nAskUserQuestion\n' >>"$AROOT/lib/radin-run.md"
}

# The wizard reads the terminal, so the whole installer runs through a pty. --dry-run
# stops every write, and the recorded screen is stripped of escape codes.
wizard_run() {
  pty_build || skip "a C compiler is needed to build the pty driver"
  mock_cli codex
  local keys="$1"
  shift
  cd "$REPO_ROOT"
  WIZ_STATUS=0
  "$PTY_RUN" "$TEST_HOME/screen" "$keys" bash ./install.sh --dry-run "$@" >/dev/null 2>&1 || WIZ_STATUS="$?"
  WIZ_SCREEN="$(LC_ALL=C sed 's/\x1b\[[0-9;?]*[A-Za-z]//g' "$TEST_HOME/screen" | LC_ALL=C tr -d '\r')"
}

wizard_count() {
  printf '%s\n' "$WIZ_SCREEN" | grep -c -- "$1" || true
}

# Ownership: the preflight, kept edits and --force backups.

home_sum() {
  # One hash process for the whole tree: a fork per file took ~15s on a three-host home.
  (cd "$TEST_HOME" && find . -type f | sort | tr '\n' '\0' |
    { if command -v sha256sum >/dev/null 2>&1; then xargs -0 sha256sum; else xargs -0 shasum -a 256; fi; } |
    awk '{ h = $1; sub(/^[^ ]+ +\*?/, ""); print $0 " " h }')
}

manifest_digest_of() {
  sed -n 's|^    "'"$1"'": "\(.*\)",\{0,1\}$|\1|p' "$TEST_HOME/.radin/manifest.json"
}

foreign_skill() {
  mkdir -p "$TEST_HOME/$1"
  printf 'mine\n' >"$TEST_HOME/$1/SKILL.md"
}

agents_skill_names() { awk '!/^#/ && NF { print $1 }' "$REPO_ROOT/lib/companion-skills.txt"; }

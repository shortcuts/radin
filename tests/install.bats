#!/usr/bin/env bats
# Exercises install.sh against an isolated $HOME with stubbed brew/curl/claude
# so the suite runs offline and never touches the real ~/.claude. PATH is
# reduced to MOCK_BIN + core system dirs so real rtk/codebase-memory-mcp/brew
# installs on the dev machine can't leak into "not installed" assertions.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

  TEST_HOME="$(mktemp -d)"
  MOCK_BIN="$(mktemp -d)"
  export HOME="$TEST_HOME"
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
  PIP_LOG="$TEST_HOME/pipx.log"
  export MOCK_BIN MOCK_LOG_DIR="$TEST_HOME"
  cc_build "$BATS_TEST_DIRNAME/helpers/mock.c" "$MOCK_SRC_BIN" ||
    skip "a C compiler is needed to build the command mocks"
  cp "$MOCK_SRC_BIN" "$MOCK_BIN/mock"
  for c in brew curl claude pipx pip3 npx python3 node gh cc gcc clang; do
    ln "$MOCK_BIN/mock" "$MOCK_BIN/$c" 2>/dev/null || ln -s "$MOCK_BIN/mock" "$MOCK_BIN/$c"
  done
}

teardown() {
  rm -rf "$TEST_HOME" "$MOCK_BIN"
}

# Replays setup_file's recorded install: the tree, its stdout and its exit
# status. Only a test whose subject is install-time behaviour should run
# install.sh itself -- see AGENTS.md's "Test suite speed".
replay_install() {
  rm -rf "$TEST_HOME/.claude" "$TEST_HOME/.local"
  cp -a "$TEMPLATE/home/.claude" "$TEST_HOME/.claude"
  [ -d "$TEMPLATE/home/.local" ] && cp -a "$TEMPLATE/home/.local" "$TEST_HOME/.local"
  for log in brew.log pipx.log; do
    [ -f "$TEMPLATE/home/$log" ] && cp "$TEMPLATE/home/$log" "$TEST_HOME/$log"
  done
  cat "$TEMPLATE/output"
  return "$(cat "$TEMPLATE/status")"
}

# The install-time-behaviour exception: a test whose subject is what install.sh
# does while running (a missing binary, a pre-existing file, a second run)
# cannot use the replay, and costs the suite ~1.1s. See AGENTS.md.
real_install() {
  cd "$REPO_ROOT" && printf '2\n' | bash ./install.sh
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

@test "a real install.sh run succeeds end to end" {
  [ "$(cat "$TEMPLATE/status")" -eq 0 ]
  grep -q 'Done' "$TEMPLATE/output"
  [ -f "$TEMPLATE/home/.claude/skills/radin-execute/SKILL.md" ]
  [ -f "$TEMPLATE/home/.claude/.radin/lib/radin-backlog.sh" ]
  [ -f "$TEMPLATE/home/.claude/.radin/manifest.json" ]
  [ -x "$TEMPLATE/home/.claude/.radin/bin/radin-tui" ]
  [ -x "$TEMPLATE/home/.claude/.radin/bin/radin-cbm-json" ]
}

# Exiting before "Done" leaves a partial ~/.claude, so the run must say so
# instead of returning success-looking silence. radin's own stack is already
# complete by then: a vendored tool dies after every token is written.
@test "an install that dies mid-run says the install is partial" {
  export MOCK_NPX=fail
  cd "$REPO_ROOT" && run bash -c "printf '2\n2\n' | bash ./install.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"partial install"* ]]
  [ -L "$TEST_HOME/.local/bin/radin" ]
  [ -z "$(grep -rl --include='*.md' 'RADIN_CLI\|RADIN_LIB\|RADIN_MODEL_' "$TEST_HOME/.claude/skills" "$TEST_HOME/.claude/.radin/lib")" ]
  grep -q 'radin:begin' "$TEST_HOME/.claude/CLAUDE.md"
}

# Every entry point is a skill, so it runs in the user's own thread. radin
# ships no agent: an install must never create ~/.claude/agents.
# A surviving RADIN_MODEL_ token would reach Claude as a literal model name and
# every dispatch would fail, so no installed file may keep one.
@test "writes a model into every sub-agent role, leaving no marker behind" {
  run_install_defaults
  run ! grep -rq --exclude=radin-doctor.sh 'RADIN_MODEL_' "$TEST_HOME/.claude/skills" "$TEST_HOME/.claude/.radin/lib"
  grep -q 'model: "sonnet"' "$TEST_HOME/.claude/.radin/lib/radin-run.md"
  grep -q 'model: "haiku"' "$TEST_HOME/.claude/.radin/lib/radin-prompt-factfind.md"
}

# "Same model for every role?" defaults to yes: one pick sets all five tokens,
# fact-finding's haiku default included.
@test "one same-model pick covers every role, even when a companion reads stdin" {
  export MOCK_NPX=eat-stdin
  cd "$REPO_ROOT" && run bash -c "printf '1\n1\n2\n' | bash ./install.sh"
  [ "$status" -eq 0 ]
  grep -q '"model_planning": "opus"' "$TEST_HOME/.claude/.radin/manifest.json"
  run ! grep -rq --exclude=radin-doctor.sh 'RADIN_MODEL_' "$TEST_HOME/.claude/skills" "$TEST_HOME/.claude/.radin/lib"
  grep -q 'model: "opus"' "$TEST_HOME/.claude/.radin/lib/radin-run.md"
  grep -q 'model: "opus"' "$TEST_HOME/.claude/.radin/lib/radin-prompt-factfind.md"
  ! grep -q 'model: "haiku"' "$TEST_HOME/.claude/.radin/lib/radin-prompt-factfind.md"
}

# install.sh, radin-doctor.sh and radin-uninstall.sh each keep their own list
# of shipped files. Checking all three against one real install tree is what
# catches a file added to one list and forgotten in another.
@test "doctor finds and uninstall removes exactly what install ships" {
  run_install_defaults
  run bash "$TEST_HOME/.claude/.radin/lib/radin-doctor.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"All expected files present."* ]]
  [[ "$output" == *"no unsubstituted token left"* ]]
  run bash "$TEST_HOME/.claude/.radin/lib/radin-uninstall.sh"
  [ "$status" -eq 0 ]
  [ -z "$(find "$TEST_HOME/.claude/.radin/lib" "$TEST_HOME/.claude/.radin/bin" -type f)" ]
  [ -z "$(ls "$TEST_HOME/.claude/skills" | grep '^radin-')" ]
  [ -f "$TEST_HOME/.claude/skills/thermo-nuclear/SKILL.md" ]
}

@test "writes an install manifest listing installed files and companion tools" {
  run run_install_defaults
  [ "$status" -eq 0 ]
  manifest="$TEST_HOME/.claude/.radin/manifest.json"
  [ -f "$manifest" ]
  grep -q '"version"' "$manifest"
  for f in "$TEST_HOME"/.claude/.radin/lib/* "$TEST_HOME"/.claude/skills/radin-*; do
    grep -q "\"${f##*/}\"" "$manifest"
  done
  grep -q '"rtk": true' "$manifest"
  grep -q '"codebase-memory-mcp": false' "$manifest"
  grep -q '"headroom": true' "$manifest"
}

# The guidance block rewrites only what sits between its own markers, so
# install.sh writes it unconditionally -- including into a file that already
# has the user's own content.
@test "the CLAUDE.md guidance block is written once, idempotently" {
  mkdir -p "$TEST_HOME/.claude"
  echo "user content stays" > "$TEST_HOME/.claude/CLAUDE.md"
  run real_install
  [ "$status" -eq 0 ]
  claude_md="$TEST_HOME/.claude/CLAUDE.md"
  before="$(wc -l < "$claude_md")"
  run real_install
  [ "$status" -eq 0 ]
  grep -q "user content stays" "$claude_md"
  [ "$(grep -c '<!-- radin:begin -->' "$claude_md")" -eq 1 ]
  [ "$(grep -c '<!-- radin:end -->' "$claude_md")" -eq 1 ]
  grep -q '/radin-record' "$claude_md"
  grep -q '"claude_md_guidance": true' "$TEST_HOME/.claude/.radin/manifest.json"
  # A re-run must not grow the file by one blank line each time.
  [ "$(wc -l < "$claude_md")" -eq "$before" ]
}

@test "installs the radin CLI dispatcher and the ~/.local/bin symlink" {
  # Asserted on the recorded tree: the symlink names its own $TEMPLATE home, so
  # a replay into another $HOME could not be checked.
  [ -x "$TEMPLATE/home/.claude/.radin/bin/radin" ]
  [ -L "$TEMPLATE/home/.local/bin/radin" ]
  [ "$(readlink "$TEMPLATE/home/.local/bin/radin")" = "$TEMPLATE/home/.claude/.radin/bin/radin" ]
  grep -q '"cli_on_path": true' "$TEMPLATE/home/.claude/.radin/manifest.json"
}

# Skills carry a RADIN_CLI token; set_cli resolves it to whichever invocation
# works. The test PATH lacks ~/.local/bin, so even with the symlink the full
# dispatcher path is written -- bare `radin` would break every skill here.
@test "RADIN_CLI resolves to the full path when ~/.local/bin is off PATH" {
  run_install_defaults
  run ! grep -rq --exclude=radin-doctor.sh 'RADIN_CLI' "$TEST_HOME/.claude/skills" "$TEST_HOME/.claude/.radin/lib"
  grep -q '"$HOME/.claude/.radin/bin/radin" backlog' "$TEST_HOME/.claude/.radin/lib/radin-run.md"
}

# radin-execute and radin-implement read lib docs with the Read tool, which
# takes no `$HOME`. set_lib resolves RADIN_LIB at install time, so the installed
# files carry a path Read accepts. The replayed tree was installed under
# $TEMPLATE/home, which is the HOME the recorded run resolved against.
@test "RADIN_LIB resolves to the installed lib directory" {
  run_install_defaults
  run_doc="$TEST_HOME/.claude/.radin/lib/radin-run.md"
  run ! grep -rq 'RADIN_LIB' "$TEST_HOME/.claude/skills" "$run_doc"
  run ! grep -q '$HOME/.claude/.radin/lib' "$run_doc"
  grep -q "$TEMPLATE/home/.claude/.radin/lib/radin-execute-clarify.md" "$run_doc"
  for s in radin-execute radin-implement; do
    grep -q "$TEMPLATE/home/.claude/.radin/lib/radin-run.md" "$TEST_HOME/.claude/skills/$s/SKILL.md"
  done
}

@test "the dispatcher routes subcommands to the installed lib scripts" {
  run_install_defaults
  # cd out of the repo: namespace resolution would otherwise count radin's own backlog.
  cd "$TEST_HOME"
  run env HOME="$TEST_HOME" bash "$TEST_HOME/.claude/.radin/bin/radin" backlog count
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
  run env HOME="$TEST_HOME" bash "$TEST_HOME/.claude/.radin/bin/radin" nope
  [ "$status" -ne 0 ]
}

@test "radin help prints the usage text, bare radin off a tty fails with it" {
  run_install_defaults
  run env HOME="$TEST_HOME" bash "$TEST_HOME/.claude/.radin/bin/radin" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"usage: radin"* ]]
  # `run` captures stdout through a pipe, so this is the non-tty path.
  run env HOME="$TEST_HOME" bash "$TEST_HOME/.claude/.radin/bin/radin"
  [ "$status" -ne 0 ]
  [[ "$output" == *"usage: radin"* ]]
}

@test "bare radin on a tty opens the TUI" {
  run_install_defaults
  pty_build || skip "a C compiler is needed to build the pty driver"
  cd "$TEST_HOME"
  run env HOME="$TEST_HOME" "$PTY_RUN" "$TEST_HOME/screen" "q" \
    bash "$TEST_HOME/.claude/.radin/bin/radin"
  [ "$status" -eq 0 ]
  run cat "$TEST_HOME/screen"
  [[ "$output" == *"no tasks"* ]]
  # The `tui` verb is gone: it is an unknown verb like any other.
  run env HOME="$TEST_HOME" bash "$TEST_HOME/.claude/.radin/bin/radin" tui
  [ "$status" -ne 0 ]
  [[ "$output" == *"usage: radin"* ]]
}

# Three install-time setups that do not interact, sharing one live run.
@test "real install: foreign ~/.local/bin/radin kept, installed rtk reinstalled, partial cbm config warned" {
  mkdir -p "$TEST_HOME/.local/bin"
  echo "someone else's" > "$TEST_HOME/.local/bin/radin"
  ln "$MOCK_BIN/mock" "$MOCK_BIN/rtk" 2>/dev/null || ln -s "$MOCK_BIN/mock" "$MOCK_BIN/rtk"
  ln "$MOCK_BIN/mock" "$MOCK_BIN/codebase-memory-mcp" 2>/dev/null ||
    ln -s "$MOCK_BIN/mock" "$MOCK_BIN/codebase-memory-mcp"
  export MOCK_CBM=fail-install
  run real_install
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_HOME/.local/bin/radin")" = "someone else's" ]
  [[ "$output" == *"isn't radin's"* ]]
  grep -q 'install rtk' "$TEST_HOME/brew.log"
  [[ "$output" == *"reported a failure while configuring Claude Code"* ]]
  [[ "$output" == *"cbm-config.log"* ]]
  [[ "$output" != *"OpenCode:"* ]]
  [[ "$output" != *"hooks: SessionStart"* ]]
  [[ "$output" != *"wired: skill"* ]]
  grep -q '^PARTIAL ' "$TEST_HOME/.claude/.radin/cbm-config.log"
  grep -q 'OpenCode:' "$TEST_HOME/.claude/.radin/cbm-config.log"
}

@test "the skill ships no per-task verification pass" {
  run_install_defaults
  agent="$TEST_HOME/.claude/.radin/lib/radin-run.md"
  run ! grep -qi "refut" "$agent"
  grep -q "Never verify a .SUCCESS. yourself" "$agent"
}

# radin-implement is radin-execute minus the planning dispatch; each skill's
# own no-plan rule is the only thing that tells them apart.
@test "only radin-execute dispatches a planning sub-agent" {
  run_install_defaults
  grep -q -- "--plan-first" "$TEST_HOME/.claude/skills/radin-execute/SKILL.md"
  run ! grep -q -- "--plan-first" "$TEST_HOME/.claude/skills/radin-implement/SKILL.md"
  run ! grep -q -- "--plan-first" "$TEST_HOME/.claude/.radin/lib/radin-run.md"
}

# The arrow-key picker only draws on a real terminal, so it gets driven through
# a pty helper. Extracting the functions from install.sh keeps the picker itself
# single-sourced there.
pick_with_keys() {
  load helpers/pty
  pty_build || skip "a C compiler is needed to build the pty driver"
  local snippet="$TEST_HOME/picker.sh" out="$TEST_HOME/picked"
  sed -n '/^_pick_nth() {/,/^prompt_yn() {/p' "$REPO_ROOT/install.sh" | sed '$d' > "$snippet"
  rm -f "$out"
  "$PTY_RUN" "$TEST_HOME/pick-screen" "$1" bash -c \
    "YES=''; RAT=''; BOLD=''; DIM=''; CYAN=''; YELLOW=''; RED=''; RESET=''; \
     source '$snippet'; prompt_pick 'pick one' 1 alpha beta gamma > '$out'" \
    >/dev/null 2>&1 && PICK_STATUS=0 || PICK_STATUS="$?"
  PICKED="$(cat "$out" 2>/dev/null || true)"
}

@test "arrow keys move the selection, enter confirms it" {
  pick_with_keys '\r'
  [ "$PICKED" = "alpha" ]
  pick_with_keys '\033[B\r'
  [ "$PICKED" = "beta" ]
  pick_with_keys '\033[B\033[B\r'
  [ "$PICKED" = "gamma" ]
}

@test "picker wraps at the ends and takes j/k and digits too" {
  pick_with_keys '\033[A\r'
  [ "$PICKED" = "gamma" ]
  pick_with_keys 'j\r'
  [ "$PICKED" = "beta" ]
  pick_with_keys '3\r'
  [ "$PICKED" = "gamma" ]
}

# Raw mode turns off ISIG: without explicit handling Ctrl-C would be swallowed
# and the picker would be unquittable.
@test "Ctrl-C in the picker aborts the install" {
  pick_with_keys '\003'
  [ "$PICK_STATUS" -eq 130 ]
  [ -z "$PICKED" ]
}

@test "refuses to reuse a fetch dir it didn't create" {
  FAKE_ROOT="$TEST_HOME/fake-checkout"
  mkdir -p "$FAKE_ROOT"
  cp "$REPO_ROOT/install.sh" "$FAKE_ROOT/install.sh"
  # No sibling skills/lib dirs -> forces the download branch.
  FETCH_DIR="$TEST_HOME/preexisting"
  mkdir -p "$FETCH_DIR"
  echo "not ours" > "$FETCH_DIR/some_other_file"
  run bash -c "cd '$FAKE_ROOT' && printf '2\n2\n' | RADIN_ROOT_OVERRIDE='$FETCH_DIR' bash ./install.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"wasn't created by this installer"* ]]
}

# --yes is how one command reproduces this machine on the next one: the three
# behaviour questions take their defaults instead of blocking on a terminal.
@test "--yes asks nothing and still installs everything" {
  cd "$REPO_ROOT" && run bash ./install.sh --yes
  [ "$status" -eq 0 ]
  grep -q "install rtk" "$BREW_LOG"
  grep -q "headroom-ai" "$PIP_LOG"
  [[ "$output" != *"Pick 1-"* ]]
  manifest="$TEST_HOME/.claude/.radin/manifest.json"
  grep -q '"rtk": true' "$manifest"
  # The guidance block is part of "same stack on the next machine".
  grep -q '"claude_md_guidance": true' "$manifest"
  grep -q '<!-- radin:begin -->' "$TEST_HOME/.claude/CLAUDE.md"
}

# The package-manager pick is what keeps radin off a manager the user doesn't
# use: picking mise must install rtk and headroom through mise, never brew, and
# the answer must survive into the manifest so `radin update` keeps it.
@test "picking mise installs rtk and headroom through mise, not brew" {
  ln "$MOCK_BIN/mock" "$MOCK_BIN/mise" 2>/dev/null || ln -s "$MOCK_BIN/mock" "$MOCK_BIN/mise"
  cd "$REPO_ROOT" && run bash -c "printf '2\n2\n' | bash ./install.sh"
  [ "$status" -eq 0 ]
  [[ "$(cat "$TEST_HOME/mise.log")" == *"aqua:rtk-ai/rtk"* ]]
  [[ "$(cat "$TEST_HOME/mise.log")" == *"pipx:headroom-ai"* ]]
  [ ! -s "$TEST_HOME/brew.log" ] || [[ "$(cat "$TEST_HOME/brew.log")" != *"install rtk"* ]]
  grep -q '"package_manager": "mise"' "$TEST_HOME/.claude/.radin/manifest.json"
}

# A companion tool that fails must not abort radin's own install -- set -e used
# to kill the script the moment a pip/pipx preflight failed. Plugins install
# through the `claude` CLI and nothing else: without it, say so once per plugin
# rather than failing three times. Both are the same advisory-failure run.
@test "a failing companion tool and a missing claude CLI both warn, and the install completes" {
  export MOCK_FAIL=brew
  rm -f "$MOCK_BIN/claude"
  cd "$REPO_ROOT" && run bash ./install.sh --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"rtk install failed"* ]]
  [[ "$output" == *"caveman skipped: the 'claude' CLI is not on PATH"* ]]
  [[ "$output" != *"caveman install failed"* ]]
  [[ "$output" == *"radin installed."* ]]
}

# A PARTIAL codebase-memory-mcp config exits 0, so install.sh takes its success
# branch. The failure still has to reach the user, and the per-item trace plus
# upstream's own per-client inventory still has to stay off the terminal.

# `radin update` runs install.sh --update: radin's own steps and questions
# only. No companion installer runs, and the package-manager answer, which
# only companions use, comes from the manifest the previous install wrote.
@test "--update asks the questions again and installs no companion tool" {
  replay_install >/dev/null
  manifest="$TEST_HOME/.claude/.radin/manifest.json"
  grep -q '"package_manager": "brew"' "$manifest"
  rm -f "$TEST_HOME"/*.log

  run bash -c "printf '1\n1\n1\n' | bash ./install.sh --update"
  [ "$status" -eq 0 ]
  [[ "$output" == *"sub-agent models: plan fable"* ]]
  grep -q 'fable' "$TEST_HOME/.claude/.radin/lib/radin-prompt-planning.md"
  grep -q '"package_manager": "brew"' "$manifest"
  [ ! -e "$TEST_HOME/brew.log" ]
  [ ! -e "$TEST_HOME/npx.log" ]
  [ ! -e "$TEST_HOME/pipx.log" ]
  [ ! -e "$TEST_HOME/curl.log" ]
  [[ "$output" == *"radin updated"* ]]
  run ! grep -qE 'install|update|marketplace' "$TEST_HOME/claude.log"
}

# install is the one path that touches companions, so a tool already on PATH
# still takes its install/upgrade command instead of being skipped.
@test "the install records its source root for radin update" {
  run run_install_defaults
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_HOME/.claude/.radin/install_root")" = "$REPO_ROOT" ]
}


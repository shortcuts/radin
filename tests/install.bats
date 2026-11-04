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
  [ -f "$TEMPLATE/home/.claude/skills/radin-batch/SKILL.md" ]
  [ -f "$TEMPLATE/home/.radin/lib/radin-backlog.sh" ]
  [ -f "$TEMPLATE/home/.radin/manifest.json" ]
  [ -x "$TEMPLATE/home/.radin/bin/radin-tui" ]
  [ -x "$TEMPLATE/home/.radin/bin/radin-cbm-json" ]
  # Agents read the backlog through the CLI.
  grep -q 'what is pending: run `.* backlog show`' "$TEMPLATE/home/.claude/CLAUDE.md"
  ! grep -q '/radin-show' "$TEMPLATE/home/.claude/CLAUDE.md"
}

@test "installed radin-run.md holds no host marker and keeps the claude loop" {
  replay_install >/dev/null
  run grep -c '<!-- /\?host' "$TEST_HOME/.radin/hosts/claude/lib/radin-run.md"
  [ "$output" = 0 ]
  grep -q 'Claude Code decides foreground or background' "$TEST_HOME/.radin/hosts/claude/lib/radin-run.md"
}

# The golden stores sums, so a failure names the file and both sums, not the lines.
@test "golden render of the Claude install is unchanged" {
  replay_install >/dev/null
  local golden="$REPO_ROOT/tests/golden-claude-render.sha256"
  local now="$BATS_TEST_TMPDIR/golden-now"
  "$REPO_ROOT/scripts/golden-render.sh" "$TEST_HOME" >"$now"
  if [ -n "${GOLDEN_UPDATE:-}" ]; then
    cp "$now" "$golden"
    return 0
  fi
  run diff -u "$golden" "$now"
  if [ "$status" -ne 0 ]; then
    echo "$output"
    false
  fi
}

@test "golden render check fails when an installed skill changes" {
  replay_install >/dev/null
  echo "one more word" >>"$TEST_HOME/.claude/skills/radin-do/SKILL.md"
  "$REPO_ROOT/scripts/golden-render.sh" "$TEST_HOME" >"$BATS_TEST_TMPDIR/golden-now"
  run diff -u "$REPO_ROOT/tests/golden-claude-render.sha256" "$BATS_TEST_TMPDIR/golden-now"
  [ "$status" -eq 1 ]
  [[ "$output" == *"skills/radin-do/SKILL.md"* ]]
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
  # Effort tokens are written after the companion step, so a mid-run death leaves them.
  [ -z "$(grep -rl --include='*.md' 'RADIN_CLI\|RADIN_LIB\|RADIN_MODEL_' "$TEST_HOME/.claude/skills" "$TEST_HOME/.radin/lib")" ]
  grep -q 'radin:begin' "$TEST_HOME/.claude/CLAUDE.md"
}

# Every entry point is a skill, so it runs in the user's own thread. radin
# ships no agent: an install must never create ~/.claude/agents.
# A surviving RADIN_MODEL_ token would reach Claude as a literal model name and
# every dispatch would fail, so no installed file may keep one.
@test "writes a model into every sub-agent role, leaving no marker behind" {
  run_install_defaults
  run ! grep -rq --exclude=radin-doctor.sh 'RADIN_MODEL_\|RADIN_EFFORT_' "$TEST_HOME/.claude/skills" "$TEST_HOME/.radin/lib"
  grep -q 'effort: ""' "$TEST_HOME/.radin/hosts/claude/lib/radin-prompt-gate.md"
  grep -q '"effort_planning": ""' "$TEST_HOME/.radin/manifest.json"
  grep -q 'model: "sonnet"' "$TEST_HOME/.radin/hosts/claude/lib/radin-prompt-gate.md"
  grep -q 'model: "haiku"' "$TEST_HOME/.radin/hosts/claude/lib/radin-prompt-factfind.md"
  grep -q 'model-low: "haiku"' "$TEST_HOME/.radin/hosts/claude/lib/radin-prompt-execution.md"
}

# Two picks, one per model group: the major roles take the first, fact-finding
# and low-complexity tasks the second.
@test "two picks set the major and minor roles, even when a companion reads stdin" {
  export MOCK_NPX=eat-stdin
  cd "$REPO_ROOT" && run bash -c "printf '1\\n2\\n1\\n2\\n' | bash ./install.sh"
  [ "$status" -eq 0 ]
  grep -q '"model_planning": "opus"' "$TEST_HOME/.radin/manifest.json"
  grep -q '"model_low": "fable"' "$TEST_HOME/.radin/manifest.json"
  run ! grep -rq --exclude=radin-doctor.sh 'RADIN_MODEL_\|RADIN_EFFORT_' "$TEST_HOME/.claude/skills" "$TEST_HOME/.radin/lib"
  grep -q 'model: "opus"' "$TEST_HOME/.radin/hosts/claude/lib/radin-prompt-gate.md"
  grep -q 'model: "fable"' "$TEST_HOME/.radin/hosts/claude/lib/radin-prompt-factfind.md"
  grep -q 'model-low: "fable"' "$TEST_HOME/.radin/hosts/claude/lib/radin-prompt-execution.md"
}

# install.sh, radin-doctor.sh and radin-uninstall.sh each keep their own list
# of shipped files. Checking all three against one real install tree is what
# catches a file added to one list and forgotten in another.
@test "doctor finds and uninstall removes exactly what install ships" {
  run_install_defaults
  run bash "$TEST_HOME/.radin/lib/radin-doctor.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"All expected files present."* ]]
  [[ "$output" == *"no unsubstituted token left"* ]]
  run bash "$TEST_HOME/.radin/lib/radin-uninstall.sh"
  [ "$status" -eq 0 ]
  [ -z "$(find "$TEST_HOME/.radin/lib" "$TEST_HOME/.radin/hosts/claude/lib" "$TEST_HOME/.radin/bin" -type f)" ]
  [ -z "$(ls "$TEST_HOME/.claude/skills" | grep '^radin-')" ]
  [ -f "$TEST_HOME/.claude/skills/thermo-nuclear/SKILL.md" ]
}

@test "writes an install manifest listing installed files and companion tools" {
  run run_install_defaults
  [ "$status" -eq 0 ]
  manifest="$TEST_HOME/.radin/manifest.json"
  [ -f "$manifest" ]
  grep -q '"version"' "$manifest"
  for f in "$TEST_HOME"/.radin/lib/* "$TEST_HOME"/.claude/skills/radin-*; do
    grep -q "\"${f##*/}\"" "$manifest"
  done
  grep -q '"rtk": true' "$manifest"
  grep -q '"codebase-memory-mcp": false' "$manifest"
  run ! grep -q headroom "$manifest"
}

@test "installs unslop and technical-writing from upstream, minus the invocation block" {
  run_install_defaults >/dev/null
  for s in unslop technical-writing; do
    f="$TEST_HOME/.claude/skills/$s/SKILL.md"
    [ "$(head -c 3 "$f")" = "---" ]
    run ! grep -q 'disable-model-invocation' "$f"
    grep -q "\"$s\": true" "$TEST_HOME/.radin/manifest.json"
  done
}

@test "never overwrites a skill radin did not install" {
  mkdir -p "$TEST_HOME/.claude/skills/unslop"
  printf 'mine\n' >"$TEST_HOME/.claude/skills/unslop/SKILL.md"
  run real_install
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_HOME/.claude/skills/unslop/SKILL.md")" = mine ]
  [[ "$output" == *"unslop skipped"* ]]
  grep -q '"unslop": false' "$TEST_HOME/.radin/manifest.json"
  grep -q '"technical-writing": true' "$TEST_HOME/.radin/manifest.json"
}

@test "install removes the skills radin renamed and keeps a foreign one of that name" {
  for s in radin-execute radin-implement radin-show; do
    mkdir -p "$TEST_HOME/.claude/skills/$s"
    printf -- '---\nname: %s\n---\n' "$s" >"$TEST_HOME/.claude/skills/$s/SKILL.md"
  done
  mkdir -p "$TEST_HOME/.claude/skills/radin-run"
  printf -- '---\nname: mine\n---\n' >"$TEST_HOME/.claude/skills/radin-run/SKILL.md"
  run real_install
  [ "$status" -eq 0 ]
  [ ! -e "$TEST_HOME/.claude/skills/radin-execute" ]
  [ ! -e "$TEST_HOME/.claude/skills/radin-implement" ]
  [ ! -e "$TEST_HOME/.claude/skills/radin-show" ]
  [ -f "$TEST_HOME/.claude/skills/radin-run/SKILL.md" ]
  [ -f "$TEST_HOME/.claude/skills/radin-batch/SKILL.md" ]
}

@test "a failed pstack download keeps the installed copy and still exits 0" {
  replay_install >/dev/null
  printf 'kept\n' >"$TEST_HOME/.claude/skills/unslop/SKILL.md"
  export MOCK_CURL=pstack-fail
  run bash -c "printf '1\n1\n1\n' | bash ./install.sh --update"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_HOME/.claude/skills/unslop/SKILL.md")" = kept ]
  [[ "$output" == *"download failed"* ]]
  grep -q '"unslop": true' "$TEST_HOME/.radin/manifest.json"
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
  [ "$(cat "$TEST_HOME/.claude/.ponytail-band")" = off ]
  grep -q '"claude_md_guidance": true' "$TEST_HOME/.radin/manifest.json"
  # A re-run must not grow the file by one blank line each time.
  [ "$(wc -l < "$claude_md")" -eq "$before" ]
}

@test "installs the radin CLI dispatcher and the ~/.local/bin symlink" {
  # Asserted on the recorded tree: the symlink names its own $TEMPLATE home, so
  # a replay into another $HOME could not be checked.
  [ -x "$TEMPLATE/home/.radin/bin/radin" ]
  [ -L "$TEMPLATE/home/.local/bin/radin" ]
  [ "$(readlink "$TEMPLATE/home/.local/bin/radin")" = "$TEMPLATE/home/.radin/bin/radin" ]
  grep -q '"cli_on_path": true' "$TEMPLATE/home/.radin/manifest.json"
}

@test "layout: .md only under hosts/claude/lib, neutral files only under lib, no ~/.claude/.radin" {
  run_install_defaults >/dev/null
  [ -z "$(find "$TEST_HOME/.radin/lib" -name '*.md')" ]
  [ -z "$(find "$TEST_HOME/.radin/hosts/claude/lib" -type f ! -name '*.md')" ]
  [ -f "$TEST_HOME/.radin/hosts/claude/lib/radin-run.md" ]
  [ ! -e "$TEST_HOME/.claude/.radin" ]
}

@test "manifest lists the rendered libs under hostlib" {
  grep -q '"hostlib": \[.*"radin-run.md"' "$TEMPLATE/home/.radin/manifest.json"
}

@test "a ~/.local/bin/radin link to the legacy dispatcher is relinked" {
  mkdir -p "$TEST_HOME/.local/bin"
  ln -s "$TEST_HOME/.claude/.radin/bin/radin" "$TEST_HOME/.local/bin/radin"
  run real_install
  [ "$status" -eq 0 ]
  [ "$(readlink "$TEST_HOME/.local/bin/radin")" = "$TEST_HOME/.radin/bin/radin" ]
  grep -q '"cli_on_path": true' "$TEST_HOME/.radin/manifest.json"
}

# Skills carry a RADIN_CLI token; set_cli resolves it to whichever invocation
# works. The test PATH lacks ~/.local/bin, so even with the symlink the full
# dispatcher path is written -- bare `radin` would break every skill here.
@test "RADIN_CLI resolves to the full path when ~/.local/bin is off PATH" {
  run_install_defaults
  run ! grep -rq --exclude=radin-doctor.sh 'RADIN_CLI' "$TEST_HOME/.claude/skills" "$TEST_HOME/.radin/lib"
  grep -q '"$HOME/.radin/bin/radin" backlog' "$TEST_HOME/.radin/hosts/claude/lib/radin-run.md"
}

# radin-batch and radin-do read lib docs with the Read tool, which
# takes no `$HOME`. set_lib resolves RADIN_LIB at install time, so the installed
# files carry a path Read accepts. The replayed tree was installed under
# $TEMPLATE/home, which is the HOME the recorded run resolved against.
@test "RADIN_LIB resolves to the installed lib directory" {
  run_install_defaults
  run_doc="$TEST_HOME/.radin/hosts/claude/lib/radin-run.md"
  run ! grep -rq 'RADIN_LIB' "$TEST_HOME/.claude/skills" "$run_doc"
  run ! grep -q '$HOME/.radin/lib' "$run_doc"
  grep -q "$TEMPLATE/home/.radin/hosts/claude/lib/radin-batch-clarify.md" "$run_doc"
  grep -q "$TEMPLATE/home/.radin/hosts/claude/lib/radin-batch-gate.md" "$run_doc"
  run ! grep -q 'full check suite' "$run_doc"
  for s in radin-batch radin-do; do
    grep -q "$TEMPLATE/home/.radin/hosts/claude/lib/radin-run.md" "$TEST_HOME/.claude/skills/$s/SKILL.md"
  done
}

@test "the dispatcher routes subcommands to the installed lib scripts" {
  run_install_defaults
  # cd out of the repo: namespace resolution would otherwise count radin's own backlog.
  cd "$TEST_HOME"
  run env HOME="$TEST_HOME" bash "$TEST_HOME/.radin/bin/radin" backlog count
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
  run env HOME="$TEST_HOME" bash "$TEST_HOME/.radin/bin/radin" nope
  [ "$status" -ne 0 ]
}

@test "radin help prints the usage text, bare radin off a tty fails with it" {
  run_install_defaults
  run env HOME="$TEST_HOME" bash "$TEST_HOME/.radin/bin/radin" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"usage: radin"* ]]
  # `run` captures stdout through a pipe, so this is the non-tty path.
  run env HOME="$TEST_HOME" bash "$TEST_HOME/.radin/bin/radin"
  [ "$status" -ne 0 ]
  [[ "$output" == *"usage: radin"* ]]
}

@test "bare radin on a tty opens the TUI" {
  run_install_defaults
  pty_build || skip "a C compiler is needed to build the pty driver"
  cd "$TEST_HOME"
  run env HOME="$TEST_HOME" "$PTY_RUN" "$TEST_HOME/screen" "q" \
    bash "$TEST_HOME/.radin/bin/radin"
  [ "$status" -eq 0 ]
  run cat "$TEST_HOME/screen"
  [[ "$output" == *"no tasks"* ]]
}

# install is the one path that touches companions, so a tool already on PATH
# still takes its install/upgrade command instead of being skipped.
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
  [ -z "$(grep no-auto-update "$TEST_HOME/brew.log")" ]
  grep -q 'skills@latest add' "$TEST_HOME/npx.log"
  [[ "$output" == *"reported a failure while configuring Claude Code"* ]]
  [[ "$output" == *"cbm-config.log"* ]]
  [[ "$output" != *"OpenCode:"* ]]
  [[ "$output" != *"hooks: SessionStart"* ]]
  [[ "$output" != *"wired: skill"* ]]
  grep -q '^PARTIAL ' "$TEST_HOME/.radin/cbm-config.log"
  grep -q 'OpenCode:' "$TEST_HOME/.radin/cbm-config.log"
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

# A release tag predates files that main's SHIPPED_LIB names, so a piped
# install.sh from main must download main, never the latest release.
@test "a piped install downloads main, not the latest release" {
  FAKE_ROOT="$TEST_HOME/fake-checkout"
  mkdir -p "$FAKE_ROOT"
  cp "$REPO_ROOT/install.sh" "$FAKE_ROOT/install.sh"
  cd "$FAKE_ROOT"
  run bash -c "RADIN_ROOT_OVERRIDE='$TEST_HOME/fetched' bash ./install.sh --yes"
  grep -q 'refs/heads/main.tar.gz' "$TEST_HOME/curl.log"
  run ! grep -q 'refs/tags' "$TEST_HOME/curl.log"
}

# --yes is how one command reproduces this machine on the next one: the three
# behaviour questions take their defaults instead of blocking on a terminal.
@test "--yes asks nothing and still installs everything" {
  cd "$REPO_ROOT" && run bash ./install.sh --yes
  [ "$status" -eq 0 ]
  grep -q "install rtk" "$BREW_LOG"
  [[ "$output" != *"Pick 1-"* ]]
  manifest="$TEST_HOME/.radin/manifest.json"
  grep -q '"rtk": true' "$manifest"
  # The guidance block is part of "same stack on the next machine".
  grep -q '"claude_md_guidance": true' "$manifest"
  grep -q '<!-- radin:begin -->' "$TEST_HOME/.claude/CLAUDE.md"
}

# The package-manager pick is what keeps radin off a manager the user doesn't
# use: picking mise must install rtk through mise, never brew, and
# the answer must survive into the manifest so `radin update` keeps it.
@test "picking mise installs rtk through mise, not brew" {
  ln "$MOCK_BIN/mock" "$MOCK_BIN/mise" 2>/dev/null || ln -s "$MOCK_BIN/mock" "$MOCK_BIN/mise"
  cd "$REPO_ROOT" && run bash -c "printf '2\n2\n' | bash ./install.sh"
  [ "$status" -eq 0 ]
  [[ "$(cat "$TEST_HOME/mise.log")" == *"aqua:rtk-ai/rtk"* ]]
  [[ "$(cat "$TEST_HOME/mise.log")" != *"headroom"* ]]
  [ ! -s "$TEST_HOME/brew.log" ] || [[ "$(cat "$TEST_HOME/brew.log")" != *"install rtk"* ]]
  grep -q '"package_manager": "mise"' "$TEST_HOME/.radin/manifest.json"
}

# ponytail's SubagentStart hook is what puts its ladder in every execution
# sub-agent, and a plugin's hooks run only while it is enabled at user scope.
@test "a plugin installed but disabled gets enabled, and a failed enable warns" {
  printf '  ❯ ponytail@ponytail\n    Version: 4.10.0\n    Scope: user\n    Status: ✘ disabled\n' > "$TEST_HOME/plugins.txt"
  export MOCK_CLAUDE_LIST="$TEST_HOME/plugins.txt"
  cd "$REPO_ROOT" && run bash ./install.sh --yes
  [ "$status" -eq 0 ]
  [[ "$(cat "$TEST_HOME/claude.log")" == *"plugin enable --scope user ponytail@ponytail"* ]]
  [[ "$output" == *"ponytail is installed but disabled"* ]]
  [[ "$(cat "$TEST_HOME/claude.log")" != *"plugin enable --scope user caveman@caveman"* ]]
}

# A companion tool that fails must not abort radin's own install -- set -e used
# to kill the script the moment a companion install failed. Plugins install
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

# `radin update` runs install.sh --update: every step and question, except
# that a companion already installed is not reinstalled. Its configuration
# (thermo-nuclear's frontmatter, codebase-memory-mcp's settings.json wiring)
# still runs, and a missing companion still installs. The package-manager
# answer comes from the manifest the previous install wrote.
@test "--update reconfigures every companion and installs only the missing ones" {
  replay_install >/dev/null
  manifest="$TEST_HOME/.radin/manifest.json"
  grep -q '"package_manager": "brew"' "$manifest"
  rm -f "$TEST_HOME"/*.log
  for t in rtk codebase-memory-mcp; do
    ln "$MOCK_BIN/mock" "$MOCK_BIN/$t" 2>/dev/null || ln -s "$MOCK_BIN/mock" "$MOCK_BIN/$t"
  done
  mkdir -p "$TEST_HOME/.claude/skills/thermo-nuclear"
  printf -- '---\ndisable-model-invocation: true\n---\n' >"$TEST_HOME/.claude/skills/thermo-nuclear/SKILL.md"
  for p in caveman@caveman ponytail@ponytail mattpocock-skills@claude-plugins-official; do
    printf '  ❯ %s\n    Scope: user\n    Status: ✔ enabled\n' "$p"
  done >"$TEST_HOME/plugins.txt"
  export MOCK_CLAUDE_LIST="$TEST_HOME/plugins.txt"

  sed -e 's/"model_planning": "[a-z]*"/"model_planning": "opus"/' \
    -e 's/"model_factfind": "[a-z]*"/"model_factfind": "fable"/' "$manifest" >"$manifest.new"
  mv "$manifest.new" "$manifest"

  run bash -c "printf '' | bash ./install.sh --update"
  [ "$status" -eq 0 ]
  [[ "$output" == *"keeping sub-agent models: opus, fable for fact-finding and low-complexity tasks"* ]]
  grep -q 'opus' "$TEST_HOME/.radin/hosts/claude/lib/radin-prompt-planning.md"
  grep -q '"package_manager": "brew"' "$manifest"
  [ ! -e "$TEST_HOME/brew.log" ]
  [ ! -e "$TEST_HOME/npx.log" ]
  run ! grep -v 'pstack/skills/' "$TEST_HOME/curl.log"
  run ! grep -q 'disable-model-invocation' "$TEST_HOME/.claude/skills/thermo-nuclear/SKILL.md"
  grep -q 'config set auto_index true' "$TEST_HOME/codebase-memory-mcp.log"
  grep -q '"cbm_agent_config": true' "$manifest"
  # Upstream's wiring ships no CLAUDE.md text, so without radin's section no
  # agent is ever told the graph tools exist.
  grep -q '## MCP Tools: codebase-memory-mcp' "$TEST_HOME/.claude/CLAUDE.md"
  run ! grep -qE 'install|update|marketplace' "$TEST_HOME/claude.log"
}

@test "the install records its source root for radin update" {
  run run_install_defaults
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_HOME/.radin/install_root")" = "$REPO_ROOT" ]
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

@test "migration moves ~/.claude/.radin to ~/.radin and drops the old Read rules" {
  use_real_cc
  seed_old_layout
  run real_install
  [ "$status" -eq 0 ]
  [[ "$output" == *"moved ~/.claude/.radin to ~/.radin"* ]]
  [[ "$output" == *"restart open Claude sessions: they hold the old path"* ]]
  assert_migrated
}

@test "migration works when ~/.claude is a symlink" {
  use_real_cc
  seed_old_layout "$TEST_HOME/elsewhere"
  run real_install
  [ "$status" -eq 0 ]
  [ ! -e "$TEST_HOME/elsewhere/.radin" ]
  assert_migrated
  run grep -cF "/elsewhere/.radin" "$TEST_HOME/.claude/settings.json"
  [ "$output" = 0 ]
}

@test "a half-migrated machine keeps the old directory, says so, and drops the old Read rules" {
  use_real_cc
  seed_old_layout
  mkdir -p "$TEST_HOME/.radin"
  cp "$TEST_HOME/.claude/.radin/manifest.json" "$TEST_HOME/.radin/manifest.json"
  run real_install
  [ "$status" -eq 0 ]
  [[ "$output" == *"is still there, unused"* ]]
  [[ "$output" != *"restart open Claude sessions"* ]]
  [ "$(cat "$TEST_HOME/.claude/.radin/backups/snap/settings.json")" = sentinel ]
  run grep -cF '/.claude/.radin' "$TEST_HOME/.claude/settings.json"
  [ "$output" = 0 ]
  grep -qF "Read(/$TEST_HOME/.radin/**)" "$TEST_HOME/.claude/settings.json"
}

@test "a foreign ~/.radin stops the install before any write" {
  seed_old_layout
  mkdir -p "$TEST_HOME/.radin"
  echo mine >"$TEST_HOME/.radin/keep.txt"
  run real_install
  [ "$status" -ne 0 ]
  [[ "$output" == *"not radin's: move it away"* ]]
  [ "$(cat "$TEST_HOME/.radin/keep.txt")" = mine ]
  [ -f "$TEST_HOME/.claude/.radin/manifest.json" ]
  [ ! -e "$TEST_HOME/.claude/skills/radin-batch" ]
}

@test "a failed mv or a leftover staging directory leaves the old directory intact" {
  seed_old_layout
  cat >"$MOCK_BIN/mv" <<'SH'
#!/bin/sh
if [ ! -e "$MOCK_LOG_DIR/mv.called" ]; then
  : >"$MOCK_LOG_DIR/mv.called"
  mkdir -p "$2"
  exit 1
fi
exec /bin/mv "$@"
SH
  chmod +x "$MOCK_BIN/mv"
  run real_install
  [ "$status" -ne 0 ]
  [[ "$output" == *"mv failed"* ]]
  [ -f "$TEST_HOME/.claude/.radin/manifest.json" ]
  [ ! -e "$TEST_HOME/.radin" ]
  [ ! -e "$TEST_HOME/.claude/skills/radin-batch" ]
  rm -f "$MOCK_BIN/mv"
  run real_install
  [ "$status" -ne 0 ]
  [[ "$output" == *"$TEST_HOME/.radin.migrating was left by an interrupted move"* ]]
  [ -f "$TEST_HOME/.claude/.radin/manifest.json" ]
  [ ! -e "$TEST_HOME/.radin" ]
}

@test "an installed pre-~/.radin radin update still reaches the migrating install.sh" {
  use_real_cc
  seed_old_layout
  cp "$REPO_ROOT/tests/fixtures/radin-update-legacy.sh" "$TEST_HOME/.claude/.radin/lib/radin-update.sh"
  local upstream="$TEST_HOME/upstream" clone="$TEST_HOME/clone"
  git init -q --bare "$upstream"
  git init -q "$clone"
  git -C "$clone" config user.email t@t
  git -C "$clone" config user.name t
  printf '#!/bin/sh\nexec bash "%s/install.sh" "$@"\n' "$REPO_ROOT" >"$clone/install.sh"
  git -C "$clone" add install.sh
  git -C "$clone" commit -qm init
  git -C "$clone" remote add origin "$upstream"
  git -C "$clone" push -q -u origin HEAD:main
  echo "$clone" >"$TEST_HOME/.claude/.radin/install_root"
  run bash -c 'printf "2\n" | bash "$HOME/.claude/.radin/lib/radin-update.sh" --yes'
  [ "$status" -eq 0 ]
  [ ! -e "$TEST_HOME/.claude/.radin" ]
  grep -q '"installed_at"' "$TEST_HOME/.radin/manifest.json"
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

# A copy of the repo to install from. Two files still fail every agents install:
# skills/radin-uninstall holds the baselined "~/.claude" (hosts/forbid-baseline.txt),
# and lib/radin-batch-recovery.md keeps RADIN_MODEL_ and RADIN_EFFORT_ tokens in its
# agents render. The seds stand in for the host blocks that will wrap them, and
# do nothing once the strings are gone.
agents_root() {
  AROOT="$BATS_TEST_TMPDIR/root"
  mkdir -p "$AROOT"
  (cd "$REPO_ROOT" && cp -R install.sh bin lib skills scripts hosts "$AROOT/")
  sed 's|~/\.claude|the host skills dir|g' "$AROOT/skills/radin-uninstall/SKILL.md" >"$AROOT/tmp.md"
  mv "$AROOT/tmp.md" "$AROOT/skills/radin-uninstall/SKILL.md"
  sed 's|`model: "RADIN_MODEL_REVIEW"`, `effort: "RADIN_EFFORT_REVIEW"`, ||' "$AROOT/lib/radin-batch-recovery.md" >"$AROOT/tmp.md"
  mv "$AROOT/tmp.md" "$AROOT/lib/radin-batch-recovery.md"
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

@test "no flag and no terminal installs claude only, even with codex on PATH" {
  mock_cli codex
  cd "$REPO_ROOT" && run bash -c "printf '2\n' | bash ./install.sh"
  [ "$status" -eq 0 ]
  [ "$(manifest_array hosts)" = '"claude"' ]
  [ "$(manifest_array agents_clis)" = '' ]
  [ ! -e "$TEST_HOME/.agents" ]
  [ ! -e "$TEST_HOME/.radin/hosts/agents" ]
  grep -q '"manifest_version": 2' "$TEST_HOME/.radin/manifest.json"
}

@test "--only codex installs the agents render and nothing under ~/.claude" {
  mock_cli codex
  agents_root
  run install_from "$AROOT" --yes --only codex
  [ "$status" -eq 0 ]
  [ -f "$TEST_HOME/.agents/skills/radin-batch/SKILL.md" ]
  [ -f "$TEST_HOME/.radin/hosts/agents/lib/radin-run.md" ]
  assert_no_agents_marker
  [ ! -e "$TEST_HOME/.claude/skills/radin-batch" ]
  [ ! -e "$TEST_HOME/.claude/CLAUDE.md" ]
  [ ! -e "$TEST_HOME/.radin/hosts/claude" ]
  [ "$(manifest_array hosts)" = '"codex"' ]
  [ "$(manifest_array agents_clis)" = '"codex"' ]
}

@test "--only opencode records opencode as the agents CLI" {
  mock_cli opencode
  agents_root
  run install_from "$AROOT" --yes --only=opencode
  [ "$status" -eq 0 ]
  [ -f "$TEST_HOME/.agents/skills/radin-batch/SKILL.md" ]
  assert_no_agents_marker
  [ "$(manifest_array hosts)" = '"opencode"' ]
  [ "$(manifest_array agents_clis)" = '"opencode"' ]
}

@test "--only with all three hosts builds both renders and the agents step runs once" {
  mock_cli codex
  mock_cli opencode
  agents_root
  run install_from "$AROOT" --yes --only opencode,claude,codex,claude
  [ "$status" -eq 0 ]
  [ -f "$TEST_HOME/.claude/skills/radin-batch/SKILL.md" ]
  [ -f "$TEST_HOME/.agents/skills/radin-batch/SKILL.md" ]
  [ -f "$TEST_HOME/.radin/hosts/claude/lib/radin-run.md" ]
  [ -f "$TEST_HOME/.radin/hosts/agents/lib/radin-run.md" ]
  [ "$(printf '%s\n' "$output" | grep -c 'agents render installed')" = 1 ]
  [ "$(manifest_array hosts)" = '"claude", "codex", "opencode"' ]
  [ "$(manifest_array agents_clis)" = '"codex", "opencode"' ]
  assert_no_agents_marker
}

@test "--update keeps the manifest hosts and asks nothing" {
  mock_cli codex
  agents_root
  install_from "$AROOT" --yes --only codex >/dev/null
  rm -f "$TEST_HOME"/*.log
  run install_from "$AROOT" --update
  [ "$status" -eq 0 ]
  [[ "$output" != *"Pick 1-"* ]]
  [ "$(manifest_array hosts)" = '"codex"' ]
  [ ! -e "$TEST_HOME/.claude/skills" ]
}

@test "--update on a v1 manifest reads it as claude only" {
  replay_install >/dev/null
  local m="$TEST_HOME/.radin/manifest.json"
  sed -e '/"manifest_version"/d' -e '/"hosts"/d' -e '/"agents_clis"/d' \
    -e '/"files": {/,/^  }/d' -e 's/^  },$/  }/' "$m" >"$m.new"
  mv "$m.new" "$m"
  [ -z "$(manifest_array hosts)" ]
  cd "$REPO_ROOT" && run bash ./install.sh --update </dev/null
  [ "$status" -eq 0 ]
  [ "$(manifest_array hosts)" = '"claude"' ]
  [ -f "$TEST_HOME/.claude/skills/radin-batch/SKILL.md" ]
}

# A new line in the copied root's lib/radin-run.md must reach exactly the renders of the manifest hosts.
update_marker() {
  printf '\nUPDATE-MARKER\n' >>"$AROOT/lib/radin-run.md"
}

@test "--update refreshes a claude-only install and touches no agents tree" {
  agents_root
  install_from "$AROOT" --yes --only claude >/dev/null
  update_marker
  run install_from "$AROOT" --update
  [ "$status" -eq 0 ]
  [[ "$output" != *"Pick 1-"* ]]
  grep -q UPDATE-MARKER "$TEST_HOME/.radin/hosts/claude/lib/radin-run.md"
  [ ! -e "$TEST_HOME/.agents" ]
  [ ! -e "$TEST_HOME/.radin/hosts/agents" ]
  [ "$(manifest_array hosts)" = '"claude"' ]
}

@test "--update refreshes an agents-only install and touches no claude tree" {
  mock_cli codex
  agents_root
  install_from "$AROOT" --yes --only codex >/dev/null
  update_marker
  run install_from "$AROOT" --update
  [ "$status" -eq 0 ]
  [[ "$output" != *"Pick 1-"* ]]
  grep -q UPDATE-MARKER "$TEST_HOME/.radin/hosts/agents/lib/radin-run.md"
  [ ! -e "$TEST_HOME/.radin/hosts/claude" ]
  [ "$(manifest_array hosts)" = '"codex"' ]
}

@test "--update refreshes both renders of a claude plus codex install" {
  mock_cli codex
  agents_root
  install_from "$AROOT" --yes --only claude,codex >/dev/null
  update_marker
  run install_from "$AROOT" --update
  [ "$status" -eq 0 ]
  [[ "$output" != *"Pick 1-"* ]]
  grep -q UPDATE-MARKER "$TEST_HOME/.radin/hosts/claude/lib/radin-run.md"
  grep -q UPDATE-MARKER "$TEST_HOME/.radin/hosts/agents/lib/radin-run.md"
  [ "$(manifest_array hosts)" = '"claude", "codex"' ]
}

@test "--update reports an edited agents skill and keeps the edit" {
  mock_cli codex
  agents_root
  install_from "$AROOT" --yes --only codex >/dev/null
  local f="$TEST_HOME/.agents/skills/radin-do/SKILL.md"
  printf 'my edit\n' >>"$f"
  run install_from "$AROOT" --update
  [ "$status" -eq 0 ]
  [[ "$output" == *"kept $f"* ]]
  grep -qx 'my edit' "$f"
}

# Forbidden in the agents render only: the claude render of the same line is fine.
break_agents_render() {
  printf '\nAskUserQuestion\n' >>"$AROOT/lib/radin-run.md"
}

@test "--update leaves a host whose render fails untouched, records it, and retries it next time" {
  mock_cli codex
  agents_root
  install_from "$AROOT" --yes --only claude,codex >/dev/null
  local before after d
  d="$(manifest_digest_of .agents/skills/radin-do/SKILL.md)"
  before="$(home_sum | grep -E '\./\.agents|\./\.radin/hosts/agents')"
  cp "$AROOT/lib/radin-run.md" "$BATS_TEST_TMPDIR/run.md"
  update_marker
  break_agents_render
  run install_from "$AROOT" --update
  [ "$status" -eq 0 ]
  [[ "$output" == *"agents render failed"* ]]
  grep -q UPDATE-MARKER "$TEST_HOME/.radin/hosts/claude/lib/radin-run.md"
  after="$(home_sum | grep -E '\./\.agents|\./\.radin/hosts/agents')"
  [ "$before" = "$after" ]
  [ "$(manifest_array hosts)" = '"claude", "codex"' ]
  [ "$(manifest_array agents_clis)" = '"codex"' ]
  [ "$(manifest_digest_of .agents/skills/radin-do/SKILL.md)" = "$d" ]
  [ -n "$d" ]
  grep -q '"codex_guidance": true' "$TEST_HOME/.radin/manifest.json"
  cp "$BATS_TEST_TMPDIR/run.md" "$AROOT/lib/radin-run.md"
  update_marker
  run install_from "$AROOT" --update
  [ "$status" -eq 0 ]
  grep -q UPDATE-MARKER "$TEST_HOME/.radin/hosts/agents/lib/radin-run.md"
}

@test "--update holds a host whose path radin does not own" {
  mock_cli codex
  agents_root
  install_from "$AROOT" --yes --only claude,codex >/dev/null
  sed -i.bak '/"\.agents\/skills\/radin-do\/SKILL.md"/d' "$TEST_HOME/.radin/manifest.json"
  local before after
  before="$(home_sum | grep -E '\./\.agents|\./\.radin/hosts/agents')"
  update_marker
  run install_from "$AROOT" --update
  [ "$status" -eq 0 ]
  [[ "$output" == *"radin did not install it"* ]]
  after="$(home_sum | grep -E '\./\.agents|\./\.radin/hosts/agents')"
  [ "$before" = "$after" ]
  [ "$(manifest_array hosts)" = '"claude", "codex"' ]
}

@test "--update takes curl for rtk, without a question, when the manifest has no package manager" {
  mock_cli codex
  agents_root
  install_from "$AROOT" --yes --only codex >/dev/null
  sed -i.bak '/"package_manager"/d' "$TEST_HOME/.radin/manifest.json"
  run install_from "$AROOT" --update
  [ "$status" -eq 0 ]
  [[ "$output" != *"Pick 1-"* ]]
  grep -q '"package_manager": "curl"' "$TEST_HOME/.radin/manifest.json"
}

@test "--dry-run lists the writes the real run makes and changes nothing" {
  mock_cli codex
  agents_root
  local before after
  before="$(find "$TEST_HOME" | sort)"
  run install_from "$AROOT" --yes --dry-run --only claude,codex
  [ "$status" -eq 0 ]
  after="$(find "$TEST_HOME" | sort)"
  [ "$before" = "$after" ]
  [ ! -e "$TEST_HOME/curl.log" ]
  [[ "$output" == *"hosts: claude codex"* ]]
  [[ "$output" == *"run claude plugin install ponytail@ponytail"* ]]
  printf '%s\n' "$output" | sed -n 's/^write //p' |
    grep -E "^$TEST_HOME/(\.radin/(lib|hosts)/|\.claude/skills/|\.agents/skills/)|^$TEST_HOME/\.radin/bin/radin$" |
    sort >"$BATS_TEST_TMPDIR/dry"
  install_from "$AROOT" --yes --only claude,codex >/dev/null
  manifest_file_keys | sed "s|^|$TEST_HOME/|" | sort >"$BATS_TEST_TMPDIR/real"
  [ -s "$BATS_TEST_TMPDIR/real" ]
  diff "$BATS_TEST_TMPDIR/dry" "$BATS_TEST_TMPDIR/real"
}

@test "a piped --dry-run names the download and fetches nothing" {
  local fake="$TEST_HOME/fake"
  mkdir -p "$fake"
  cp "$REPO_ROOT/install.sh" "$fake/install.sh"
  run install_from "$fake" --dry-run --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"would download https://github.com/shortcuts/radin/archive/refs/heads/main.tar.gz"* ]]
  [ ! -e "$TEST_HOME/curl.log" ]
  [ ! -e "$TEST_HOME/.radin" ]
}

@test "--list prints one row per host and writes nothing" {
  run bash "$REPO_ROOT/install.sh" --list
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" = 3 ]
  [ "${lines[0]}" = "$(printf 'claude\tClaude Code\tyes')" ]
  [ "${lines[1]}" = "$(printf 'codex\tCodex CLI\tno')" ]
  [ "${lines[2]}" = "$(printf 'opencode\topencode\tno')" ]
  mock_cli codex
  run bash "$REPO_ROOT/install.sh" --list
  [ "${lines[1]}" = "$(printf 'codex\tCodex CLI\tyes')" ]
  [ -z "$(ls -A "$TEST_HOME")" ]
}

@test "a selected host without its CLI warns, installs radin's files and records the host" {
  agents_root
  run install_from "$AROOT" --yes --only codex
  [ "$status" -eq 0 ]
  [[ "$output" == *"codex CLI not found"* ]]
  [ -f "$TEST_HOME/.agents/skills/radin-batch/SKILL.md" ]
  [ "$(manifest_array hosts)" = '"codex"' ]
  [ "$(manifest_array agents_clis)" = '"codex"' ]
}

@test "an unknown host id or flag exits 2 before any write" {
  run bash "$REPO_ROOT/install.sh" --only cursor
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage: install.sh"* ]]
  run bash "$REPO_ROOT/install.sh" --onyl codex
  [ "$status" -eq 2 ]
  run bash "$REPO_ROOT/install.sh" --only ''
  [ "$status" -eq 2 ]
  [ -z "$(ls -A "$TEST_HOME")" ]
}

@test "every manifest files entry holds the digest of the installed file" {
  mock_cli codex
  agents_root
  install_from "$AROOT" --yes --only claude,codex >/dev/null
  local key digest n=0
  while IFS= read -r key; do
    digest="$(sed -n 's|^    "'"$key"'": "\(.*\)",\{0,1\}$|\1|p' "$TEST_HOME/.radin/manifest.json")"
    [ -n "$digest" ]
    [ "$(sha256_file "$TEST_HOME/$key")" = "$digest" ]
    n=$((n + 1))
  done < <(manifest_file_keys)
  [ "$n" -gt 40 ]
  manifest_file_keys | grep -qx '.agents/skills/radin-batch/SKILL.md'
  manifest_file_keys | grep -qx '.claude/skills/radin-batch/SKILL.md'
  manifest_file_keys | grep -qx '.radin/bin/radin'
}

@test "an agents render that fails the forbid check leaves codex out and claude in" {
  mock_cli codex
  agents_root
  printf 'AskUserQuestion\n' >>"$AROOT/lib/radin-run.md"
  run install_from "$AROOT" --yes --only claude,codex
  [ "$status" -eq 0 ]
  [[ "$output" == *"agents render failed"* ]]
  [[ "$output" == *"radin-run.md"* ]]
  [ "$(manifest_array hosts)" = '"claude"' ]
  [ "$(manifest_array agents_clis)" = '' ]
  [ ! -e "$TEST_HOME/.agents" ]
  [ ! -e "$TEST_HOME/.radin/hosts/agents" ]
  [ -f "$TEST_HOME/.claude/skills/radin-batch/SKILL.md" ]
}

# The host question reads the terminal, so it runs through a pty. Extracting the
# functions from install.sh keeps them single-sourced there, as pick_with_keys does.
host_prompt_hosts() {
  pty_build || skip "a C compiler is needed to build the pty driver"
  mock_cli codex
  local snippet="$TEST_HOME/hosts.sh" out="$TEST_HOME/selected"
  {
    sed -n '/^HOSTS=/,/^while \[ \$# -gt 0 \]/p' "$REPO_ROOT/install.sh" | sed '$d'
    sed -n '/^_pick_nth() {/,/^prompt_yn() {/p' "$REPO_ROOT/install.sh" | sed '$d'
    sed -n '/^have_tty() {/,/^select_hosts$/p' "$REPO_ROOT/install.sh" | sed '$d'
  } >"$snippet"
  "$PTY_RUN" "$TEST_HOME/screen" "$1" bash -c \
    "YES=''; UPDATE=''; ONLY_SET=''; RAT=''; BOLD=''; DIM=''; CYAN=''; YELLOW=''; RED=''; RESET=''; \
     info() { :; }; source '$snippet'; select_hosts; echo \"\$SELECTED\" > '$out'" >/dev/null 2>&1
  SELECTED_HOSTS="$(cat "$out" 2>/dev/null || true)"
}

@test "a terminal run offers each detected host and installs the ones answered yes" {
  host_prompt_hosts '\r|k|\r'
  [ "$SELECTED_HOSTS" = "claude codex" ]
}

@test "a terminal run keeps claude only when codex is answered no" {
  host_prompt_hosts '\r|\r'
  [ "$SELECTED_HOSTS" = "claude" ]
}

@test "a terminal run can deselect claude" {
  host_prompt_hosts 'j\r|k\r'
  [ "$SELECTED_HOSTS" = "codex" ]
}

@test "a terminal run that answers no to every host exits before any write" {
  host_prompt_hosts 'j\r|\r'
  [ -z "$SELECTED_HOSTS" ]
  [ ! -e "$TEST_HOME/.radin" ]
}

# Ownership: the preflight, kept edits and --force backups.

home_sum() {
  (cd "$TEST_HOME" && find . -type f | sort | while IFS= read -r f; do printf '%s %s\n' "$f" "$(sha256_file "$f")"; done)
}

manifest_digest_of() {
  sed -n 's|^    "'"$1"'": "\(.*\)",\{0,1\}$|\1|p' "$TEST_HOME/.radin/manifest.json"
}

foreign_skill() {
  mkdir -p "$TEST_HOME/$1"
  printf 'mine\n' >"$TEST_HOME/$1/SKILL.md"
}

@test "an unowned skill stops the claude host and writes nothing" {
  agents_root
  foreign_skill .claude/skills/radin-batch
  local before
  before="$(home_sum)"
  run install_from "$AROOT" --yes --only claude
  [ "$status" -eq 1 ]
  [[ "$output" == *"exists and radin did not install it"* ]]
  [ "$before" = "$(home_sum)" ]
  [ ! -e "$TEST_HOME/.radin" ]
}

@test "an unowned claude skill drops claude and still installs codex" {
  mock_cli codex
  agents_root
  foreign_skill .claude/skills/radin-batch
  run install_from "$AROOT" --yes --only claude,codex
  [ "$status" -eq 0 ]
  [ "$(manifest_array hosts)" = '"codex"' ]
  [ "$(cat "$TEST_HOME/.claude/skills/radin-batch/SKILL.md")" = mine ]
  [ -f "$TEST_HOME/.agents/skills/radin-batch/SKILL.md" ]
}

@test "an unowned agents skill drops codex and opencode together" {
  mock_cli codex
  mock_cli opencode
  agents_root
  foreign_skill .agents/skills/radin-batch
  local before
  before="$(home_sum)"
  run install_from "$AROOT" --yes --only codex,opencode
  [ "$status" -eq 1 ]
  [[ "$output" == *"codex opencode skipped"* ]]
  [ "$before" = "$(home_sum)" ]
}

@test "--force backs an unowned skill up under ~/.radin/backups and records it" {
  agents_root
  foreign_skill .claude/skills/radin-batch
  run install_from "$AROOT" --yes --only claude --force
  [ "$status" -eq 0 ]
  local backup
  backup="$(find "$TEST_HOME/.radin/backups" -path '*/.claude/skills/radin-batch/SKILL.md')"
  [ "$(cat "$backup")" = mine ]
  [ "$(head -c 3 "$TEST_HOME/.claude/skills/radin-batch/SKILL.md")" = "---" ]
  grep -q '"backups": {' "$TEST_HOME/.radin/manifest.json"
  grep -q '": ".claude/skills/radin-batch"' "$TEST_HOME/.radin/manifest.json"
  [ ! -e "$TEST_HOME/.claude/skills/radin-batch.bak" ]
}

@test "a re-run on an unchanged install rewrites no render file" {
  mock_cli codex
  agents_root
  install_from "$AROOT" --yes --only claude,codex >/dev/null
  touch "$BATS_TEST_TMPDIR/marker"
  sleep 1
  run install_from "$AROOT" --yes --update
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 written"* ]]
  run find "$TEST_HOME/.claude/skills"/radin-* "$TEST_HOME/.agents/skills"/radin-* "$TEST_HOME/.radin/hosts" -type f -newer "$BATS_TEST_TMPDIR/marker"
  [ -z "$output" ]
}

@test "a skill the user edited is kept, with its old digest, on every re-run" {
  agents_root
  install_from "$AROOT" --yes --only claude >/dev/null
  local f="$TEST_HOME/.claude/skills/radin-do/SKILL.md" d
  d="$(manifest_digest_of .claude/skills/radin-do/SKILL.md)"
  printf 'my edit\n' >>"$f"
  run install_from "$AROOT" --yes --update
  [ "$status" -eq 0 ]
  [[ "$output" == *"kept $f"* ]]
  grep -qx 'my edit' "$f"
  [ "$(manifest_digest_of .claude/skills/radin-do/SKILL.md)" = "$d" ]
  run install_from "$AROOT" --yes --update
  [[ "$output" == *"kept $f"* ]]
}

@test "--force replaces an edited skill and backs the edit up" {
  agents_root
  install_from "$AROOT" --yes --only claude >/dev/null
  local f="$TEST_HOME/.claude/skills/radin-do/SKILL.md"
  printf 'my edit\n' >>"$f"
  run install_from "$AROOT" --yes --update --force
  [ "$status" -eq 0 ]
  run grep -qx 'my edit' "$f"
  [ "$status" -eq 1 ]
  grep -qx 'my edit' "$(find "$TEST_HOME/.radin/backups" -path '*/.claude/skills/radin-do/SKILL.md')"
  [ "$(manifest_digest_of .claude/skills/radin-do/SKILL.md)" = "$(sha256_file "$f")" ]
}

@test "a v1 manifest owns its skills, so an update replaces them without a conflict" {
  agents_root
  install_from "$AROOT" --yes --only claude >/dev/null
  local m="$TEST_HOME/.radin/manifest.json" f="$TEST_HOME/.claude/skills/radin-do/SKILL.md"
  sed -e '/"manifest_version"/d' -e '/"hosts"/d' -e '/"agents_clis"/d' \
    -e '/"files": {/,/^  }/d' -e 's/^  },$/  }/' "$m" >"$m.new"
  mv "$m.new" "$m"
  printf 'my edit\n' >>"$f"
  run install_from "$AROOT" --yes --update
  [ "$status" -eq 0 ]
  [[ "$output" != *"did not install it"* ]]
  run grep -qx 'my edit' "$f"
  [ "$status" -eq 1 ]
}

@test "a claude render that fails leaves claude out and keeps codex" {
  mock_cli codex
  agents_root
  : >"$AROOT/lib/skill-names-claude.txt"
  run install_from "$AROOT" --yes --only claude,codex
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude render failed"* ]]
  [ "$(manifest_array hosts)" = '"codex"' ]
  [ ! -e "$TEST_HOME/.claude/skills/radin-batch" ]
  [ -f "$TEST_HOME/.agents/skills/radin-batch/SKILL.md" ]
}

@test "--dry-run reports a conflict and a kept edit and writes nothing" {
  agents_root
  foreign_skill .claude/skills/radin-batch
  local before
  before="$(home_sum)"
  run install_from "$AROOT" --yes --dry-run --only claude
  [ "$status" -eq 1 ]
  [[ "$output" == *"conflict $TEST_HOME/.claude/skills/radin-batch"* ]]
  [[ "$output" == *"skip host claude"* ]]
  [ "$before" = "$(home_sum)" ]
  rm -rf "$TEST_HOME/.claude"
  install_from "$AROOT" --yes --only claude >/dev/null
  printf 'my edit\n' >>"$TEST_HOME/.claude/skills/radin-do/SKILL.md"
  run install_from "$AROOT" --yes --dry-run --only claude
  [ "$status" -eq 0 ]
  [[ "$output" == *"keep $TEST_HOME/.claude/skills/radin-do/SKILL.md"* ]]
}

@test "all three hosts build the C helpers once" {
  mock_cli codex
  mock_cli opencode
  agents_root
  run install_from "$AROOT" --yes --only claude,codex,opencode
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$TEST_HOME/cc.log" | tr -d ' ')" = 2 ]
}

# Companion skills on the agents host: lib/companion-skills.txt, fetched by install.sh.

agents_skill_names() { awk '!/^#/ && NF { print $1 }' "$REPO_ROOT/lib/companion-skills.txt"; }

@test "agents host fetches every companion skill, strips the invocation block and keeps siblings" {
  mock_cli codex
  agents_root
  run install_from "$AROOT" --yes --only codex
  [ "$status" -eq 0 ]
  for n in $(agents_skill_names); do
    f="$TEST_HOME/.agents/skills/$n/SKILL.md"
    [ "$(head -c 3 "$f")" = "---" ]
    run ! grep -q 'disable-model-invocation' "$f"
    grep -qx "name: $n" "$f"
  done
  [ -f "$TEST_HOME/.agents/skills/codebase-design/DEEPENING.md" ]
  [ -f "$TEST_HOME/.agents/skills/codebase-design/DESIGN-IT-TWICE.md" ]
  [ -f "$TEST_HOME/.agents/skills/diagnosing-bugs/scripts/hitl-loop.template.sh" ]
  [ -f "$TEST_HOME/.agents/skills/writing-for-agents/SKILL-MECHANICS.md" ]
  [ "$(manifest_array agents_skills | tr ',' '\n' | grep -c .)" = 19 ]
  [ ! -e "$TEST_HOME/.claude" ]
}

@test "agents host leaves a skill radin did not install alone" {
  mock_cli codex
  agents_root
  mkdir -p "$TEST_HOME/.agents/skills/lean-build" "$TEST_HOME/.agents/skills/grilling"
  printf 'mine\n' >"$TEST_HOME/.agents/skills/lean-build/SKILL.md"
  run install_from "$AROOT" --yes --only codex
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_HOME/.agents/skills/lean-build/SKILL.md")" = mine ]
  [[ "$output" == *"grilling skipped"* ]]
  [ ! -e "$TEST_HOME/.agents/skills/grilling/SKILL.md" ]
  run ! grep -qE '"(lean-build|grilling)"' <<<"$(manifest_array agents_skills)"
}

@test "opencode's own skill dir counts as present and gets no second copy" {
  mock_cli opencode
  agents_root
  mkdir -p "$TEST_HOME/.config/opencode/skills/lean-build"
  printf 'mine\n' >"$TEST_HOME/.config/opencode/skills/lean-build/SKILL.md"
  run env XDG_CONFIG_HOME="$TEST_HOME/.config" bash -c "cd '$AROOT' && bash ./install.sh --yes --only opencode </dev/null"
  [ "$status" -eq 0 ]
  [ ! -e "$TEST_HOME/.agents/skills/lean-build" ]
  [ -f "$TEST_HOME/.agents/skills/safe-refactor/SKILL.md" ]
}

@test "a failed companion skill download warns, exits 0 and lets the other rows land" {
  mock_cli codex
  agents_root
  export MOCK_CURL_FAIL=/lean-build/
  run install_from "$AROOT" --yes --only codex
  [ "$status" -eq 0 ]
  [[ "$output" == *"lean-build download failed"* ]]
  [ ! -e "$TEST_HOME/.agents/skills/lean-build" ]
  [ -f "$TEST_HOME/.agents/skills/safe-refactor/SKILL.md" ]
  run ! grep -q '"lean-build"' <<<"$(manifest_array agents_skills)"
}

@test "a sibling download failure installs none of that skill's files" {
  mock_cli codex
  agents_root
  export MOCK_CURL_FAIL=DEEPENING.md
  run install_from "$AROOT" --yes --only codex
  [ "$status" -eq 0 ]
  [[ "$output" == *"codebase-design download failed"* ]]
  [ ! -e "$TEST_HOME/.agents/skills/codebase-design" ]
}

@test "--update refetches an owned skill, keeps it on a failed refetch and leaves a foreign one alone" {
  mock_cli codex
  agents_root
  install_from "$AROOT" --yes --only codex >/dev/null
  printf 'stale\n' >"$TEST_HOME/.agents/skills/ponytail/SKILL.md"
  printf 'kept\n' >"$TEST_HOME/.agents/skills/lean-build/SKILL.md"
  export MOCK_CURL_FAIL=/lean-build/
  run install_from "$AROOT" --update
  [ "$status" -eq 0 ]
  grep -qx 'name: ponytail' "$TEST_HOME/.agents/skills/ponytail/SKILL.md"
  [ "$(cat "$TEST_HOME/.agents/skills/lean-build/SKILL.md")" = kept ]
  [ "$(manifest_array agents_skills | tr ',' '\n' | grep -c .)" = 19 ]
  unset MOCK_CURL_FAIL
  sed -i.bak 's/"lean-build", //; s/, "lean-build"//' "$TEST_HOME/.radin/manifest.json"
  run install_from "$AROOT" --update
  [ "$(cat "$TEST_HOME/.agents/skills/lean-build/SKILL.md")" = kept ]
}

@test "--dry-run prints a curl line per file of each skill it would fetch and writes nothing" {
  mock_cli opencode
  agents_root
  run install_from "$AROOT" --yes --dry-run --only opencode
  [ "$status" -eq 0 ]
  [[ "$output" == *"run curl -fsSL https://raw.githubusercontent.com/JuliusBrussee/caveman/refs/heads/main/skills/lean-build/SKILL.md"* ]]
  [[ "$output" == *"/skills/engineering/codebase-design/DEEPENING.md"* ]]
  [ ! -e "$TEST_HOME/curl.log" ]
  [ ! -e "$TEST_HOME/.agents" ]
}

@test "a claude-only install fetches no agents companion skill" {
  run_install_defaults >/dev/null
  [ ! -e "$TEST_HOME/.agents" ]
  [ -z "$(manifest_array agents_skills)" ]
  run ! grep -v 'pstack/skills/' "$TEST_HOME/curl.log"
}

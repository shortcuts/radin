#!/usr/bin/env bats
# Exercises install.sh against an isolated $HOME with stubbed brew/curl/claude
# so the suite runs offline and never touches the real ~/.claude. PATH is
# reduced to MOCK_BIN + core system dirs so real rtk/code-review-graph/brew
# installs on the dev machine can't leak into "not installed" assertions.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

  TEST_HOME="$(mktemp -d)"
  MOCK_BIN="$(mktemp -d)"
  export HOME="$TEST_HOME"
  export PATH="$MOCK_BIN:/usr/bin:/bin:/usr/sbin:/sbin"

  BREW_LOG="$TEST_HOME/brew.log"
  # "install rtk" also drops a stub rtk binary on PATH, mirroring what a real
  # brew install would leave behind -- needed for manifest/companion-tool
  # reachability checks (command -v rtk) to see the install take effect.
  cat > "$MOCK_BIN/brew" <<EOF
#!/bin/sh
echo "\$@" >> "$BREW_LOG"
if [ "\$1" = "install" ] && [ "\$2" = "rtk" ]; then
  printf '#!/bin/sh\n' > "$MOCK_BIN/rtk"
  chmod +x "$MOCK_BIN/rtk"
fi
exit 0
EOF

  # -o file: write a byte so downstream steps that check the file exists pass.
  # No -o: emit nothing, matching an empty/absent GitHub API response.
  cat > "$MOCK_BIN/curl" <<'EOF'
#!/bin/sh
out=""
prev=""
for arg in "$@"; do
  if [ "$prev" = "-o" ]; then out="$arg"; fi
  prev="$arg"
done
if [ -n "$out" ]; then
  echo "mock" > "$out"
fi
exit 0
EOF

  cat > "$MOCK_BIN/claude" <<'EOF'
#!/bin/sh
if [ "$1" = "plugin" ] && [ "$2" = "list" ]; then exit 0; fi
exit 0
EOF

  PIP_LOG="$TEST_HOME/pip.log"
  # Mirrors the brew mock: "install headroom-ai[...]" drops a stub headroom
  # binary on PATH, needed for headroom's own manifest/reachability check.
  cat > "$MOCK_BIN/pipx" <<EOF
#!/bin/sh
echo "\$@" >> "$PIP_LOG"
if [ "\$1" = "install" ]; then
  case "\$*" in
    *headroom-ai*)
      printf '#!/bin/sh\n' > "$MOCK_BIN/headroom"
      chmod +x "$MOCK_BIN/headroom"
      ;;
  esac
fi
exit 0
EOF

  chmod +x "$MOCK_BIN"/brew "$MOCK_BIN"/curl "$MOCK_BIN"/claude "$MOCK_BIN"/pipx
}

teardown() {
  rm -rf "$TEST_HOME" "$MOCK_BIN"
}

# Declining every companion-tool prompt is the fastest path through the
# script and covers source resolution + core skills install. None of
# rtk/code-review-graph/headroom/caveman/ponytail exist on the
# trimmed PATH, so all five prompts fire and all five get declined.
# Every prompt is a numbered picker: 1 is the first option (parallel / yes),
# 2 the second (sequential / no). Order: 1 parallel-execution,
# 2 sub-agent-model, 3 background-agent, then one per companion tool starting
# with rtk at 4. run_install_no_companions_answering puts its answer on rtk.
run_install_no_companions() {
  cd "$REPO_ROOT" && printf '2\n2\n2\n2\n2\n2\n2\n2\n2\n' | bash ./install.sh
}

run_install_no_companions_answering() {
  cd "$REPO_ROOT" && printf '2\n2\n2\n2\n%s\n2\n2\n2\n2\n' "$1" | bash ./install.sh
}

@test "syntax is valid" {
  run bash -n "$REPO_ROOT/install.sh"
  [ "$status" -eq 0 ]
}

@test "installs fine when brew is missing, falling back to rtk's own installer" {
  rm -f "$MOCK_BIN/brew"
  run run_install_no_companions
  [ "$status" -eq 0 ]
}

@test "resolves RADIN_ROOT from a real checkout, no tarball download" {
  run run_install_no_companions
  [ "$status" -eq 0 ]
  [[ "$output" == *"Using radin source at $REPO_ROOT"* ]]
}

# Every entry point is a skill, so it runs in the user's own thread. The one
# agent radin ships is opt-in, and declining must not even create the dir.
@test "declining the background agent leaves ~/.claude/agents alone" {
  run_install_no_companions
  [ ! -d "$TEST_HOME/.claude/agents" ]
  grep -q '"background_agent": false' "$TEST_HOME/.claude/.radin/manifest.json"
}

@test "accepting the background agent installs just that one agent" {
  cd "$REPO_ROOT" && run bash -c "printf '2\n2\n2\n1\n2\n2\n2\n2\n2\n' | bash ./install.sh"
  [ "$status" -eq 0 ]
  [ -f "$TEST_HOME/.claude/agents/radin-execute-background.md" ]
  [ ! -e "$TEST_HOME/.claude/agents/radin-execute.md" ]
  grep -q '"background_agent": true' "$TEST_HOME/.claude/.radin/manifest.json"
}

# A surviving RADIN_MODEL_ token would reach Claude as a literal model name and
# every dispatch would fail, so no installed file may keep one.
@test "writes a model into every sub-agent role, leaving no marker behind" {
  run_install_no_companions
  ! grep -rq 'RADIN_MODEL_' "$TEST_HOME/.claude/skills" "$TEST_HOME/.claude/.radin/lib"
  grep -q 'model: "sonnet"' "$TEST_HOME/.claude/skills/radin-execute/SKILL.md"
  grep -q 'model: "haiku"' "$TEST_HOME/.claude/.radin/lib/radin-execute-prompts.md"
}

# The per-role gate at prompt 3: yes, then one pick per role (fable/opus/
# sonnet/haiku), then background-agent no, then the companion tools.
@test "per-role model picks land in the right file" {
  cd "$REPO_ROOT" && run bash -c "printf '2\n2\n1\n2\n1\n4\n3\n3\n3\n2\n2\n2\n2\n2\n2\n' | bash ./install.sh"
  [ "$status" -eq 0 ]
  ! grep -rq 'RADIN_MODEL_' "$TEST_HOME/.claude/skills" "$TEST_HOME/.claude/.radin/lib"
  grep -q 'model: "opus"' "$TEST_HOME/.claude/.radin/lib/radin-execute-prompts.md"
  grep -q 'model: "fable"' "$TEST_HOME/.claude/.radin/lib/radin-execute-prompts.md"
  grep -q 'model: "haiku"' "$TEST_HOME/.claude/skills/radin-execute/SKILL.md"
}

@test "the background agent gets its own model" {
  cd "$REPO_ROOT" && run bash -c "printf '2\n2\n1\n3\n3\n3\n3\n3\n3\n4\n1\n2\n2\n2\n2\n2\n' | bash ./install.sh"
  [ "$status" -eq 0 ]
  grep -q '^model: haiku$' "$TEST_HOME/.claude/agents/radin-execute-background.md"
}

# Declining is not a removal: install.sh never deletes a file, so it has to
# name the leftover instead of quietly leaving a shadowed copy behind.
@test "declining names a previously-installed background agent instead of removing it" {
  mkdir -p "$TEST_HOME/.claude/agents"
  : > "$TEST_HOME/.claude/agents/radin-execute-background.md"
  run run_install_no_companions
  [ "$status" -eq 0 ]
  [ -f "$TEST_HOME/.claude/agents/radin-execute-background.md" ]
  [[ "$output" == *"an earlier install left"* ]]
}

@test "installs radin's own skills, not unrelated skill dirs" {
  run_install_no_companions
  [ -d "$TEST_HOME/.claude/skills/radin-execute" ]
  [ -d "$TEST_HOME/.claude/skills/radin-review" ]
  [ -d "$TEST_HOME/.claude/skills/radin-record" ]
  [ -d "$TEST_HOME/.claude/skills/radin-setup-hooks" ]
  [ -d "$TEST_HOME/.claude/skills/radin-doctor" ]
  [ -d "$TEST_HOME/.claude/skills/radin-uninstall" ]
}

@test "installs shared namespace-resolution script into ~/.claude/.radin/lib" {
  run_install_no_companions
  [ -f "$TEST_HOME/.claude/.radin/lib/radin-namespace.sh" ]
  [ -f "$TEST_HOME/.claude/.radin/lib/radin-json.sh" ]
  [ -f "$TEST_HOME/.claude/.radin/lib/radin-uninstall.sh" ]
  [ -f "$TEST_HOME/.claude/.radin/lib/radin-execute-recovery.md" ]
  [ -f "$TEST_HOME/.claude/.radin/lib/radin-execute-reporting.md" ]
}

@test "downloads thermo-nuclear SKILL.md alongside radin's own skills" {
  run_install_no_companions
  [ -f "$TEST_HOME/.claude/skills/thermo-nuclear/SKILL.md" ]
}

# Regression test for a real bug: install_if_confirmed/install_plugin_if_confirmed
# used a bare `return` after a failed `[ ]` test, which under `set -e` propagated
# that nonzero status and killed the whole script the moment anyone declined a
# companion-tool prompt for a tool they don't already have.
@test "declining every companion prompt still runs the script to completion" {
  run run_install_no_companions
  [ "$status" -eq 0 ]
  [[ "$output" == *"radin installed."* ]]
  ! grep -q "install rtk" "$BREW_LOG"
}

@test "companion install commands only run after picking yes" {
  run run_install_no_companions_answering "1"
  [ "$status" -eq 0 ]
  [[ "$(cat "$BREW_LOG")" == *"install rtk"* ]]
}

@test "writes an install manifest listing installed files and companion tools" {
  run run_install_no_companions_answering "1"
  [ "$status" -eq 0 ]
  manifest="$TEST_HOME/.claude/.radin/manifest.json"
  [ -f "$manifest" ]
  grep -q '"version"' "$manifest"
  grep -q '"radin-execute"' "$manifest"
  grep -q '"radin-doctor"' "$manifest"
  grep -q '"radin-namespace.sh"' "$manifest"
  grep -q '"radin-json.sh"' "$manifest"
  grep -q '"rtk": true' "$manifest"
  grep -q '"code-review-graph": false' "$manifest"
  grep -q '"headroom": false' "$manifest"
}

# headroom gets install_if_confirmed's extra 4th-arg confirmation on top of
# the normal yes/no gate (Python/pip footprint) -- both prompts must be
# answered yes before the pip/pipx install command actually runs.
@test "headroom's extra pip confirmation blocks install when declined" {
  cd "$REPO_ROOT" && run bash -c "printf '2\n2\n2\n2\n2\n2\n1\n2\n2\n2\n' | bash ./install.sh"
  [ "$status" -eq 0 ]
  [ ! -f "$PIP_LOG" ] || ! grep -q "headroom-ai" "$PIP_LOG"
}

@test "headroom installs only after both confirmations pick yes" {
  cd "$REPO_ROOT" && run bash -c "printf '2\n2\n2\n2\n2\n2\n1\n1\n2\n2\n' | bash ./install.sh"
  [ "$status" -eq 0 ]
  grep -q "headroom-ai" "$PIP_LOG"
  manifest="$TEST_HOME/.claude/.radin/manifest.json"
  grep -q '"headroom": true' "$manifest"
}

@test "declining per-task verification keeps the no-refuter rule only" {
  run_install_no_companions
  agent="$TEST_HOME/.claude/skills/radin-execute/SKILL.md"
  grep -q "No refuter pass" "$agent"
  ! grep -q "Verify a .SUCCESS. before you record it" "$agent"
  ! grep -q "radin:refute" "$agent"
}

@test "accepting per-task verification keeps the refuter rule only" {
  cd "$REPO_ROOT" && run bash -c "printf '2\n1\n2\n2\n2\n2\n2\n2\n2\n' | bash ./install.sh"
  [ "$status" -eq 0 ]
  agent="$TEST_HOME/.claude/skills/radin-execute/SKILL.md"
  grep -q "Verify a .SUCCESS. before you record it" "$agent"
  ! grep -q "No refuter pass" "$agent"
  ! grep -q "radin:refute" "$agent"
}

@test "declining parallel execution keeps the sequential constraint only" {
  run_install_no_companions
  agent="$TEST_HOME/.claude/skills/radin-execute/SKILL.md"
  grep -q "One execution sub-agent at a time" "$agent"
  ! grep -q "Concurrency allowed" "$agent"
  ! grep -q "radin:concurrency" "$agent"
  grep -q '"parallel_execution": false' "$TEST_HOME/.claude/.radin/manifest.json"
}

@test "accepting parallel execution keeps the concurrency constraint only" {
  cd "$REPO_ROOT" && run bash -c "printf '1\n2\n2\n2\n2\n2\n2\n2\n2\n' | bash ./install.sh"
  [ "$status" -eq 0 ]
  agent="$TEST_HOME/.claude/skills/radin-execute/SKILL.md"
  grep -q "Concurrency allowed" "$agent"
  ! grep -q "One execution sub-agent at a time" "$agent"
  ! grep -q "radin:concurrency" "$agent"
  grep -q '"parallel_execution": true' "$TEST_HOME/.claude/.radin/manifest.json"
}

# The arrow-key picker only draws on a real terminal, so it gets driven through
# a pty helper. Extracting the functions from install.sh keeps the picker itself
# single-sourced there.
pick_with_keys() {
  command -v python3 >/dev/null 2>&1 || skip "python3 needed to allocate a pty"
  local snippet="$TEST_HOME/picker.sh" out="$TEST_HOME/picked"
  sed -n '/^_pick_nth() {/,/^prompt_yn() {/p' "$REPO_ROOT/install.sh" | sed '$d' > "$snippet"
  rm -f "$out"
  PATH="$PATH:/usr/local/bin:/opt/homebrew/bin" python3 "$REPO_ROOT/tests/helpers/pty-drive.py" \
    "$snippet" "$out" "$1" 1 alpha beta gamma >/dev/null 2>&1 && PICK_STATUS=0 || PICK_STATUS="$?"
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
  run bash -c "cd '$FAKE_ROOT' && printf '2\n2\n2\n2\n2\n' | RADIN_ROOT_OVERRIDE='$FETCH_DIR' bash ./install.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"wasn't created by this installer"* ]]
}

# --force on an already-installed plugin must reach `claude plugin update`,
# not the install path -- a plain re-install is a no-op and leaves it stale.
@test "--force updates an already-installed plugin" {
  CLAUDE_LOG="$TEST_HOME/claude.log"
  cat > "$MOCK_BIN/claude" <<EOF
#!/bin/sh
echo "\$@" >> "$CLAUDE_LOG"
if [ "\$1" = "plugin" ] && [ "\$2" = "list" ]; then echo "caveman@caveman"; fi
exit 0
EOF
  chmod +x "$MOCK_BIN/claude"
  cd "$REPO_ROOT" && run bash ./install.sh --force --yes
  [ "$status" -eq 0 ]
  grep -q "plugin update caveman@caveman" "$CLAUDE_LOG"
  ! grep -q "plugin install caveman@caveman" "$CLAUDE_LOG"
}

# A companion tool that fails to install must not abort radin's own install --
# set -e used to kill the script the moment a pip/pipx preflight failed.
@test "a failing companion install warns but completes" {
  cat > "$MOCK_BIN/brew" <<'EOF'
#!/bin/sh
exit 1
EOF
  chmod +x "$MOCK_BIN/brew"
  run run_install_no_companions_answering "1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"rtk install failed"* ]]
  [[ "$output" == *"radin installed."* ]]
}

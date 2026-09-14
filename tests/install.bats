#!/usr/bin/env bats
# Exercises install.sh against an isolated $HOME with stubbed brew/curl/claude
# so the suite runs offline and never touches the real ~/.claude. PATH is
# reduced to MOCK_BIN + core system dirs so real rtk/codebase-memory-mcp/brew
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

# Only execution behaviour is asked about, in this order: 1 concurrency,
# 2 refuter pass, 3 sub-agent models. Each is a numbered picker where 1 is the
# first option (parallel / yes) and 2 the second (sequential / no), so three
# 2s takes every documented default. Every companion tool installs with no
# prompt at all -- the stubs on MOCK_BIN absorb those calls.
run_install_defaults() {
  cd "$REPO_ROOT" && printf '2\n2\n2\n' | bash ./install.sh
}

@test "syntax is valid" {
  run bash -n "$REPO_ROOT/install.sh"
  [ "$status" -eq 0 ]
}

@test "installs fine when brew is missing, falling back to rtk's own installer" {
  rm -f "$MOCK_BIN/brew"
  run run_install_defaults
  [ "$status" -eq 0 ]
}

# A child that inherits fd0 reads the rest of the piped script or the piped
# answers, and the install then stops before the questions.
@test "a companion install that reads stdin can't eat the piped answers" {
  cat > "$MOCK_BIN/npx" <<'EOF'
#!/bin/sh
cat > /dev/null
exit 0
EOF
  chmod +x "$MOCK_BIN/npx"
  cd "$REPO_ROOT" && run bash -c "printf '1\n2\n2\n' | bash ./install.sh"
  [ "$status" -eq 0 ]
  grep -q 'Concurrency allowed' "$TEST_HOME/.claude/skills/radin-execute/SKILL.md"
}

@test "resolves RADIN_ROOT from a real checkout, no tarball download" {
  run run_install_defaults
  [ "$status" -eq 0 ]
  [[ "$output" == *"Using radin source at $REPO_ROOT"* ]]
}

# Every entry point is a skill, so it runs in the user's own thread. radin
# ships no agent: an install must never create ~/.claude/agents.
@test "install creates no ~/.claude/agents" {
  run_install_defaults
  [ ! -d "$TEST_HOME/.claude/agents" ]
  ! grep -q 'background_agent' "$TEST_HOME/.claude/.radin/manifest.json"
}

# A surviving RADIN_MODEL_ token would reach Claude as a literal model name and
# every dispatch would fail, so no installed file may keep one.
@test "writes a model into every sub-agent role, leaving no marker behind" {
  run_install_defaults
  ! grep -rq 'RADIN_MODEL_' "$TEST_HOME/.claude/skills" "$TEST_HOME/.claude/.radin/lib"
  grep -q 'model: "sonnet"' "$TEST_HOME/.claude/skills/radin-execute/SKILL.md"
  grep -q 'model: "haiku"' "$TEST_HOME/.claude/.radin/lib/radin-execute-prompts.md"
}

# The model gate at prompt 3: yes, then "same model for every role?" no, then
# one pick per role (fable/opus/sonnet/haiku) -- no refuter pick, since the
# refuter pass was declined.
@test "per-role model picks land in the right file" {
  cd "$REPO_ROOT" && run bash -c "printf '2\n2\n1\n2\n2\n1\n4\n3\n3\n' | bash ./install.sh"
  [ "$status" -eq 0 ]
  ! grep -rq 'RADIN_MODEL_' "$TEST_HOME/.claude/skills" "$TEST_HOME/.claude/.radin/lib"
  grep -q 'model: "opus"' "$TEST_HOME/.claude/.radin/lib/radin-execute-prompts.md"
  grep -q 'model: "fable"' "$TEST_HOME/.claude/.radin/lib/radin-execute-prompts.md"
  grep -q 'model: "haiku"' "$TEST_HOME/.claude/skills/radin-execute/SKILL.md"
}

# The refuter role only gets a model question when the refuter pass is on.
# "Same model for every role?" defaults to yes: one pick sets all six tokens,
# fact-finding's haiku default included.
@test "one same-model pick covers every role" {
  cd "$REPO_ROOT" && run bash -c "printf '2\n2\n1\n1\n2\n' | bash ./install.sh"
  [ "$status" -eq 0 ]
  ! grep -rq 'RADIN_MODEL_' "$TEST_HOME/.claude/skills" "$TEST_HOME/.claude/.radin/lib"
  grep -q 'model: "opus"' "$TEST_HOME/.claude/skills/radin-execute/SKILL.md"
  grep -q 'model: "opus"' "$TEST_HOME/.claude/.radin/lib/radin-execute-prompts.md"
  ! grep -q 'model: "haiku"' "$TEST_HOME/.claude/.radin/lib/radin-execute-prompts.md"
}

@test "refuter model pick is asked when the refuter pass is enabled" {
  cd "$REPO_ROOT" && run bash -c "printf '2\n1\n1\n2\n3\n3\n3\n1\n3\n3\n' | bash ./install.sh"
  [ "$status" -eq 0 ]
  grep -q 'model: "fable"' "$TEST_HOME/.claude/.radin/lib/radin-execute-prompts.md"
}

@test "installs radin's own skills, not unrelated skill dirs" {
  run_install_defaults
  [ -d "$TEST_HOME/.claude/skills/radin-execute" ]
  [ -d "$TEST_HOME/.claude/skills/radin-review" ]
  [ -d "$TEST_HOME/.claude/skills/radin-record" ]
  [ -d "$TEST_HOME/.claude/skills/radin-setup-hooks" ]
  [ -d "$TEST_HOME/.claude/skills/radin-doctor" ]
  [ -d "$TEST_HOME/.claude/skills/radin-uninstall" ]
}

@test "installs shared namespace-resolution script into ~/.claude/.radin/lib" {
  run_install_defaults
  [ -f "$TEST_HOME/.claude/.radin/lib/radin-namespace.sh" ]
  [ -f "$TEST_HOME/.claude/.radin/lib/radin-json.sh" ]
  [ -f "$TEST_HOME/.claude/.radin/lib/radin-uninstall.sh" ]
  [ -f "$TEST_HOME/.claude/.radin/lib/radin-execute-recovery.md" ]
  [ -f "$TEST_HOME/.claude/.radin/lib/radin-execute-reporting.md" ]
}

@test "downloads thermo-nuclear SKILL.md alongside radin's own skills" {
  run_install_defaults
  [ -f "$TEST_HOME/.claude/skills/thermo-nuclear/SKILL.md" ]
}

# The stack is opinionated: no tool has a prompt, so a run that answers only
# the three behaviour questions must still install every companion tool.
@test "every companion tool installs without a prompt" {
  run run_install_defaults
  [ "$status" -eq 0 ]
  [[ "$output" == *"radin installed."* ]]
  grep -q "install rtk" "$BREW_LOG"
  grep -q "headroom-ai" "$PIP_LOG"
  [[ "$output" != *"Install rtk?"* ]]
}

@test "writes an install manifest listing installed files and companion tools" {
  run run_install_defaults
  [ "$status" -eq 0 ]
  manifest="$TEST_HOME/.claude/.radin/manifest.json"
  [ -f "$manifest" ]
  grep -q '"version"' "$manifest"
  grep -q '"radin-execute"' "$manifest"
  grep -q '"radin-doctor"' "$manifest"
  grep -q '"radin-namespace.sh"' "$manifest"
  grep -q '"radin-json.sh"' "$manifest"
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
  run run_install_defaults
  [ "$status" -eq 0 ]
  run run_install_defaults
  [ "$status" -eq 0 ]
  claude_md="$TEST_HOME/.claude/CLAUDE.md"
  grep -q "user content stays" "$claude_md"
  [ "$(grep -c '<!-- radin:begin -->' "$claude_md")" -eq 1 ]
  [ "$(grep -c '<!-- radin:end -->' "$claude_md")" -eq 1 ]
  grep -q '/radin-record' "$claude_md"
  grep -q '"claude_md_guidance": true' "$TEST_HOME/.claude/.radin/manifest.json"
  # A re-run must not grow the file by one blank line each time.
  before="$(wc -l < "$claude_md")"
  run run_install_defaults
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$claude_md")" -eq "$before" ]
}

@test "installs the radin CLI dispatcher and the ~/.local/bin symlink" {
  run_install_defaults
  [ -x "$TEST_HOME/.claude/.radin/bin/radin" ]
  [ -L "$TEST_HOME/.local/bin/radin" ]
  [ "$(readlink "$TEST_HOME/.local/bin/radin")" = "$TEST_HOME/.claude/.radin/bin/radin" ]
  grep -q '"cli_on_path": true' "$TEST_HOME/.claude/.radin/manifest.json"
}

# Skills carry a RADIN_CLI token; set_cli resolves it to whichever invocation
# works. The test PATH lacks ~/.local/bin, so even with the symlink the full
# dispatcher path is written -- bare `radin` would break every skill here.
@test "RADIN_CLI resolves to the full path when ~/.local/bin is off PATH" {
  run_install_defaults
  ! grep -rq 'RADIN_CLI' "$TEST_HOME/.claude/skills" "$TEST_HOME/.claude/.radin/lib"
  grep -q '"$HOME/.claude/.radin/bin/radin" backlog' "$TEST_HOME/.claude/skills/radin-execute/SKILL.md"
}

@test "RADIN_CLI resolves to bare radin when ~/.local/bin is on PATH" {
  cd "$REPO_ROOT" && printf '2\n2\n2\n' | PATH="$TEST_HOME/.local/bin:$PATH" bash ./install.sh
  ! grep -rq 'RADIN_CLI' "$TEST_HOME/.claude/skills" "$TEST_HOME/.claude/.radin/lib"
  grep -q 'radin backlog count' "$TEST_HOME/.claude/skills/radin-execute/SKILL.md"
  ! grep -q '.radin/bin/radin" backlog' "$TEST_HOME/.claude/skills/radin-execute/SKILL.md"
}

@test "the dispatcher routes subcommands to the installed lib scripts" {
  run_install_defaults
  run env HOME="$TEST_HOME" bash "$TEST_HOME/.claude/.radin/bin/radin" backlog count
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
  run env HOME="$TEST_HOME" bash "$TEST_HOME/.claude/.radin/bin/radin" nope
  [ "$status" -ne 0 ]
}

@test "an existing non-radin ~/.local/bin/radin is named, never replaced" {
  mkdir -p "$TEST_HOME/.local/bin"
  echo "someone else's" > "$TEST_HOME/.local/bin/radin"
  run run_install_defaults
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_HOME/.local/bin/radin")" = "someone else's" ]
  [[ "$output" == *"isn't radin's"* ]]
}

@test "the default keeps the no-refuter rule only" {
  run_install_defaults
  agent="$TEST_HOME/.claude/skills/radin-execute/SKILL.md"
  grep -q "No refuter pass" "$agent"
  ! grep -q "Verify a .SUCCESS. before you record it" "$agent"
  ! grep -q "radin:refute" "$agent"
}

@test "accepting per-task verification keeps the refuter rule only" {
  cd "$REPO_ROOT" && run bash -c "printf '2\n1\n2\n' | bash ./install.sh"
  [ "$status" -eq 0 ]
  agent="$TEST_HOME/.claude/skills/radin-execute/SKILL.md"
  grep -q "Verify a .SUCCESS. before you record it" "$agent"
  ! grep -q "No refuter pass" "$agent"
  ! grep -q "radin:refute" "$agent"
}

@test "the default keeps the sequential constraint only" {
  run_install_defaults
  agent="$TEST_HOME/.claude/skills/radin-execute/SKILL.md"
  grep -q "One execution sub-agent at a time" "$agent"
  ! grep -q "Concurrency allowed" "$agent"
  ! grep -q "radin:concurrency" "$agent"
  grep -q '"parallel_execution": false' "$TEST_HOME/.claude/.radin/manifest.json"
}

@test "accepting parallel execution keeps the concurrency constraint only" {
  cd "$REPO_ROOT" && run bash -c "printf '1\n2\n2\n' | bash ./install.sh"
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
  run bash -c "cd '$FAKE_ROOT' && printf '2\n2\n2\n' | RADIN_ROOT_OVERRIDE='$FETCH_DIR' bash ./install.sh"
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

# Plugins install through the `claude` CLI and nothing else: without it, say so
# once per plugin rather than failing three times.
@test "plugins are skipped with one line when the claude CLI is absent" {
  rm -f "$MOCK_BIN/claude"
  cd "$REPO_ROOT" && run bash ./install.sh --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"caveman skipped: the 'claude' CLI is not on PATH"* ]]
  [[ "$output" != *"caveman install failed"* ]]
}

# A companion tool that fails to install must not abort radin's own install --
# set -e used to kill the script the moment a pip/pipx preflight failed.
@test "a failing companion install warns but completes" {
  cat > "$MOCK_BIN/brew" <<'EOF'
#!/bin/sh
exit 1
EOF
  chmod +x "$MOCK_BIN/brew"
  run run_install_defaults
  [ "$status" -eq 0 ]
  [[ "$output" == *"rtk install failed"* ]]
  [[ "$output" == *"radin installed."* ]]
}

# `radin update` runs install.sh --update: no question is asked again, and the
# answers come from the manifest the previous install wrote.
@test "--update reuses the recorded behaviour answers instead of asking" {
  cd "$REPO_ROOT" && printf '1\n1\n1\n1\n1\n' | bash ./install.sh
  manifest="$TEST_HOME/.claude/.radin/manifest.json"
  grep -q '"parallel_execution": true' "$manifest"
  grep -q '"refuter_pass": true' "$manifest"
  grep -q '"model_planning": "fable"' "$manifest"

  run bash ./install.sh --update
  [ "$status" -eq 0 ]
  [[ "$output" == *"keeping the recorded answer: parallel"* ]]
  [[ "$output" == *"keeping the recorded answer: refuter pass yes"* ]]
  [[ "$output" == *"keeping recorded sub-agent models: plan fable"* ]]
  grep -q '"parallel_execution": true' "$manifest"
  grep -q '"refuter_pass": true' "$manifest"
  grep -q '"model_planning": "fable"' "$manifest"
  grep -q 'fable' "$TEST_HOME/.claude/.radin/lib/radin-execute-prompts.md"
  [[ "$output" == *"radin updated"* ]]
}

@test "the install records its source root for radin update" {
  run run_install_defaults
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_HOME/.claude/.radin/install_root")" = "$REPO_ROOT" ]
}

# --update is non-interactive by design, so with no manifest to read it takes
# the documented defaults rather than blocking on a question.
@test "--update with no manifest takes the defaults, never a prompt" {
  cd "$REPO_ROOT" && run bash ./install.sh --update
  [ "$status" -eq 0 ]
  [[ "$output" != *"keeping the recorded answer"* ]]
  grep -q '"parallel_execution": false' "$TEST_HOME/.claude/.radin/manifest.json"
  grep -q '"refuter_pass": false' "$TEST_HOME/.claude/.radin/manifest.json"
}

@test "ships the update script and routes radin update to it" {
  run run_install_defaults
  [ "$status" -eq 0 ]
  [ -f "$TEST_HOME/.claude/.radin/lib/radin-update.sh" ]
  grep -q '"radin-update.sh"' "$TEST_HOME/.claude/.radin/manifest.json"
  run env HOME="$TEST_HOME" bash "$TEST_HOME/.claude/.radin/bin/radin"
  [[ "$output" == *"update"* ]]
}

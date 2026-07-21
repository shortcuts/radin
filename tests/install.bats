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
  cat > "$MOCK_BIN/brew" <<EOF
#!/bin/sh
echo "\$@" >> "$BREW_LOG"
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

  chmod +x "$MOCK_BIN"/brew "$MOCK_BIN"/curl "$MOCK_BIN"/claude
}

teardown() {
  rm -rf "$TEST_HOME" "$MOCK_BIN"
}

# Declining every companion-tool prompt is the fastest path through the
# script and covers source resolution + core agents/skills install. None of
# rtk/code-review-graph/caveman/i-have-adhd/ponytail exist on the trimmed
# PATH, so all five prompts fire and all five get declined.
run_install_no_companions() {
  cd "$REPO_ROOT" && printf 'n\nn\nn\nn\nn\n' | bash ./install.sh
}

run_install_no_companions_answering() {
  cd "$REPO_ROOT" && printf '%s\nn\nn\nn\nn\n' "$1" | bash ./install.sh
}

@test "syntax is valid" {
  run bash -n "$REPO_ROOT/install.sh"
  [ "$status" -eq 0 ]
}

@test "fails with a clear message when brew is missing" {
  rm -f "$MOCK_BIN/brew"
  run bash "$REPO_ROOT/install.sh" <<< $'n\nn\nn\nn\n'
  [ "$status" -ne 0 ]
  [[ "$output" == *"Homebrew not found"* ]]
}

@test "resolves RADIN_ROOT from a real checkout, no tarball download" {
  run run_install_no_companions
  [ "$status" -eq 0 ]
  [[ "$output" == *"Using radin source at $REPO_ROOT"* ]]
}

@test "installs all shipped agents into ~/.claude/agents" {
  run_install_no_companions
  for f in "$REPO_ROOT"/agents/*.md; do
    name="$(basename "$f")"
    [ -f "$TEST_HOME/.claude/agents/$name" ]
  done
}

@test "installs radin's own skills, not unrelated skill dirs" {
  run_install_no_companions
  [ -d "$TEST_HOME/.claude/skills/radin-review" ]
  [ -d "$TEST_HOME/.claude/skills/radin-record" ]
  [ -d "$TEST_HOME/.claude/skills/radin-setup-hooks" ]
  [ -d "$TEST_HOME/.claude/skills/radin-update" ]
}

@test "installs shared namespace-resolution script into ~/.claude/radin-lib" {
  run_install_no_companions
  [ -f "$TEST_HOME/.claude/radin-lib/radin-namespace.sh" ]
}

@test "downloads thermo-nuclear SKILL.md alongside radin's own skills" {
  run_install_no_companions
  [ -f "$TEST_HOME/.claude/skills/thermo-nuclear/SKILL.md" ]
}

@test "creates the .radin namespace with an empty registry" {
  run_install_no_companions
  [ -d "$TEST_HOME/.claude/.radin/projects" ]
  [ -f "$TEST_HOME/.claude/.radin/registry.json" ]
  [ "$(cat "$TEST_HOME/.claude/.radin/registry.json")" = "{}" ]
}

@test "does not clobber an existing registry.json on reinstall" {
  run_install_no_companions
  echo '{"seeded":true}' > "$TEST_HOME/.claude/.radin/registry.json"
  run_install_no_companions
  [ "$(cat "$TEST_HOME/.claude/.radin/registry.json")" = '{"seeded":true}' ]
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

@test "companion install commands only run after an explicit y" {
  run run_install_no_companions_answering "y"
  [ "$status" -eq 0 ]
  [[ "$(cat "$BREW_LOG")" == *"install rtk"* ]]
}

@test "refuses to reuse a fetch dir it didn't create" {
  FAKE_ROOT="$TEST_HOME/fake-checkout"
  mkdir -p "$FAKE_ROOT"
  cp "$REPO_ROOT/install.sh" "$FAKE_ROOT/install.sh"
  # No sibling agents/skills dirs -> forces the download branch.
  FETCH_DIR="$TEST_HOME/preexisting"
  mkdir -p "$FETCH_DIR"
  echo "not ours" > "$FETCH_DIR/some_other_file"
  run bash -c "cd '$FAKE_ROOT' && printf 'n\nn\nn\nn\n' | RADIN_ROOT_OVERRIDE='$FETCH_DIR' bash ./install.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"wasn't created by this installer"* ]]
}

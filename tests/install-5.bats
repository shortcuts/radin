#!/usr/bin/env bats
# Exercises install.sh against an isolated $HOME with stubbed commands (see helpers/install.bash).
# One of eight shards so the files run side by side.

bats_require_minimum_version 1.5.0
load helpers/install

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

@test "migration moves ~/.claude/.radin to ~/.radin and drops the old Read rules" {
  use_real_cc
  seed_old_layout
  run real_install
  [ "$status" -eq 0 ]
  [[ "$output" == *"moved ~/.claude/.radin to ~/.radin"* ]]
  [[ "$output" == *"restart open Claude sessions: they hold the old path"* ]]
  assert_migrated
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

@test "Backspace returns to the previous step" {
  wizard_run '\r|\177|\r|\r|\r|\r'
  [ "$WIZ_STATUS" -eq 0 ]
  [ "$(wizard_count 'Step 1/3')" -ge 2 ]
  [[ "$WIZ_SCREEN" == *"hosts: claude"* ]]
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

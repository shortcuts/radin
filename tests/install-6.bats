#!/usr/bin/env bats
# Exercises install.sh against an isolated $HOME with stubbed commands (see helpers/install.bash).
# One of eight shards so the files run side by side.

bats_require_minimum_version 1.5.0
load helpers/install

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

@test "manifest lists the rendered libs under hostlib" {
  grep -q '"hostlib": \[.*"radin-run.md"' "$TEMPLATE/home/.radin/manifest.json"
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

@test "uninstall removes what a three-host install wrote and nothing else" {
  mock_cli codex
  mock_cli opencode
  agents_root
  install_from "$AROOT" --yes --only claude,codex,opencode >/dev/null
  grep -q 'radin:begin' "$TEST_HOME/.codex/AGENTS.md"
  run bash "$TEST_HOME/.radin/lib/radin-uninstall.sh"
  [ "$status" -eq 0 ]
  [ -z "$(ls "$TEST_HOME/.claude/skills" "$TEST_HOME/.agents/skills" | grep '^radin-')" ]
  run grep -rl 'radin:begin' "$TEST_HOME/.claude" "$TEST_HOME/.codex" "$TEST_HOME/.config/opencode"
  [ "$status" -eq 1 ]
  [ -z "$(ls "$TEST_HOME"/.config/opencode/agents 2>/dev/null | grep '^radin-')" ]
  run grep -s '\.radin/\*\*' "$TEST_HOME/.config/opencode/opencode.json"
  [ "$status" -ne 0 ]
  [ ! -e "$TEST_HOME/.radin/manifest.json" ]
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

@test "a sibling download failure installs none of that skill's files" {
  mock_cli codex
  agents_root
  export MOCK_CURL_FAIL=DEEPENING.md
  run install_from "$AROOT" --yes --only codex
  [ "$status" -eq 0 ]
  [[ "$output" == *"codebase-design download failed"* ]]
  [ ! -e "$TEST_HOME/.agents/skills/codebase-design" ]
}

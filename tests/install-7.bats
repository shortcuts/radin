#!/usr/bin/env bats
# Exercises install.sh against an isolated $HOME with stubbed commands (see helpers/install.bash).
# One of eight shards so the files run side by side.

bats_require_minimum_version 1.5.0
load helpers/install

@test "golden render check fails when an installed skill changes" {
  replay_install >/dev/null
  echo "one more word" >>"$TEST_HOME/.claude/skills/radin-do/SKILL.md"
  "$REPO_ROOT/scripts/golden-render.sh" "$TEST_HOME" >"$BATS_TEST_TMPDIR/golden-now"
  run diff -u "$REPO_ROOT/tests/golden-claude-render.sha256" "$BATS_TEST_TMPDIR/golden-now"
  [ "$status" -eq 1 ]
  [[ "$output" == *"skills/radin-do/SKILL.md"* ]]
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

@test "installs the radin CLI dispatcher and the ~/.local/bin symlink" {
  # Asserted on the recorded tree: the symlink names its own $TEMPLATE home, so
  # a replay into another $HOME could not be checked.
  [ -x "$TEMPLATE/home/.radin/bin/radin" ]
  [ -L "$TEMPLATE/home/.local/bin/radin" ]
  [ "$(readlink "$TEMPLATE/home/.local/bin/radin")" = "$TEMPLATE/home/.radin/bin/radin" ]
  grep -q '"cli_on_path": true' "$TEMPLATE/home/.radin/manifest.json"
}

@test "arrow keys move the selection, enter confirms it" {
  pick_with_keys '\r'
  [ "$PICKED" = "alpha" ]
  pick_with_keys '\033[B\r'
  [ "$PICKED" = "beta" ]
  pick_with_keys '\033[B\033[B\r'
  [ "$PICKED" = "gamma" ]
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
  [[ "$output" == *"radin installed in "* ]]
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

@test "Left returns to the previous step and keeps its answer" {
  wizard_run '\r|\033[D|j| |\r|\r|\r'
  [ "$WIZ_STATUS" -eq 0 ]
  [ "$(wizard_count 'Step 1/3')" -ge 2 ]
  [[ "$WIZ_SCREEN" == *"hosts: claude codex"* ]]
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

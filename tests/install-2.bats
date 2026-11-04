#!/usr/bin/env bats
# Exercises install.sh against an isolated $HOME with stubbed commands (see helpers/install.bash).
# One of eight shards so the files run side by side.

bats_require_minimum_version 1.5.0
load helpers/install

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
  [ ! -e "$TEST_HOME/.radin/manifest.json" ]
  [ ! -e "$TEST_HOME/.radin/install_root" ]
  [ ! -e "$TEST_HOME/.radin/lib" ]
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

# Skills carry a RADIN_CLI token; set_cli resolves it to whichever invocation
# works. The test PATH lacks ~/.local/bin, so even with the symlink the full
# dispatcher path is written -- bare `radin` would break every skill here.
@test "RADIN_CLI resolves to the full path when ~/.local/bin is off PATH" {
  run_install_defaults
  run ! grep -rq --exclude=radin-doctor.sh 'RADIN_CLI' "$TEST_HOME/.claude/skills" "$TEST_HOME/.radin/lib"
  grep -q '"$HOME/.radin/bin/radin" backlog' "$TEST_HOME/.radin/hosts/claude/lib/radin-run.md"
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

# --refresh is the path that upgrades companions: a tool already on PATH still
# takes its install/upgrade command instead of being skipped.
# Three install-time setups that do not interact, sharing one live run.
@test "real install: foreign ~/.local/bin/radin kept, installed rtk reinstalled, partial cbm config warned" {
  mkdir -p "$TEST_HOME/.local/bin"
  echo "someone else's" > "$TEST_HOME/.local/bin/radin"
  ln "$MOCK_BIN/mock" "$MOCK_BIN/rtk" 2>/dev/null || ln -s "$MOCK_BIN/mock" "$MOCK_BIN/rtk"
  ln "$MOCK_BIN/mock" "$MOCK_BIN/codebase-memory-mcp" 2>/dev/null ||
    ln -s "$MOCK_BIN/mock" "$MOCK_BIN/codebase-memory-mcp"
  export MOCK_CBM=fail-install
  run real_install --refresh
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

@test "every selected host installs its files when no host CLI exists" {
  agents_root
  rm -f "$MOCK_BIN/claude"
  run install_from "$AROOT" --yes --only claude,codex,opencode
  [ "$status" -eq 0 ]
  [[ "$output" == *"codex CLI not found"* ]]
  [[ "$output" == *"opencode CLI not found"* ]]
  [ "$(manifest_array hosts)" = '"claude", "codex", "opencode"' ]
  [ -f "$TEST_HOME/.claude/skills/radin-batch/SKILL.md" ]
  [ -f "$TEST_HOME/.agents/skills/radin-batch/SKILL.md" ]
  [ -f "$TEST_HOME/.config/opencode/agents/radin-review.md" ]
}

@test "step progress totals match the step calls" {
  [ "$(grep -c '^step "' "$REPO_ROOT/install.sh")" = "$(sed -n 's/^STEP_TOTAL=//p' "$REPO_ROOT/install.sh")" ]
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

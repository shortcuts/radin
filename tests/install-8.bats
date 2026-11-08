#!/usr/bin/env bats
# Exercises install.sh against an isolated $HOME with stubbed commands (see helpers/install.bash).
# One of eight shards so the files run side by side.

bats_require_minimum_version 1.5.0
load helpers/install

@test "a real install.sh run succeeds end to end" {
  [ "$(cat "$TEMPLATE/status")" -eq 0 ]
  grep -q 'radin installed in ' "$TEMPLATE/output"
  [ -f "$TEMPLATE/home/.claude/skills/radin-batch/SKILL.md" ]
  [ -f "$TEMPLATE/home/.radin/lib/radin-backlog.sh" ]
  [ -f "$TEMPLATE/home/.radin/manifest.json" ]
  [ -x "$TEMPLATE/home/.radin/bin/radin-tui" ]
  [ -x "$TEMPLATE/home/.radin/bin/radin-cbm-json" ]
  # Agents read the backlog through the CLI.
  grep -q 'what is pending: run `.* backlog show`' "$TEMPLATE/home/.claude/CLAUDE.md"
  ! grep -q '/radin-show' "$TEMPLATE/home/.claude/CLAUDE.md"
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

@test "layout: .md only under hosts/claude/lib, neutral files only under lib, no ~/.claude/.radin" {
  run_install_defaults >/dev/null
  [ -z "$(find "$TEST_HOME/.radin/lib" -name '*.md')" ]
  [ -z "$(find "$TEST_HOME/.radin/hosts/claude/lib" -type f ! -name '*.md')" ]
  [ -f "$TEST_HOME/.radin/hosts/claude/lib/radin-run.md" ]
  [ ! -e "$TEST_HOME/.claude/.radin" ]
  grep -q '"hostlib": \[.*"radin-run.md"' "$TEST_HOME/.radin/manifest.json"
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

# --yes is how one command reproduces this machine on the next one: the three
# behaviour questions take their defaults instead of blocking on a terminal.
@test "--yes asks nothing and still installs everything" {
  cd "$REPO_ROOT" && run bash ./install.sh --yes
  [ "$status" -eq 0 ]
  grep -q "install rtk" "$BREW_LOG"
  [[ "$output" != *"Pick 1-"* ]]
  [[ "$output" != *"Step 1/"* ]]
  [[ "$output" == *"┌─ Review "* ]]
  manifest="$TEST_HOME/.radin/manifest.json"
  grep -q '"rtk": true' "$manifest"
  # The guidance block is part of "same stack on the next machine".
  grep -q '"claude_md_guidance": true' "$manifest"
  grep -q '<!-- radin:begin -->' "$TEST_HOME/.claude/CLAUDE.md"
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
  [ "$(wc -l <"$TEST_HOME/cc.log" | tr -d ' ')" = 2 ]
}

@test "--update --dry-run lists writes and changes no byte" {
  mock_cli codex
  agents_root
  install_from "$AROOT" --yes --only claude,codex >/dev/null
  update_marker
  local before
  before="$(home_sum)"
  run install_from "$AROOT" --update --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"write "* ]]
  [ "$before" = "$(home_sum)" ]
  run grep -c UPDATE-MARKER "$TEST_HOME/.radin/hosts/agents/lib/radin-run.md" "$TEST_HOME/.radin/hosts/claude/lib/radin-run.md"
  [ "$status" -eq 1 ]
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

@test "space ticks a host in the checkbox list" {
  wizard_run 'j| |\r|\r|\r'
  [ "$WIZ_STATUS" -eq 0 ]
  [[ "$WIZ_SCREEN" == *"Hosts            Claude Code, Codex CLI"* ]]
  [[ "$WIZ_SCREEN" == *"hosts: claude codex"* ]]
}

# Companion skills on the agents host: lib/companion-skills.txt, fetched by install.sh.


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

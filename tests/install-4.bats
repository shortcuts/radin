#!/usr/bin/env bats
# Exercises install.sh against an isolated $HOME with stubbed commands (see helpers/install.bash).
# One of eight shards so the files run side by side.

bats_require_minimum_version 1.5.0
load helpers/install

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

@test "installs unslop and technical-writing from upstream, minus the invocation block" {
  run_install_defaults >/dev/null
  for s in unslop technical-writing; do
    f="$TEST_HOME/.claude/skills/$s/SKILL.md"
    [ "$(head -c 3 "$f")" = "---" ]
    run ! grep -q 'disable-model-invocation' "$f"
    grep -q "\"$s\": true" "$TEST_HOME/.radin/manifest.json"
  done
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

@test "the wizard walks Hosts, Models and Package manager, prints the Review box and installs" {
  wizard_run '\r|\r|\r'
  [ "$WIZ_STATUS" -eq 0 ]
  [[ "$WIZ_SCREEN" == *"Step 1/3  Hosts > Models > Package manager"* ]]
  [[ "$WIZ_SCREEN" == *"> [x] Claude Code"* ]]
  [[ "$WIZ_SCREEN" == *"[ ] Codex CLI"* ]]
  [[ "$WIZ_SCREEN" == *"┌─ Review "* ]]
  [[ "$WIZ_SCREEN" == *"Hosts            Claude Code "* ]]
  [[ "$WIZ_SCREEN" == *"hosts: claude"* ]]
  [[ "$WIZ_SCREEN" == *"[1/7] Resolving radin source"* ]]
}

@test "--update asks nothing and prints the Recap with the kept answers" {
  replay_install >/dev/null
  cd "$REPO_ROOT" && run bash ./install.sh --update </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"┌─ Recap "* ]]
  [[ "$output" == *"Models           sonnet: planning, execution, review, debug"* ]]
  [[ "$output" == *"Package manager  "* ]]
  [[ "$output" != *"Pick 1-"* ]]
  [[ "$output" != *"Step 1/"* ]]
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

@test "a claude-only install fetches no agents companion skill" {
  run_install_defaults >/dev/null
  [ ! -e "$TEST_HOME/.agents" ]
  [ -z "$(manifest_array agents_skills)" ]
  run ! grep -v 'pstack/skills/' "$TEST_HOME/curl.log"
}

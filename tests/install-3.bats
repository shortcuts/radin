#!/usr/bin/env bats
# Exercises install.sh against an isolated $HOME with stubbed commands (see helpers/install.bash).
# One of eight shards so the files run side by side.

bats_require_minimum_version 1.5.0
load helpers/install

@test "a ~/.local/bin/radin link to the legacy dispatcher is relinked" {
  mkdir -p "$TEST_HOME/.local/bin"
  ln -s "$TEST_HOME/.claude/.radin/bin/radin" "$TEST_HOME/.local/bin/radin"
  run real_install
  [ "$status" -eq 0 ]
  [ "$(readlink "$TEST_HOME/.local/bin/radin")" = "$TEST_HOME/.radin/bin/radin" ]
  grep -q '"cli_on_path": true' "$TEST_HOME/.radin/manifest.json"
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

@test "a three-host lifecycle keeps foreign content and leaves no radin file" {
  mock_cli codex
  mock_cli opencode
  agents_root
  rm -f "$MOCK_BIN/cc" "$MOCK_BIN/gcc" "$MOCK_BIN/clang"
  mkdir -p "$TEST_HOME/.claude" "$TEST_HOME/.codex" "$TEST_HOME/.config/opencode"
  printf 'mine\n' >"$TEST_HOME/.claude/CLAUDE.md"
  printf 'mine\n' >"$TEST_HOME/.codex/AGENTS.md"
  printf 'mine\n' >"$TEST_HOME/.config/opencode/AGENTS.md"
  printf '{"permission":{"external_directory":{"/keep/**":"allow"}}}\n' >"$TEST_HOME/.config/opencode/opencode.json"
  foreign_skill .claude/skills/foreign
  foreign_skill .agents/skills/foreign
  (cd "$TEST_HOME" && find . -type f | sort) >"$BATS_TEST_TMPDIR/seeded"
  run install_from "$AROOT" --yes --only claude,codex,opencode
  [ "$status" -eq 0 ]
  assert_no_agents_marker
  run bash "$TEST_HOME/.radin/lib/radin-doctor.sh"
  [ "$status" -eq 0 ]
  local before after
  before="$(home_sum | grep -v -e '^\./\.radin/manifest\.json ' -e '\.log ' -e '^\./\.radin/backups/')"
  run install_from "$AROOT" --yes --only claude,codex,opencode
  [ "$status" -eq 0 ]
  after="$(home_sum | grep -v -e '^\./\.radin/manifest\.json ' -e '\.log ' -e '^\./\.radin/backups/')"
  [ "$before" = "$after" ]
  run bash "$TEST_HOME/.radin/lib/radin-uninstall.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_HOME/.claude/CLAUDE.md")" = mine ]
  [ "$(cat "$TEST_HOME/.codex/AGENTS.md")" = mine ]
  [ "$(cat "$TEST_HOME/.config/opencode/AGENTS.md")" = mine ]
  grep -q '/keep/\*\*' "$TEST_HOME/.config/opencode/opencode.json"
  run grep -s '\.radin/\*\*' "$TEST_HOME/.config/opencode/opencode.json"
  [ "$status" -ne 0 ]
  [ -f "$TEST_HOME/.claude/skills/foreign/SKILL.md" ]
  [ -f "$TEST_HOME/.agents/skills/foreign/SKILL.md" ]
  local left
  left="$(cd "$TEST_HOME" && find . -type f | sort | comm -23 - "$BATS_TEST_TMPDIR/seeded" |
    grep -v -e '\.log$' -e '^\./\.claude/\.ponytail-band$' -e '^\./\.claude/settings\.json$' -e '^\./\.radin/backups/' -e '^\./\.agents/skills/' -e '^\./\.claude/skills/' || true)"
  [ -z "$left" ] || { echo "left behind: $left"; false; }
  [ -z "$(ls "$TEST_HOME/.claude/skills" "$TEST_HOME/.agents/skills" | grep '^radin-')" ]
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

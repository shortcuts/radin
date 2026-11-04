#!/usr/bin/env bats
# Exercises install.sh against an isolated $HOME with stubbed commands (see helpers/install.bash).
# One of eight shards so the files run side by side.

bats_require_minimum_version 1.5.0
load helpers/install

@test "never overwrites a skill radin did not install" {
  mkdir -p "$TEST_HOME/.claude/skills/unslop"
  printf 'mine\n' >"$TEST_HOME/.claude/skills/unslop/SKILL.md"
  run real_install
  [ "$status" -eq 0 ]
  [ "$(cat "$TEST_HOME/.claude/skills/unslop/SKILL.md")" = mine ]
  [[ "$output" == *"unslop skipped"* ]]
  grep -q '"unslop": false' "$TEST_HOME/.radin/manifest.json"
  grep -q '"technical-writing": true' "$TEST_HOME/.radin/manifest.json"
}

# radin-batch and radin-do read lib docs with the Read tool, which
# takes no `$HOME`. set_lib resolves RADIN_LIB at install time, so the installed
# files carry a path Read accepts. The replayed tree was installed under
# $TEMPLATE/home, which is the HOME the recorded run resolved against.
@test "RADIN_LIB resolves to the installed lib directory" {
  run_install_defaults
  run_doc="$TEST_HOME/.radin/hosts/claude/lib/radin-run.md"
  run ! grep -rq 'RADIN_LIB' "$TEST_HOME/.claude/skills" "$run_doc"
  run ! grep -q '$HOME/.radin/lib' "$run_doc"
  grep -q "$TEMPLATE/home/.radin/hosts/claude/lib/radin-batch-clarify.md" "$run_doc"
  grep -q "$TEMPLATE/home/.radin/hosts/claude/lib/radin-batch-gate.md" "$run_doc"
  run ! grep -q 'full check suite' "$run_doc"
  for s in radin-batch radin-do; do
    grep -q "$TEMPLATE/home/.radin/hosts/claude/lib/radin-run.md" "$TEST_HOME/.claude/skills/$s/SKILL.md"
  done
}

@test "the dispatcher routes subcommands to the installed lib scripts" {
  run_install_defaults
  # cd out of the repo: namespace resolution would otherwise count radin's own backlog.
  cd "$TEST_HOME"
  run env HOME="$TEST_HOME" bash "$TEST_HOME/.radin/bin/radin" backlog count
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
  run env HOME="$TEST_HOME" bash "$TEST_HOME/.radin/bin/radin" nope
  [ "$status" -ne 0 ]
}

# Raw mode turns off ISIG: without explicit handling Ctrl-C would be swallowed
# and the picker would be unquittable.
@test "Ctrl-C in the picker aborts the install" {
  pick_with_keys '\003'
  [ "$PICK_STATUS" -eq 130 ]
  [ -z "$PICKED" ]
}

# A release tag predates files that main's SHIPPED_LIB names, so a piped
# install.sh from main must download main, never the latest release.
@test "a piped install downloads main, not the latest release" {
  FAKE_ROOT="$TEST_HOME/fake-checkout"
  mkdir -p "$FAKE_ROOT"
  cp "$REPO_ROOT/install.sh" "$FAKE_ROOT/install.sh"
  cd "$FAKE_ROOT"
  run bash -c "RADIN_ROOT_OVERRIDE='$TEST_HOME/fetched' bash ./install.sh --yes"
  grep -q 'refs/heads/main.tar.gz' "$TEST_HOME/curl.log"
  run ! grep -q 'refs/tags' "$TEST_HOME/curl.log"
}

# ponytail's SubagentStart hook is what puts its ladder in every execution
# sub-agent, and a plugin's hooks run only while it is enabled at user scope.
@test "a plugin installed but disabled gets enabled, and a failed enable warns" {
  printf '  ❯ ponytail@ponytail\n    Version: 4.10.0\n    Scope: user\n    Status: ✘ disabled\n' > "$TEST_HOME/plugins.txt"
  export MOCK_CLAUDE_LIST="$TEST_HOME/plugins.txt"
  cd "$REPO_ROOT" && run bash ./install.sh --yes
  [ "$status" -eq 0 ]
  [[ "$(cat "$TEST_HOME/claude.log")" == *"plugin enable --scope user ponytail@ponytail"* ]]
  [[ "$output" == *"ponytail is installed but disabled"* ]]
  [[ "$(cat "$TEST_HOME/claude.log")" != *"plugin enable --scope user caveman@caveman"* ]]
}

@test "a half-migrated machine keeps the old directory, says so, and drops the old Read rules" {
  use_real_cc
  seed_old_layout
  mkdir -p "$TEST_HOME/.radin"
  cp "$TEST_HOME/.claude/.radin/manifest.json" "$TEST_HOME/.radin/manifest.json"
  run real_install
  [ "$status" -eq 0 ]
  [[ "$output" == *"is still there, unused"* ]]
  [[ "$output" != *"restart open Claude sessions"* ]]
  [ "$(cat "$TEST_HOME/.claude/.radin/backups/snap/settings.json")" = sentinel ]
  run grep -cF '/.claude/.radin' "$TEST_HOME/.claude/settings.json"
  [ "$output" = 0 ]
  grep -qF "Read(/$TEST_HOME/.radin/**)" "$TEST_HOME/.claude/settings.json"
}

@test "no flag and no terminal installs claude only, even with codex on PATH" {
  mock_cli codex
  cd "$REPO_ROOT" && run bash -c "printf '2\n' | bash ./install.sh"
  [ "$status" -eq 0 ]
  [ "$(manifest_array hosts)" = '"claude"' ]
  [ "$(manifest_array agents_clis)" = '' ]
  [ ! -e "$TEST_HOME/.agents" ]
  [ ! -e "$TEST_HOME/.radin/hosts/agents" ]
  grep -q '"manifest_version": 2' "$TEST_HOME/.radin/manifest.json"
}

@test "--update takes curl for rtk, without a question, when the manifest has no package manager" {
  mock_cli codex
  agents_root
  install_from "$AROOT" --yes --only codex >/dev/null
  sed -i.bak '/"package_manager"/d' "$TEST_HOME/.radin/manifest.json"
  run install_from "$AROOT" --update
  [ "$status" -eq 0 ]
  [[ "$output" != *"Pick 1-"* ]]
  grep -q '"package_manager": "curl"' "$TEST_HOME/.radin/manifest.json"
}

@test "unticking every host is refused and the list stays" {
  wizard_run ' |\r| |\r|\r|\r'
  [ "$WIZ_STATUS" -eq 0 ]
  [[ "$WIZ_SCREEN" == *"pick at least one host"* ]]
  [[ "$WIZ_SCREEN" == *"hosts: claude"* ]]
}

@test "a re-run on an unchanged install rewrites no render file" {
  mock_cli codex
  agents_root
  install_from "$AROOT" --yes --only claude,codex >/dev/null
  touch "$BATS_TEST_TMPDIR/marker"
  sleep 1
  run install_from "$AROOT" --yes --update
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 written"* ]]
  run find "$TEST_HOME/.claude/skills"/radin-* "$TEST_HOME/.agents/skills"/radin-* "$TEST_HOME/.radin/hosts" -type f -newer "$BATS_TEST_TMPDIR/marker"
  [ -z "$output" ]
}

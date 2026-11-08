#!/usr/bin/env bats
# The Codex steps of install.sh under an isolated HOME and CODEX_HOME with
# mocked commands. The file avoids "install" in its name: `make test` runs
# those files in a separate lane.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TEST_HOME="$(mktemp -d)"
  MOCK_BIN="$(mktemp -d)"
  export HOME="$TEST_HOME"
  load helpers/isolate
  isolate_env "$TEST_HOME"
  export CODEX_HOME="$TEST_HOME/codex-home"
  export PATH="$MOCK_BIN:/usr/bin:/bin:/usr/sbin:/sbin"
  export MOCK_BIN MOCK_LOG_DIR="$TEST_HOME"
  unset HOMEBREW_NO_AUTO_UPDATE MOCK_FAIL MOCK_CURL_FAIL
  load helpers/pty
  cc_build "$BATS_TEST_DIRNAME/helpers/mock.c" "$BATS_TEST_DIRNAME/helpers/mock" ||
    skip "a C compiler is needed to build the command mocks"
  cp "$BATS_TEST_DIRNAME/helpers/mock" "$MOCK_BIN/mock"
  for c in brew curl claude npx python3 node gh cc gcc clang codex rtk codebase-memory-mcp; do
    ln "$MOCK_BIN/mock" "$MOCK_BIN/$c"
  done
  AROOT="$BATS_TEST_TMPDIR/root"
  mkdir -p "$AROOT"
  (cd "$REPO_ROOT" && cp -R install.sh bin lib skills scripts hosts "$AROOT/")
  sed 's|~/\.claude|the host skills dir|g' "$AROOT/skills/radin-uninstall/SKILL.md" >"$AROOT/tmp.md"
  mv "$AROOT/tmp.md" "$AROOT/skills/radin-uninstall/SKILL.md"
}

teardown() {
  rm -rf "$TEST_HOME" "$MOCK_BIN"
}

run_install() {
  (cd "$AROOT" && bash ./install.sh --yes "$@" </dev/null)
}

sum() { cksum <"$1"; }

@test "--only codex runs the four companion steps and prints the hooks trust step" {
  run run_install --only codex
  [ "$status" -eq 0 ]
  grep -qx 'plugin marketplace add DietrichGebert/ponytail' "$TEST_HOME/codex.log"
  grep -qx 'plugin add ponytail@ponytail' "$TEST_HOME/codex.log"
  grep -qx 'init -g --codex' "$TEST_HOME/rtk.log"
  grep -qx 'install -y --clients=codex' "$TEST_HOME/codebase-memory-mcp.log"
  grep -q 'caveman/main/install.sh' "$TEST_HOME/curl.log"
  [[ "$output" == *"open /hooks and trust the new hooks"* ]]
}

@test "the AGENTS.md block is neutral, written once and keeps foreign content" {
  mkdir -p "$CODEX_HOME"
  printf 'user text\n<!-- rtk:begin -->\nrtk block\n<!-- rtk:end -->\n' >"$CODEX_HOME/AGENTS.md"
  run_install --only codex >/dev/null
  run run_install --only codex
  [ "$status" -eq 0 ]
  md="$CODEX_HOME/AGENTS.md"
  [ "$(grep -c '<!-- radin:begin -->' "$md")" -eq 1 ]
  [ "$(grep -c '<!-- radin:end -->' "$md")" -eq 1 ]
  grep -q 'user text' "$md"
  grep -q 'rtk block' "$md"
  grep -q 'radin-record. skill' "$md"
  grep -q -- '--host agents backlog show' "$md"
  block="$(sed -n '/<!-- radin:begin -->/,/<!-- radin:end -->/p' "$md")"
  while IFS= read -r word; do
    case "$word" in '' | '#'* | skills/*) continue ;; esac
    [[ "$block" != *"$word"* ]]
  done <"$REPO_ROOT/lib/forbid-agents.txt"
  grep -q '"codex_guidance": true' "$TEST_HOME/.radin/manifest.json"
}

@test "a failing companion warns, the run exits 0 and the block is still written" {
  MOCK_FAIL=codex run run_install --only codex
  [ "$status" -eq 0 ]
  [[ "$output" == *"ponytail-codex install failed"* ]]
  grep -q 'radin:begin' "$CODEX_HOME/AGENTS.md"
  MOCK_CURL_FAIL=caveman run run_install --only codex
  [ "$status" -eq 0 ]
  [[ "$output" == *"caveman-codex install failed"* ]]
  grep -q 'init -g --codex' "$TEST_HOME/rtk.log"
}

@test "a missing codex CLI skips the steps, warns and still writes the block" {
  rm "$MOCK_BIN/codex"
  run run_install --only codex
  [ "$status" -eq 0 ]
  [[ "$output" == *"codex CLI not found"* ]]
  [ ! -e "$TEST_HOME/codex.log" ]
  [ -z "$(grep 'init -g --codex' "$TEST_HOME/rtk.log" 2>/dev/null)" ]
  [[ "$output" != *"open /hooks"* ]]
  grep -q 'radin:begin' "$CODEX_HOME/AGENTS.md"
}

@test "hooks.json is copied to the backups dir and config.toml and roles stay untouched" {
  mkdir -p "$CODEX_HOME/agents"
  printf '{"hooks":1}\n' >"$CODEX_HOME/hooks.json"
  printf 'model = "x"\n' >"$CODEX_HOME/config.toml"
  printf 'role\n' >"$CODEX_HOME/agents/r.toml"
  before="$(sum "$CODEX_HOME/hooks.json") $(sum "$CODEX_HOME/config.toml") $(sum "$CODEX_HOME/agents/r.toml")"
  run run_install --only codex
  [ "$status" -eq 0 ]
  set -- "$TEST_HOME"/.radin/backups/hooks.json.*.bak
  [ -f "$1" ]
  [ "$(cat "$1")" = '{"hooks":1}' ]
  [ "$before" = "$(sum "$CODEX_HOME/hooks.json") $(sum "$CODEX_HOME/config.toml") $(sum "$CODEX_HOME/agents/r.toml")" ]
}

@test "--dry-run --only codex lists the write and run lines and creates nothing" {
  run run_install --dry-run --only codex
  [ "$status" -eq 0 ]
  [ ! -e "$CODEX_HOME" ]
  [ ! -e "$TEST_HOME/codex.log" ]
  [[ "$output" == *"write $CODEX_HOME/AGENTS.md"* ]]
  [[ "$output" == *"run codex plugin marketplace add DietrichGebert/ponytail && codex plugin add ponytail@ponytail"* ]]
  [[ "$output" == *"run rtk init -g --codex"* ]]
  [[ "$output" == *"--only codex --non-interactive"* ]]
  [[ "$output" == *'--clients=codex'* ]]
}

@test "--only claude leaves Codex alone and writes the unchanged Claude block" {
  run run_install --only claude
  [ "$status" -eq 0 ]
  [ ! -e "$CODEX_HOME" ]
  [ ! -e "$TEST_HOME/codex.log" ]
  grep -q '"codex_guidance": false' "$TEST_HOME/.radin/manifest.json"
  md="$TEST_HOME/.claude/CLAUDE.md"
  grep -q '`/radin-record`' "$md"
  grep -q 'invoke `/mattpocock-skills:grilling`' "$md"
  [ "$(grep -c '<!-- radin:begin -->' "$md")" -eq 1 ]
}

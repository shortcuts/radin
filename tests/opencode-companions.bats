#!/usr/bin/env bats
# The opencode steps of install.sh under an isolated HOME and XDG_CONFIG_HOME
# with mocked commands. The file avoids "install" in its name: `make test` runs
# those files in a separate lane. No cc mock: the allow rule needs the real
# radin-cbm-json that install.sh builds.

bats_require_minimum_version 1.5.0

KINDS="planning execution review debug factfind gate merge"

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TEST_HOME="$(mktemp -d)"
  MOCK_BIN="$(mktemp -d)"
  export HOME="$TEST_HOME"
  export XDG_CONFIG_HOME="$TEST_HOME/xdg"
  export PATH="$MOCK_BIN:/usr/bin:/bin:/usr/sbin:/sbin"
  export MOCK_BIN MOCK_LOG_DIR="$TEST_HOME"
  unset HOMEBREW_NO_AUTO_UPDATE MOCK_FAIL MOCK_CURL_FAIL OPENCODE_CONFIG
  load helpers/pty
  cc_build "$BATS_TEST_DIRNAME/helpers/mock.c" "$BATS_FILE_TMPDIR/mock" ||
    skip "a C compiler is needed to build the command mocks"
  cp "$BATS_FILE_TMPDIR/mock" "$MOCK_BIN/mock"
  for c in brew curl claude npx python3 node gh opencode rtk codebase-memory-mcp; do
    ln "$MOCK_BIN/mock" "$MOCK_BIN/$c"
  done
  OC="$XDG_CONFIG_HOME/opencode"
  AROOT="$BATS_TEST_TMPDIR/root"
  mkdir -p "$AROOT"
  (cd "$REPO_ROOT" && cp -R install.sh bin lib skills scripts hosts "$AROOT/")
  sed 's|~/\.claude|the host skills dir|g' "$AROOT/skills/radin-uninstall/SKILL.md" >"$AROOT/tmp.md"
  mv "$AROOT/tmp.md" "$AROOT/skills/radin-uninstall/SKILL.md"
  sed 's|`model: "RADIN_MODEL_REVIEW"`, `effort: "RADIN_EFFORT_REVIEW"`, ||' "$AROOT/lib/radin-batch-recovery.md" >"$AROOT/tmp.md"
  mv "$AROOT/tmp.md" "$AROOT/lib/radin-batch-recovery.md"
}

teardown() {
  rm -rf "$TEST_HOME" "$MOCK_BIN"
}

run_install() {
  (cd "$AROOT" && bash ./install.sh --yes "$@" </dev/null)
}

@test "--only opencode writes seven agent files and runs the four companion steps" {
  run run_install --only opencode
  [ "$status" -eq 0 ]
  for k in $KINDS; do
    f="$OC/agents/radin-$k.md"
    [ -f "$f" ]
    grep -qx 'mode: subagent' "$f"
    grep -qx '  question: deny' "$f"
    grep -qx '  task: deny' "$f"
    [ "$(grep -c '^description: radin leaf' "$f")" -eq 1 ]
    [ -z "$(grep -E '^(model|tools)' "$f")" ]
    [ -z "$(grep RADIN_AGENT_ "$f")" ]
    grep -q "radin $k leaf" "$f"
  done
  grep -qx 'plugin add @dietrichgebert/ponytail' "$TEST_HOME/opencode.log"
  grep -qx 'init -g --opencode' "$TEST_HOME/rtk.log"
  grep -qx 'install -y --clients=opencode' "$TEST_HOME/codebase-memory-mcp.log"
  grep -q 'caveman/main/install.sh' "$TEST_HOME/curl.log"
}

@test "the allow rule lands in opencode.json once, keeps foreign keys and leaves a backup" {
  mkdir -p "$OC"
  printf '{"plugin":["a"],"mcp":{"x":{}}}\n' >"$OC/opencode.json"
  run_install --only opencode >/dev/null
  once="$(cksum <"$OC/opencode.json")"
  run run_install --only opencode
  [ "$status" -eq 0 ]
  [ "$once" = "$(cksum <"$OC/opencode.json")" ]
  grep -q "\"$TEST_HOME/.radin/\*\*\": \"allow\"" "$OC/opencode.json"
  grep -q '"plugin"' "$OC/opencode.json"
  grep -q '"mcp"' "$OC/opencode.json"
  set -- "$TEST_HOME"/.radin/backups/opencode.json.*.bak
  [ -f "$1" ]
  [ "$(cat "$1")" = '{"plugin":["a"],"mcp":{"x":{}}}' ]
}

@test "a JSONC config or a string external_directory stays byte-identical and the rule is printed" {
  mkdir -p "$OC"
  printf '{\n  // mine\n  "plugin": []\n}\n' >"$OC/opencode.jsonc"
  run run_install --only opencode
  [ "$status" -eq 0 ]
  [ ! -e "$OC/opencode.json" ]
  [[ "$output" == *"{\"permission\":{\"external_directory\":{\"$TEST_HOME/.radin/**\":\"allow\""* ]]
  printf '{"permission":{"external_directory":"ask"}}\n' >"$OC/opencode.json"
  run run_install --only opencode
  [ "$status" -eq 0 ]
  [ "$(cat "$OC/opencode.json")" = '{"permission":{"external_directory":"ask"}}' ]
  [[ "$output" == *'"external_directory":{'* ]]
  [ -f "$OC/agents/radin-merge.md" ]
}

@test "OPENCODE_CONFIG takes the rule only and XDG_CONFIG_HOME unset falls back to ~/.config" {
  printf '{}\n' >"$TEST_HOME/custom.json"
  OPENCODE_CONFIG="$TEST_HOME/custom.json" run run_install --only opencode
  [ "$status" -eq 0 ]
  grep -q '"allow"' "$TEST_HOME/custom.json"
  [ ! -e "$OC/opencode.json" ]
  [ -f "$OC/agents/radin-gate.md" ]
  unset XDG_CONFIG_HOME
  run run_install --only opencode
  [ "$status" -eq 0 ]
  [ -f "$TEST_HOME/.config/opencode/agents/radin-gate.md" ]
  grep -q '"allow"' "$TEST_HOME/.config/opencode/opencode.json"
}

@test "the AGENTS.md block is neutral, written once and keeps foreign content" {
  mkdir -p "$OC"
  printf 'user text\n' >"$OC/AGENTS.md"
  run_install --only opencode >/dev/null
  run run_install --only opencode
  [ "$status" -eq 0 ]
  md="$OC/AGENTS.md"
  [ "$(grep -c '<!-- radin:begin -->' "$md")" -eq 1 ]
  grep -q 'user text' "$md"
  grep -q -- '--host agents backlog show' "$md"
  block="$(sed -n '/<!-- radin:begin -->/,/<!-- radin:end -->/p' "$md")"
  while IFS= read -r word; do
    case "$word" in '' | '#'* | skills/*) continue ;; esac
    [[ "$block" != *"$word"* ]]
  done <"$REPO_ROOT/hosts/forbid-agents.txt"
  grep -q '"opencode_guidance": true' "$TEST_HOME/.radin/manifest.json"
  grep -q "\"opencode_allow\": \"$OC/opencode.json\"" "$TEST_HOME/.radin/manifest.json"
}

@test "a failing companion warns, exits 0 and still writes the files" {
  MOCK_FAIL=opencode run run_install --only opencode
  [ "$status" -eq 0 ]
  [[ "$output" == *"ponytail-opencode install failed"* ]]
  [ -f "$OC/agents/radin-planning.md" ]
  grep -q 'radin:begin' "$OC/AGENTS.md"
  MOCK_CURL_FAIL=caveman run run_install --only opencode
  [ "$status" -eq 0 ]
  [[ "$output" == *"caveman-opencode install failed"* ]]
  grep -q 'init -g --opencode' "$TEST_HOME/rtk.log"
}

@test "a missing opencode CLI skips the steps, warns and still writes files and the rule" {
  rm "$MOCK_BIN/opencode"
  run run_install --only opencode
  [ "$status" -eq 0 ]
  [[ "$output" == *"opencode CLI not found"* ]]
  [ ! -e "$TEST_HOME/opencode.log" ]
  [ -z "$(grep 'init -g --opencode' "$TEST_HOME/rtk.log" 2>/dev/null)" ]
  [ -f "$OC/agents/radin-debug.md" ]
  grep -q 'radin:begin' "$OC/AGENTS.md"
  grep -q '"allow"' "$OC/opencode.json"
}

@test "an edited or foreign agent file is kept, and --force backs it up and replaces it" {
  run_install --only opencode >/dev/null
  printf 'mine\n' >"$OC/agents/radin-planning.md"
  rm "$OC/agents/radin-gate.md"
  printf 'foreign\n' >"$OC/agents/radin-gate.md"
  run run_install --only opencode
  [ "$status" -eq 0 ]
  [[ "$output" == *"kept $OC/agents/radin-planning.md"* ]]
  [[ "$output" == *"kept $OC/agents/radin-gate.md"* ]]
  [ "$(cat "$OC/agents/radin-planning.md")" = mine ]
  run run_install --only opencode --force
  [ "$status" -eq 0 ]
  grep -qx 'mode: subagent' "$OC/agents/radin-planning.md"
  grep -qx 'mode: subagent' "$OC/agents/radin-gate.md"
  [ "$(find "$TEST_HOME/.radin/backups" -name 'radin-planning.md*' | wc -l)" -ge 1 ]
}

@test "--dry-run --only opencode lists the writes and runs and creates nothing" {
  run run_install --dry-run --only opencode
  [ "$status" -eq 0 ]
  [ ! -e "$XDG_CONFIG_HOME" ]
  [ ! -e "$TEST_HOME/opencode.log" ]
  for k in $KINDS; do [[ "$output" == *"write $OC/agents/radin-$k.md"* ]]; done
  [[ "$output" == *"write $OC/AGENTS.md"* ]]
  [[ "$output" == *"write $OC/opencode.json"* ]]
  [[ "$output" == *"run opencode plugin add @dietrichgebert/ponytail"* ]]
  [[ "$output" == *"run rtk init -g --opencode"* ]]
  [[ "$output" == *"--only opencode --non-interactive"* ]]
  [[ "$output" == *'--clients=opencode'* ]]
}

@test "--only claude leaves opencode alone" {
  for c in cc gcc clang; do ln "$MOCK_BIN/mock" "$MOCK_BIN/$c"; done
  run run_install --only claude
  [ "$status" -eq 0 ]
  [ ! -e "$XDG_CONFIG_HOME" ]
  [ ! -e "$TEST_HOME/opencode.log" ]
  grep -q '"opencode_guidance": false' "$TEST_HOME/.radin/manifest.json"
}

#!/usr/bin/env bats
# A test that runs a radin script must isolate every host path variable, or a
# developer's real CODEX_HOME or XDG_CONFIG_HOME leaks into the run.

bats_require_minimum_version 1.5.0

@test "every test file that sets HOME calls isolate_env" {
  local f missing=""
  for f in "$BATS_TEST_DIRNAME"/*.bats; do
    grep -qE 'HOME=' "$f" || continue
    grep -q isolate_env "$f" || missing="$missing $(basename "$f")"
  done
  [ -z "$missing" ] || { echo "no isolate_env in:$missing"; false; }
}

@test "isolate_env points every host path variable under the given home" {
  load helpers/isolate
  export CODEX_HOME=/nonexistent/c XDG_CONFIG_HOME=/nonexistent/x OPENCODE_CONFIG=/nonexistent/o CLAUDE_CONFIG_DIR=/nonexistent/d
  isolate_env "$BATS_TEST_TMPDIR/h"
  [ "$HOME" = "$BATS_TEST_TMPDIR/h" ]
  [ "$XDG_CONFIG_HOME" = "$BATS_TEST_TMPDIR/h/.config" ]
  [ "$CODEX_HOME" = "$BATS_TEST_TMPDIR/h/.codex" ]
  [ -z "${OPENCODE_CONFIG:-}" ]
  [ -z "${CLAUDE_CONFIG_DIR:-}" ]
}

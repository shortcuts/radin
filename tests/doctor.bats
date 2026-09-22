#!/usr/bin/env bats
# Exercises lib/radin-doctor.sh: read-only post-install health check.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  CLI="$REPO_ROOT/lib/radin-doctor.sh"
  TEST_HOME="$(mktemp -d)"
  MOCK_BIN="$(mktemp -d)"
  export PATH="$MOCK_BIN:/usr/bin:/bin:/usr/sbin:/sbin"
}

teardown() {
  rm -rf "$TEST_HOME" "$MOCK_BIN"
}

install_all_expected() {
  mkdir -p "$TEST_HOME/.claude/.radin/lib" "$TEST_HOME/.claude/.radin/bin"
  printf '#!/usr/bin/env bash\ntrue\n' > "$TEST_HOME/.claude/.radin/bin/radin"
  for name in radin-execute radin-plan radin-record radin-review radin-setup-hooks radin-show radin-stats radin-doctor radin-uninstall thermo-nuclear; do
    mkdir -p "$TEST_HOME/.claude/skills/$name"
    : > "$TEST_HOME/.claude/skills/$name/SKILL.md"
  done
  printf '#!/usr/bin/env bash\ntrue\n' > "$TEST_HOME/.claude/.radin/lib/radin-namespace.sh"
  printf '#!/usr/bin/env bash\ntrue\n' > "$TEST_HOME/.claude/.radin/lib/radin-json.sh"
  printf '#!/usr/bin/env bash\ntrue\n' > "$TEST_HOME/.claude/.radin/lib/radin-backlog.sh"
  : > "$TEST_HOME/.claude/.radin/lib/radin-tui.c"
  : > "$TEST_HOME/.claude/.radin/lib/radin-cbm-json.c"
  printf '#!/usr/bin/env bash\ntrue\n' > "$TEST_HOME/.claude/.radin/lib/radin-state.sh"
  printf '#!/usr/bin/env bash\ntrue\n' > "$TEST_HOME/.claude/.radin/lib/radin-scope.sh"
  printf '#!/usr/bin/env bash\ntrue\n' > "$TEST_HOME/.claude/.radin/lib/radin-prompt.sh"
printf '#!/usr/bin/env bash\ntrue\n' > "$TEST_HOME/.claude/.radin/lib/radin-cbm-hooks.sh"
  printf '#!/usr/bin/env bash\ntrue\n' > "$TEST_HOME/.claude/.radin/lib/radin-cbm-config.sh"
  : > "$TEST_HOME/.claude/.radin/lib/radin-prioritization.md"
  for k in planning execution debug factfind; do
    : > "$TEST_HOME/.claude/.radin/lib/radin-prompt-$k.md"
  done
  : > "$TEST_HOME/.claude/.radin/lib/radin-execute-recovery.md"
  : > "$TEST_HOME/.claude/.radin/lib/radin-execute-reporting.md"
  : > "$TEST_HOME/.claude/.radin/lib/radin-execute-clarify.md"
  : > "$TEST_HOME/.claude/.radin/lib/radin-execute-session.md"
  : > "$TEST_HOME/.claude/.radin/lib/radin-execute-resume.md"
  printf '#!/usr/bin/env bash\ntrue\n' > "$TEST_HOME/.claude/.radin/lib/radin-update.sh"
  # The real script, not a stub: it carries the RADIN_ token names as its own
  # search pattern, so a stub hides whether the token scan matches itself.
  cp "$CLI" "$TEST_HOME/.claude/.radin/lib/radin-doctor.sh"
  printf '#!/usr/bin/env bash\ntrue\n' > "$TEST_HOME/.claude/.radin/lib/radin-uninstall.sh"
}

@test "exits 0 and reports OK for every file when a full install is present" {
  install_all_expected
  run env HOME="$TEST_HOME" bash "$CLI"
  [ "$status" -eq 0 ]
  [[ "$output" != *"MISSING"* ]]
  [[ "$output" == *"All expected files present."* ]]
  [[ "$output" == *"no unsubstituted token or marker left"* ]]
}

@test "exits 1 and reports MISSING for an absent on-demand lib file" {
  install_all_expected
  rm "$TEST_HOME/.claude/.radin/lib/radin-execute-recovery.md"
  run env HOME="$TEST_HOME" bash "$CLI"
  [ "$status" -eq 1 ]
  [[ "$output" == *"MISSING  radin-execute-recovery.md"* ]]
}

@test "exits 1 and reports MISSING for an absent skill" {
  install_all_expected
  rm -rf "$TEST_HOME/.claude/skills/radin-doctor"
  run env HOME="$TEST_HOME" bash "$CLI"
  [ "$status" -eq 1 ]
  [[ "$output" == *"MISSING  radin-doctor"* ]]
}

@test "exits 1 and reports INVALID for a lib script with bad syntax" {
  install_all_expected
  printf 'if [ true\n' > "$TEST_HOME/.claude/.radin/lib/radin-backlog.sh"
  run env HOME="$TEST_HOME" bash "$CLI"
  [ "$status" -eq 1 ]
  [[ "$output" == *"INVALID  radin-backlog.sh"* ]]
}

@test "reports companion tools as informational, never affecting exit code" {
  install_all_expected
  cat > "$MOCK_BIN/rtk" <<'EOF'
#!/bin/sh
exit 0
EOF
  chmod +x "$MOCK_BIN/rtk"
  run env HOME="$TEST_HOME" bash "$CLI"
  [ "$status" -eq 0 ]
  [[ "$output" == *"rtk"*"found"* ]]
  [[ "$output" == *"codebase-memory-mcp"*"not found"* ]]
}

@test "does not mutate the filesystem outside HOME/.claude" {
  install_all_expected
  WORK="$(mktemp -d)"
  run env HOME="$TEST_HOME" bash -c "cd '$WORK' && bash '$CLI'"
  [ "$status" -eq 0 ]
  [ -z "$(ls -A "$WORK")" ]
  rm -rf "$WORK"
}

@test "reports the codebase-memory-mcp hooks that upstream wrote as OK" {
  install_all_expected
  cat > "$MOCK_BIN/codebase-memory-mcp" <<'MOCK'
#!/bin/sh
exit 0
MOCK
  chmod +x "$MOCK_BIN/codebase-memory-mcp"
  # Verbatim shape of an upstream hook entry: the tool's name appears only as
  # the command path.
  cat > "$TEST_HOME/.claude/settings.json" <<'JSON'
{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"/usr/local/bin/codebase-memory-mcp"}]}]}}
JSON
  run env HOME="$TEST_HOME" bash "$CLI"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK       hooks in $TEST_HOME/.claude/settings.json"* ]]
}

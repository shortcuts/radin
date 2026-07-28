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
  mkdir -p "$TEST_HOME/.claude/agents"
  mkdir -p "$TEST_HOME/.claude/.radin/lib"
  for name in radin-plan radin-record radin-review radin-setup-hooks radin-show radin-stats radin-doctor thermo-nuclear; do
    mkdir -p "$TEST_HOME/.claude/skills/$name"
    : > "$TEST_HOME/.claude/skills/$name/SKILL.md"
  done
  : > "$TEST_HOME/.claude/agents/radin-execute.md"
  printf '#!/usr/bin/env bash\ntrue\n' > "$TEST_HOME/.claude/.radin/lib/radin-namespace.sh"
  printf '#!/usr/bin/env bash\ntrue\n' > "$TEST_HOME/.claude/.radin/lib/radin-backlog.sh"
  : > "$TEST_HOME/.claude/.radin/lib/radin-prioritization.md"
  printf '#!/usr/bin/env bash\ntrue\n' > "$TEST_HOME/.claude/.radin/lib/radin-doctor.sh"
}

@test "syntax is valid" {
  run bash -n "$CLI"
  [ "$status" -eq 0 ]
}

@test "exits 0 and reports OK for every file when a full install is present" {
  install_all_expected
  run env HOME="$TEST_HOME" bash "$CLI"
  [ "$status" -eq 0 ]
  [[ "$output" != *"MISSING"* ]]
  [[ "$output" == *"All expected files present."* ]]
}

@test "exits 1 and reports MISSING for an absent agent file" {
  install_all_expected
  rm "$TEST_HOME/.claude/agents/radin-execute.md"
  run env HOME="$TEST_HOME" bash "$CLI"
  [ "$status" -eq 1 ]
  [[ "$output" == *"MISSING  radin-execute.md"* ]]
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
  [[ "$output" == *"code-review-graph"*"not found"* ]]
}

@test "does not mutate the filesystem outside HOME/.claude" {
  install_all_expected
  WORK="$(mktemp -d)"
  run env HOME="$TEST_HOME" bash -c "cd '$WORK' && bash '$CLI'"
  [ "$status" -eq 0 ]
  [ -z "$(ls -A "$WORK")" ]
  rm -rf "$WORK"
}

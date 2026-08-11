#!/usr/bin/env bats
# Exercises lib/radin-uninstall.sh: removes everything install.sh copies.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  CLI="$REPO_ROOT/lib/radin-uninstall.sh"
  TEST_HOME="$(mktemp -d)"
}

teardown() {
  rm -rf "$TEST_HOME"
}

install_all_expected() {
  mkdir -p "$TEST_HOME/.claude/agents"
  mkdir -p "$TEST_HOME/.claude/.radin/lib"
  for name in radin-plan radin-record radin-review radin-setup-hooks radin-show radin-stats radin-doctor radin-uninstall; do
    mkdir -p "$TEST_HOME/.claude/skills/$name"
    : > "$TEST_HOME/.claude/skills/$name/SKILL.md"
  done
  mkdir -p "$TEST_HOME/.claude/skills/thermo-nuclear"
  : > "$TEST_HOME/.claude/skills/thermo-nuclear/SKILL.md"
  : > "$TEST_HOME/.claude/agents/radin-execute.md"
  printf '#!/usr/bin/env bash\ntrue\n' > "$TEST_HOME/.claude/.radin/lib/radin-namespace.sh"
  printf '#!/usr/bin/env bash\ntrue\n' > "$TEST_HOME/.claude/.radin/lib/radin-json.sh"
  printf '#!/usr/bin/env bash\ntrue\n' > "$TEST_HOME/.claude/.radin/lib/radin-backlog.sh"
  printf '#!/usr/bin/env bash\ntrue\n' > "$TEST_HOME/.claude/.radin/lib/radin-state.sh"
  printf '#!/usr/bin/env bash\ntrue\n' > "$TEST_HOME/.claude/.radin/lib/radin-scope.sh"
  : > "$TEST_HOME/.claude/.radin/lib/radin-prioritization.md"
  printf '#!/usr/bin/env bash\ntrue\n' > "$TEST_HOME/.claude/.radin/lib/radin-doctor.sh"
  cp "$CLI" "$TEST_HOME/.claude/.radin/lib/radin-uninstall.sh"
}

@test "syntax is valid" {
  run bash -n "$CLI"
  [ "$status" -eq 0 ]
}

@test "removes every expected agent, skill, and lib file" {
  install_all_expected
  run env HOME="$TEST_HOME" bash "$TEST_HOME/.claude/.radin/lib/radin-uninstall.sh"
  [ "$status" -eq 0 ]
  [ ! -e "$TEST_HOME/.claude/agents/radin-execute.md" ]
  for name in radin-plan radin-record radin-review radin-setup-hooks radin-show radin-stats radin-doctor radin-uninstall; do
    [ ! -e "$TEST_HOME/.claude/skills/$name" ]
  done
  [ ! -e "$TEST_HOME/.claude/.radin/lib/radin-namespace.sh" ]
  [ ! -e "$TEST_HOME/.claude/.radin/lib/radin-json.sh" ]
  [ ! -e "$TEST_HOME/.claude/.radin/lib/radin-backlog.sh" ]
  [ ! -e "$TEST_HOME/.claude/.radin/lib/radin-state.sh" ]
  [ ! -e "$TEST_HOME/.claude/.radin/lib/radin-scope.sh" ]
  [ ! -e "$TEST_HOME/.claude/.radin/lib/radin-prioritization.md" ]
  [ ! -e "$TEST_HOME/.claude/.radin/lib/radin-doctor.sh" ]
  [ ! -e "$TEST_HOME/.claude/.radin/lib/radin-uninstall.sh" ]
}

@test "leaves thermo-nuclear untouched" {
  install_all_expected
  run env HOME="$TEST_HOME" bash "$TEST_HOME/.claude/.radin/lib/radin-uninstall.sh"
  [ "$status" -eq 0 ]
  [ -f "$TEST_HOME/.claude/skills/thermo-nuclear/SKILL.md" ]
  [[ "$output" == *"thermo-nuclear"*"not vendored"* ]]
}

@test "prints manual removal commands for advisory companion tools" {
  install_all_expected
  run env HOME="$TEST_HOME" bash "$TEST_HOME/.claude/.radin/lib/radin-uninstall.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"brew uninstall rtk"* ]]
  [[ "$output" == *"pipx uninstall code-review-graph"* ]]
  [[ "$output" == *"claude plugin uninstall caveman@caveman"* ]]
}

@test "is idempotent, reporting ABSENT on a second run" {
  install_all_expected
  env HOME="$TEST_HOME" bash "$CLI" > /dev/null
  # Second run: script removed itself, so run the repo copy against the
  # now-empty TEST_HOME to confirm every path reports ABSENT.
  run env HOME="$TEST_HOME" bash "$CLI"
  [ "$status" -eq 0 ]
  [[ "$output" != *"REMOVED"* ]]
  [[ "$output" == *"ABSENT   radin-execute.md"* ]]
}

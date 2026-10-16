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
  for name in $(awk '$1 == "skill" { print $2 }' "$REPO_ROOT/SHIPPED") thermo-nuclear; do
    mkdir -p "$TEST_HOME/.claude/skills/$name"
    : > "$TEST_HOME/.claude/skills/$name/SKILL.md"
  done
  for name in $(awk '$1 == "lib" { print $2 }' "$REPO_ROOT/SHIPPED"); do
    case "$name" in
      *.sh) printf '#!/usr/bin/env bash\ntrue\n' > "$TEST_HOME/.claude/.radin/lib/$name" ;;
      *) : > "$TEST_HOME/.claude/.radin/lib/$name" ;;
    esac
  done
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

@test "reports the pstack skills found or not found without touching the exit code" {
  install_all_expected
  run env HOME="$TEST_HOME" bash "$CLI"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qE '^ +unslop +not found$'
  mkdir -p "$TEST_HOME/.claude/skills/unslop"
  : > "$TEST_HOME/.claude/skills/unslop/SKILL.md"
  run env HOME="$TEST_HOME" bash "$CLI"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qE '^ +unslop +found$'
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

# A plugin's hooks run only when it is enabled at user scope, so a disabled or
# project-only install is not "found".
@test "reports a plugin found only when it is enabled at user scope" {
  install_all_expected
  cat > "$MOCK_BIN/claude" <<'EOF'
#!/bin/sh
cat <<'LIST'
  ❯ caveman@caveman
    Version: 2.7.0
    Scope: project
    Status: ✔ enabled

  ❯ ponytail@ponytail
    Version: 4.10.0
    Scope: user
    Status: ✘ disabled

  ❯ mattpocock-skills@claude-plugins-official
    Version: 1.2.3
    Scope: user
    Status: ✔ enabled
LIST
EOF
  chmod +x "$MOCK_BIN/claude"
  run env HOME="$TEST_HOME" bash "$CLI"
  [ "$status" -eq 0 ]
  [[ "$output" == *"caveman"*"not found"* ]]
  [[ "$output" == *"ponytail"*"disabled"* ]]
  [[ "$output" == *"mattpocock-skills    found"* ]]
}

@test "writes nothing, in HOME or in the working directory" {
  install_all_expected
  WORK="$(mktemp -d)"
  touch "$BATS_TEST_TMPDIR/before"
  run env HOME="$TEST_HOME" bash -c "cd '$WORK' && bash '$CLI'"
  [ "$status" -eq 0 ]
  [ -z "$(find "$TEST_HOME" "$WORK" -newer "$BATS_TEST_TMPDIR/before")" ]
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

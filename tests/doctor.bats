#!/usr/bin/env bats
# Exercises lib/radin-doctor.sh: read-only post-install health check.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  CLI="$REPO_ROOT/lib/radin-doctor.sh"
  TEST_HOME="$(mktemp -d)"
  MOCK_BIN="$(mktemp -d)"
  export PATH="$MOCK_BIN:/usr/bin:/bin:/usr/sbin:/sbin"
  load helpers/pty
  cc_build "$REPO_ROOT/lib/radin-cbm-json.c" "$REPO_ROOT/lib/radin-cbm-json" ||
    skip "a C compiler is needed to build the JSON helper"
}

teardown() {
  rm -rf "$TEST_HOME" "$MOCK_BIN"
}

install_all_expected() {
  mkdir -p "$TEST_HOME/.radin/lib" "$TEST_HOME/.radin/bin" "$TEST_HOME/.radin/hosts/claude/lib"
  printf '#!/usr/bin/env bash\ntrue\n' > "$TEST_HOME/.radin/bin/radin"
  for name in $(awk '$1 == "skill" { print $2 }' "$REPO_ROOT/SHIPPED") thermo-nuclear; do
    mkdir -p "$TEST_HOME/.claude/skills/$name"
    : > "$TEST_HOME/.claude/skills/$name/SKILL.md"
  done
  for name in $(awk '$1 == "lib" { print $2 }' "$REPO_ROOT/SHIPPED"); do
    case "$name" in
      *.sh) printf '#!/usr/bin/env bash\ntrue\n' > "$TEST_HOME/.radin/lib/$name" ;;
      *) : > "$TEST_HOME/.radin/lib/$name" ;;
    esac
  done
  for name in $(awk '$1 == "hostlib" { print $2 }' "$REPO_ROOT/SHIPPED"); do
    : > "$TEST_HOME/.radin/hosts/claude/lib/$name"
  done
}

@test "exits 1 and reports MISSING for an absent on-demand lib file" {
  install_all_expected
  rm "$TEST_HOME/.radin/hosts/claude/lib/radin-batch-recovery.md"
  run env HOME="$TEST_HOME" bash "$CLI"
  [ "$status" -eq 1 ]
  [[ "$output" == *"MISSING  radin-batch-recovery.md"* ]]
}

@test "exits 1 and reports MISSING for an absent skill" {
  install_all_expected
  rm -rf "$TEST_HOME/.claude/skills/radin-stats"
  run env HOME="$TEST_HOME" bash "$CLI"
  [ "$status" -eq 1 ]
  [[ "$output" == *"MISSING  radin-stats"* ]]
}

@test "exits 1 and reports INVALID for a lib script with bad syntax" {
  install_all_expected
  printf 'if [ true\n' > "$TEST_HOME/.radin/lib/radin-backlog.sh"
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

with_helper() {
  install_all_expected
  cp "$REPO_ROOT/lib/radin-cbm-json" "$TEST_HOME/.radin/bin/radin-cbm-json"
}

@test "exits 1 and names a hook command that is not on PATH" {
  with_helper
  cat > "$TEST_HOME/.claude/settings.json" <<'JSON'
{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"caveman-session"}]}]}}
JSON
  run env HOME="$TEST_HOME" bash "$CLI"
  [ "$status" -eq 1 ]
  [[ "$output" == *"INVALID  hook "*"caveman-session"* ]]
  [[ "$output" == *"1 check(s) failed"* ]]
}

@test "passes a bare name on PATH, an absolute executable with args, and an sh -c wrapper" {
  with_helper
  printf '#!/bin/sh\n' > "$MOCK_BIN/rtk"
  chmod +x "$MOCK_BIN/rtk"
  cat > "$TEST_HOME/.claude/settings.json" <<JSON
{"hooks":{"SessionStart":[{"hooks":[
{"type":"command","command":"rtk hook claude"},
{"type":"command","command":"$MOCK_BIN/rtk","args":["x"]},
{"type":"command","command":"/bin/sh -c 'nothing-here || true'"}]}]}}
JSON
  run env HOME="$TEST_HOME" bash "$CLI"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK       every hook command resolves"* ]]
}

@test "exits 1 for an absolute hook path that is not executable" {
  with_helper
  : > "$MOCK_BIN/plain"
  cat > "$TEST_HOME/.claude/settings.json" <<JSON
{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"$MOCK_BIN/plain"}]}]}}
JSON
  run env HOME="$TEST_HOME" bash "$CLI"
  [ "$status" -eq 1 ]
  [[ "$output" == *"INVALID  hook "*"$MOCK_BIN/plain"* ]]
}

@test "skips the hook check without the helper" {
  install_all_expected
  cat > "$TEST_HOME/.claude/settings.json" <<'JSON'
{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"caveman-session"}]}]}}
JSON
  run env HOME="$TEST_HOME" bash "$CLI"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SKIPPED  hook commands"* ]]
}

agents_doctor_setup() {
  install_all_expected
  cp "$REPO_ROOT/lib/companion-skills.txt" "$REPO_ROOT/lib/skill-names-agents.txt" "$TEST_HOME/.radin/lib/"
  printf '{\n  "agents_clis": [%s],\n}\n' "$1" >"$TEST_HOME/.radin/manifest.json"
  for name in $(awk '!/^#/ && NF { print $1 }' "$REPO_ROOT/lib/companion-skills.txt"); do
    mkdir -p "$TEST_HOME/.agents/skills/$name"
    : >"$TEST_HOME/.agents/skills/$name/SKILL.md"
  done
}

@test "prints no agents skills section when the manifest lists no agents CLI" {
  agents_doctor_setup ''
  rm -rf "$TEST_HOME/.agents/skills/grilling"
  run env HOME="$TEST_HOME" bash "$CLI"
  [ "$status" -eq 0 ]
  [[ "$output" != *"Agents companion skills"* ]]
}

@test "exits 1 and reports MISSING for an invoked agents skill that does not resolve" {
  agents_doctor_setup '"codex"'
  rm -rf "$TEST_HOME/.agents/skills/grilling"
  run env HOME="$TEST_HOME" bash "$CLI"
  [ "$status" -eq 1 ]
  [[ "$output" == *"  MISSING  grilling"* ]]
}

@test "reports a non-invoked agents skill as not found without touching the exit code" {
  agents_doctor_setup '"codex"'
  rm -rf "$TEST_HOME/.agents/skills/writing-for-agents"
  run env HOME="$TEST_HOME" bash "$CLI"
  [ "$status" -eq 0 ]
  [[ "$output" == *"writing-for-agents"*"not found"* ]]
}

@test "counts a copy in the opencode skills dir only when opencode is an agents CLI" {
  agents_doctor_setup '"opencode"'
  rm -rf "$TEST_HOME/.agents/skills/grilling"
  mkdir -p "$TEST_HOME/.config/opencode/skills/grilling"
  : >"$TEST_HOME/.config/opencode/skills/grilling/SKILL.md"
  run env HOME="$TEST_HOME" bash "$CLI"
  [ "$status" -eq 0 ]
  [[ "$output" == *"  OK       grilling"* ]]
  printf '{\n  "agents_clis": ["codex"],\n}\n' >"$TEST_HOME/.radin/manifest.json"
  run env HOME="$TEST_HOME" bash "$CLI"
  [ "$status" -eq 1 ]
}

# A codex/opencode install: the agents render, the forbid lists and a manifest.
hosts_setup() {
  install_all_expected
  local name
  cp "$REPO_ROOT/lib/companion-skills.txt" "$REPO_ROOT/lib/skill-names-agents.txt" "$REPO_ROOT"/lib/forbid-*.txt "$TEST_HOME/.radin/lib/"
  mkdir -p "$TEST_HOME/.radin/hosts/agents/lib"
  for name in $(awk '$1 == "hostlib" { print $2 }' "$REPO_ROOT/SHIPPED"); do
    : >"$TEST_HOME/.radin/hosts/agents/lib/$name"
  done
  for name in $(awk '$1 == "skill" { print $2 }' "$REPO_ROOT/SHIPPED") $(awk '!/^#/ && NF { print $1 }' "$REPO_ROOT/lib/companion-skills.txt"); do
    mkdir -p "$TEST_HOME/.agents/skills/$name"
    : >"$TEST_HOME/.agents/skills/$name/SKILL.md"
  done
  mkdir -p "$TEST_HOME/.codex" "$TEST_HOME/.config/opencode/agents"
  printf '<!-- radin:begin -->\nx\n<!-- radin:end -->\n' | tee "$TEST_HOME/.codex/AGENTS.md" >"$TEST_HOME/.config/opencode/AGENTS.md"
  printf -- '---\ndescription: d\nmode: subagent\n---\nbody\n' >"$TEST_HOME/.config/opencode/agents/radin-planning.md"
  printf '{"permission":{"external_directory":{"%s/.radin/**":"allow"}}}\n' "$TEST_HOME" >"$TEST_HOME/.config/opencode/opencode.json"
  write_manifest "$1" "$2"
}

write_manifest() {
  printf '{\n  "opencode_allow": "",\n  "hosts": [%s],\n  "agents_clis": [%s],\n}\n' "$1" "$2" >"$TEST_HOME/.radin/manifest.json"
}

mock_cli() {
  printf '#!/bin/sh\n%s\n' "$2" >"$MOCK_BIN/$1"
  chmod +x "$MOCK_BIN/$1"
}

doctor() { run env HOME="$TEST_HOME" bash "$CLI"; }

@test "a codex-only install needs no Claude files" {
  hosts_setup '"codex"' '"codex"'
  rm -rf "$TEST_HOME/.claude" "$TEST_HOME/.radin/hosts/claude"
  doctor
  [ "$status" -eq 0 ]
  [[ "$output" != *"Skills ("* ]]
  [[ "$output" == *"Codex:"* ]]
  [[ "$output" != *"opencode:"* ]]
}

@test "a claude-only manifest prints no host section" {
  install_all_expected
  write_manifest '"claude"' ''
  doctor
  [ "$status" -eq 0 ]
  [[ "$output" != *"Agents render"* && "$output" != *"Codex:"* && "$output" != *"opencode:"* && "$output" != *"Digests"* ]]
}

@test "digests: a match is OK, a changed file fails, a missing files key skips the section" {
  hosts_setup '"codex"' '"codex"'
  p=".agents/skills/radin-do/SKILL.md"
  d="$(shasum -a 256 "$TEST_HOME/$p" | cut -d' ' -f1)"
  other="$(printf 'x' | shasum -a 256 | cut -d' ' -f1)"
  printf '{\n  "hosts": ["codex"],\n  "agents_clis": ["codex"],\n  "files": {\n    "%s": "%s",\n    ".claude/skills/radin-do/SKILL.md": "%s"\n  }\n}\n' "$p" "$d" "$other" >"$TEST_HOME/.radin/manifest.json"
  doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK       1 file(s) match their recorded digest"* ]]
  printf 'edit' >>"$TEST_HOME/$p"
  doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"INVALID  $TEST_HOME/$p (changed since install"* ]]
  write_manifest '"codex"' '"codex"'
  doctor
  [ "$status" -eq 0 ]
  [[ "$output" != *"Digests"* ]]
}

@test "an unresolved @@skill: token in the agents render fails" {
  hosts_setup '"codex"' '"codex"'
  printf 'use @@skill:grilling@@\n' >"$TEST_HOME/.radin/hosts/agents/lib/radin-run.md"
  doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"INVALID  unsubstituted RADIN_ token"* ]]
}

@test "a forbidden string fails the agents render and passes the claude render" {
  hosts_setup '"codex"' '"codex"'
  printf 'AskUserQuestion\n' >"$TEST_HOME/.radin/hosts/agents/lib/radin-run.md"
  doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"INVALID  $TEST_HOME/.radin/hosts/agents/lib/radin-run.md (forbidden string \"AskUserQuestion\" in the agents render)"* ]]
  hosts_setup '"claude"' ''
  printf 'AskUserQuestion\n' >"$TEST_HOME/.radin/hosts/claude/lib/radin-run.md"
  doctor
  [ "$status" -eq 0 ]
}

@test "with both CLIs a skill found only in the opencode dir is MISSING, with opencode alone it is OK" {
  hosts_setup '"codex", "opencode"' '"codex", "opencode"'
  rm -rf "$TEST_HOME/.agents/skills/grilling"
  mkdir -p "$TEST_HOME/.config/opencode/skills/grilling"
  : >"$TEST_HOME/.config/opencode/skills/grilling/SKILL.md"
  doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"  MISSING  grilling"* ]]
  write_manifest '"opencode"' '"opencode"'
  doctor
  [ "$status" -eq 0 ]
}

@test "Codex hooks: missing, untrusted and trusted are notes that exit 0" {
  hosts_setup '"codex"' '"codex"'
  doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"NOTE     no Codex hooks found"* ]]
  printf '{"hooks":[{"command":"x"}]}\n' >"$TEST_HOME/.codex/hooks.json"
  doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"open /hooks in Codex and trust the new hooks once"* ]]
  printf '[hooks.state."k"]\ntrusted_hash = "h"\n' >"$TEST_HOME/.codex/config.toml"
  doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK       Codex hook trust recorded"* ]]
}

@test "Codex skills probe: a listing with radin-batch is OK, a failing codex is a note" {
  hosts_setup '"codex"' '"codex"'
  mock_cli codex 'echo radin-batch'
  doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK       Codex lists radin skills"* ]]
  mock_cli codex 'exit 1'
  doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"NOTE     Codex skills listing did not answer"* ]]
}

@test "opencode version: v2.2.5 and 1.18.29 pass, 1.18.28 fails, unparsable is a note" {
  hosts_setup '"opencode"' '"opencode"'
  for v in 2.2.5 1.18.29; do
    mock_cli opencode "echo opencode v$v"
    doctor
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK       opencode $v"* ]]
  done
  mock_cli opencode 'echo opencode v1.18.28'
  doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"INVALID  opencode 1.18.28 is below 1.18.29"* ]]
  mock_cli opencode 'echo dev'
  doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"NOTE     opencode version not readable"* ]]
}

@test "opencode agent files: a tools line or an unclosed front matter fails" {
  hosts_setup '"opencode"' '"opencode"'
  f="$TEST_HOME/.config/opencode/agents/radin-planning.md"
  printf -- '---\ndescription: d\nmode: subagent\ntools: [bash]\n---\n' >"$f"
  doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"INVALID  $f (tools line stops opencode from booting)"* ]]
  printf -- '---\ndescription: d\nmode: subagent\n' >"$f"
  doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"front matter missing or not closed"* ]]
}

@test "opencode external_directory rule: present passes, absent fails, the manifest path wins" {
  hosts_setup '"opencode"' '"opencode"'
  doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK       external_directory rule"* ]]
  printf '{}\n' >"$TEST_HOME/.config/opencode/opencode.json"
  doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"MISSING  opencode external_directory rule"* ]]
  printf '{"permission":{"external_directory":{"%s/.radin/**":"allow"}}}\n' "$TEST_HOME" >"$TEST_HOME/custom.json"
  printf '{\n  "opencode_allow": "%s/custom.json",\n  "hosts": ["opencode"],\n  "agents_clis": ["opencode"],\n}\n' "$TEST_HOME" >"$TEST_HOME/.radin/manifest.json"
  doctor
  [ "$status" -eq 0 ]
}

@test "the shared-skills note appears with both CLIs and not with one" {
  hosts_setup '"codex", "opencode"' '"codex", "opencode"'
  doctor
  [[ "$output" == *"codex and opencode share ~/.agents/skills"* ]]
  write_manifest '"codex"' '"codex"'
  doctor
  [[ "$output" != *"share ~/.agents/skills"* ]]
}

@test "a CLI not on PATH prints not found and exits 0" {
  hosts_setup '"codex", "opencode"' '"codex", "opencode"'
  doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"codex"*"not found (companion steps were skipped"* ]]
  [[ "$output" == *"opencode"*"not found (companion steps were skipped"* ]]
}

@test "a missing agents skills dir fails the home layout" {
  hosts_setup '"codex"' '"codex"'
  rm -rf "$TEST_HOME/.agents"
  doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"MISSING  $TEST_HOME/.agents/skills"* ]]
}

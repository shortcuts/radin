#!/usr/bin/env bats
# Exercises lib/radin-uninstall.sh: removes everything install.sh copies.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  CLI="$REPO_ROOT/lib/radin-uninstall.sh"
  TEST_HOME="$(mktemp -d)"
  load helpers/isolate
  isolate_env "$TEST_HOME"
}

teardown() {
  rm -rf "$TEST_HOME"
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
  cp "$CLI" "$TEST_HOME/.radin/lib/radin-uninstall.sh"
}

@test "leaves thermo-nuclear untouched" {
  install_all_expected
  run env HOME="$TEST_HOME" bash "$TEST_HOME/.radin/lib/radin-uninstall.sh"
  [ "$status" -eq 0 ]
  [ -f "$TEST_HOME/.claude/skills/thermo-nuclear/SKILL.md" ]
  [[ "$output" == *"thermo-nuclear"*"not vendored"* ]]
}

@test "leaves the pstack skills untouched" {
  install_all_expected
  mkdir -p "$TEST_HOME/.claude/skills/unslop"
  : > "$TEST_HOME/.claude/skills/unslop/SKILL.md"
  run env HOME="$TEST_HOME" bash "$TEST_HOME/.radin/lib/radin-uninstall.sh"
  [ "$status" -eq 0 ]
  [ -f "$TEST_HOME/.claude/skills/unslop/SKILL.md" ]
  [[ "$output" == *"unslop"*"cursor/plugins"* ]]
}

@test "prints manual removal commands for advisory companion tools" {
  install_all_expected
  run env HOME="$TEST_HOME" bash "$TEST_HOME/.radin/lib/radin-uninstall.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"codebase-memory-mcp uninstall"* ]]
  [[ "$output" == *"claude plugin uninstall caveman@caveman"* ]]
}

# rtk and headroom come from whichever manager the install asked about, so a
# brew command on a mise machine would name a tool the user never installed.
@test "names the removal command of the recorded package manager" {
  install_all_expected
  printf '{\n  "package_manager": "mise"\n}\n' > "$TEST_HOME/.radin/manifest.json"
  run env HOME="$TEST_HOME" bash "$TEST_HOME/.radin/lib/radin-uninstall.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"mise rm -g aqua:rtk-ai/rtk"* ]]
  [[ "$output" == *"mise rm -g pipx:headroom-ai"* ]]
  [[ "$output" != *"brew uninstall rtk"* ]]
}

@test "is idempotent, reporting ABSENT on a second run" {
  install_all_expected
  env HOME="$TEST_HOME" bash "$CLI" > /dev/null
  # Second run: script removed itself, so run the repo copy against the
  # now-empty TEST_HOME to confirm every path reports ABSENT.
  run env HOME="$TEST_HOME" bash "$CLI"
  [ "$status" -eq 0 ]
  [[ "$output" != *"REMOVED"* ]]
  [[ "$output" == *"ABSENT   .radin/lib/radin-backlog.sh"* ]]
}

# Three-host fixture with a real manifest. Every file holds its own name, so a
# digest in the manifest is the digest of that content.
sum_of() { shasum -a 256 "$1" | cut -d' ' -f1; }

manifest_install() {
  local rel files="" sep=""
  install_all_expected
  for rel in .claude/skills/radin-batch/SKILL.md .claude/skills/radin-do/SKILL.md \
    .agents/skills/radin-batch/SKILL.md .config/opencode/agents/radin-review.md \
    .radin/hosts/agents/lib/radin-run.md; do
    mkdir -p "$TEST_HOME/$(dirname "$rel")"
    printf '%s\n' "$rel" > "$TEST_HOME/$rel"
  done
  while IFS= read -r rel; do
    files="$files$sep
    \"$rel\": \"$(sum_of "$TEST_HOME/$rel")\""
    sep=","
  done < <(cd "$TEST_HOME" && find .claude/skills .agents/skills .radin .config/opencode/agents -type f ! -path '.claude/skills/thermo-nuclear/*' | sort)
  cat > "$TEST_HOME/.radin/manifest.json" <<JSON
{
  "manifest_version": 2,
  "opencode_allow": "$TEST_HOME/.config/opencode/opencode.json",
  "hosts": ["claude", "codex", "opencode"],
  "agents_clis": ["codex", "opencode"],
  "files": {$files
  },
  "backups": {
  }
}
JSON
  printf 'x\n' > "$TEST_HOME/.radin/install_root"
  for f in .claude/CLAUDE.md .codex/AGENTS.md .config/opencode/AGENTS.md; do
    mkdir -p "$TEST_HOME/$(dirname "$f")"
    printf 'mine\n\n<!-- radin:begin -->\nradin text\n<!-- radin:end -->\n' > "$TEST_HOME/$f"
  done
  printf '{"permission":{"external_directory":{"%s/.radin/**":"allow","/keep/**":"allow"}}}\n' "$TEST_HOME" \
    > "$TEST_HOME/.config/opencode/opencode.json"
  cc -o "$TEST_HOME/.radin/bin/radin-cbm-json" "$REPO_ROOT/lib/radin-cbm-json.c"
}
run_uninstall() { run env HOME="$TEST_HOME" bash "$TEST_HOME/.radin/lib/radin-uninstall.sh" "$@"; }

@test "removes every host's files, blocks and the opencode rule" {
  manifest_install
  run_uninstall
  [ "$status" -eq 0 ]
  [[ "$output" == *"STRIPPED"* && "$output" == *"radin removed."* ]]
  [ ! -e "$TEST_HOME/.claude/skills/radin-batch" ]
  [ ! -e "$TEST_HOME/.agents/skills/radin-batch" ]
  [ ! -e "$TEST_HOME/.config/opencode/agents/radin-review.md" ]
  [ ! -e "$TEST_HOME/.radin" ]
  [ -d "$TEST_HOME/.claude/skills" ]
  for f in .claude/CLAUDE.md .codex/AGENTS.md .config/opencode/AGENTS.md; do
    [ "$(cat "$TEST_HOME/$f")" = "mine" ]
  done
  grep -q '/keep/\*\*' "$TEST_HOME/.config/opencode/opencode.json"
  run ! grep -q '\.radin/\*\*' "$TEST_HOME/.config/opencode/opencode.json"
}

@test "keeps an edited file and the manifest, --force removes them" {
  manifest_install
  printf 'mine\n' >> "$TEST_HOME/.agents/skills/radin-batch/SKILL.md"
  run_uninstall
  [ "$status" -eq 0 ]
  [[ "$output" == *"KEPT (edited) .agents/skills/radin-batch/SKILL.md"* ]]
  [ -f "$TEST_HOME/.agents/skills/radin-batch/SKILL.md" ]
  [ -f "$TEST_HOME/.radin/manifest.json" ]
  run env HOME="$TEST_HOME" bash "$CLI" --force
  [ "$status" -eq 0 ]
  [ ! -e "$TEST_HOME/.agents/skills/radin-batch" ]
  [ ! -e "$TEST_HOME/.radin" ]
}

@test "never removes a dash-digest file or a foreign file, even with --force" {
  manifest_install
  sed -i.bak 's|\("\.agents/skills/radin-batch/SKILL.md": "\)[0-9a-f]*|\1-|' "$TEST_HOME/.radin/manifest.json"
  printf 'notes\n' > "$TEST_HOME/.claude/skills/radin-batch/notes.md"
  run_uninstall --force
  [ "$status" -eq 0 ]
  [ -f "$TEST_HOME/.agents/skills/radin-batch/SKILL.md" ]
  [ -f "$TEST_HOME/.claude/skills/radin-batch/notes.md" ]
  [ ! -e "$TEST_HOME/.claude/skills/radin-batch/SKILL.md" ]
  [[ "$output" == *"KEPT (holds other files)"*"radin-batch"* ]]
}

@test "a half-installed host reports ABSENT and exits 0" {
  manifest_install
  rm -rf "$TEST_HOME/.agents"
  run_uninstall
  [ "$status" -eq 0 ]
  [[ "$output" == *"ABSENT   .agents/skills/radin-batch/SKILL.md"* ]]
}

@test "without a manifest it leaves the agents render and says so" {
  install_all_expected
  mkdir -p "$TEST_HOME/.agents/skills/radin-batch"
  : > "$TEST_HOME/.agents/skills/radin-batch/SKILL.md"
  run_uninstall
  [ "$status" -eq 0 ]
  [ -f "$TEST_HOME/.agents/skills/radin-batch/SKILL.md" ]
  [[ "$output" == *"agents render, remove by hand:"*".agents/skills/radin-batch"* ]]
}

@test "--dry-run changes no byte" {
  manifest_install
  before="$(cd "$TEST_HOME" && find . -type f -exec shasum {} + | sort | shasum)"
  run_uninstall --dry-run --force
  [ "$status" -eq 0 ]
  after="$(cd "$TEST_HOME" && find . -type f -exec shasum {} + | sort | shasum)"
  [ "$before" = "$after" ]
  [[ "$output" == *"WOULD REMOVE"* ]]
}

@test "unbalanced markers leave the file byte-identical" {
  manifest_install
  printf 'mine\n<!-- radin:begin -->\nno end\n' > "$TEST_HOME/.codex/AGENTS.md"
  cp "$TEST_HOME/.codex/AGENTS.md" "$TEST_HOME/before"
  run_uninstall
  [ "$status" -eq 0 ]
  cmp "$TEST_HOME/before" "$TEST_HOME/.codex/AGENTS.md"
  [[ "$output" == *"KEPT (markers unbalanced)"* ]]
}

@test "a symlinked CLAUDE.md stays a symlink" {
  manifest_install
  mv "$TEST_HOME/.claude/CLAUDE.md" "$TEST_HOME/dotfile.md"
  ln -s "$TEST_HOME/dotfile.md" "$TEST_HOME/.claude/CLAUDE.md"
  run_uninstall
  [ "$status" -eq 0 ]
  [ -L "$TEST_HOME/.claude/CLAUDE.md" ]
  [ "$(cat "$TEST_HOME/dotfile.md")" = "mine" ]
}

@test "an unknown argument exits 2" {
  run env HOME="$TEST_HOME" bash "$CLI" --nope
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage:"* ]]
}

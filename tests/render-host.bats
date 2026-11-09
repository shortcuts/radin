#!/usr/bin/env bats
# Exercises scripts/render-host.sh. The prose lints live in tests/lints.rs.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  RENDER="$REPO_ROOT/scripts/render-host.sh"
  T="$(mktemp -d)"
}

teardown() {
  rm -rf "$T"
}

src() { printf '%s\n' "$@" > "$T/in.md"; }

@test "keeps outside text and matching blocks, drops others and every marker" {
  src one '<!-- host:claude -->' c-only '<!-- /host -->' '<!-- host:agents -->' a-only '<!-- /host -->' '<!-- host:claude,agents -->' both '<!-- /host -->' two
  run "$RENDER" "$T/in.md" claude
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'one\nc-only\nboth\ntwo')" ]
  run "$RENDER" "$T/in.md" agents
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'one\na-only\nboth\ntwo')" ]
}

@test "--batch renders each pair like a single run, keeps an empty file empty and stops at a bad file" {
  printf '%s\n' one '<!-- host:claude -->' c-only '<!-- /host -->' >"$T/a.md"
  printf '%s\n' two '<!-- host:agents -->' a-only '<!-- /host -->' >"$T/b.md"
  : >"$T/empty.md"
  printf '%s\n' bad '<!-- host:claude -->' body >"$T/bad.md"
  printf '%s\n' last >"$T/c.md"
  run bash -c "printf '%s\t%s\n' '$T/a.md' '$T/a.out' '$T/b.md' '$T/b.out' '$T/empty.md' '$T/empty.out' | '$RENDER' --batch claude"
  [ "$status" -eq 0 ]
  [ "$(cat "$T/a.out")" = "$("$RENDER" "$T/a.md" claude)" ]
  [ "$(cat "$T/b.out")" = "$("$RENDER" "$T/b.md" claude)" ]
  [ -f "$T/empty.out" ] && [ ! -s "$T/empty.out" ]
  run bash -c "printf '%s\t%s\n' '$T/bad.md' '$T/bad.out' '$T/c.md' '$T/c.out' | '$RENDER' --batch claude"
  [ "$status" -eq 1 ]
  [ "$output" = "$T/bad.md:2: host block never closed" ]
  [ ! -e "$T/bad.out" ] && [ ! -e "$T/c.out" ]
}

@test "fails with FILE:LINE on an unclosed block" {
  src one '<!-- host:claude -->' body
  run "$RENDER" "$T/in.md" claude
  [ "$status" -eq 1 ]
  [ "$output" = "$T/in.md:2: host block never closed" ]
}

@test "fails with FILE:LINE on a stray close" {
  src one '<!-- /host -->'
  run "$RENDER" "$T/in.md" claude
  [ "$status" -eq 1 ]
  [ "$output" = "$T/in.md:2: <!-- /host --> with no open block" ]
}

@test "fails with FILE:LINE on a nested block" {
  src '<!-- host:claude -->' '<!-- host:agents -->'
  run "$RENDER" "$T/in.md" claude
  [ "$status" -eq 1 ]
  [ "$output" = "$T/in.md:2: nested host block, opened at line 1" ]
}

@test "fails with FILE:LINE on an unknown host name" {
  src one '<!-- host:claude,mars -->'
  run "$RENDER" "$T/in.md" claude
  [ "$status" -eq 1 ]
  [ "$output" = "$T/in.md:2: unknown host \"mars\"" ]
}

@test "fails with FILE:LINE on a marker that shares its line" {
  src one 'text <!-- host:claude -->'
  run "$RENDER" "$T/in.md" claude
  [ "$status" -eq 1 ]
  [ "$output" = "$T/in.md:2: host marker must sit alone on its line" ]
}

@test "fails on an unknown HOST" {
  src one
  run "$RENDER" "$T/in.md" mars
  [ "$status" -eq 1 ]
}

@test "a forbidden string outside a block fails the agents render" {
  src one 'call SendMessage now'
  run "$RENDER" "$T/in.md" agents
  [ "$status" -eq 1 ]
  [ "$output" = "$T/in.md: forbidden string \"SendMessage\" survives in the agents render" ]
}

@test "the same string inside a claude block passes the agents render" {
  src one '<!-- host:claude -->' 'call SendMessage now' '<!-- /host -->'
  run "$RENDER" "$T/in.md" agents
  [ "$status" -eq 0 ]
  [ "$output" = one ]
}

@test "--hits prints the surviving string and exits 0" {
  src 'call SendMessage now'
  run "$RENDER" --hits "$T/in.md" agents
  [ "$status" -eq 0 ]
  [ "$output" = SendMessage ]
}

@test "the agents render of each ask site has no AskUserQuestion" {
  ask_hosts
  for f in lib/radin-run.md lib/radin-batch-session.md lib/radin-batch-merge.md lib/radin-batch-clarify.md skills/radin-review/SKILL.md skills/radin-record/SKILL.md skills/radin-do/SKILL.md; do
    run env RADIN_LIB_DIR="$T/h" "$RENDER" "$REPO_ROOT/$f" agents
    [ "$status" -eq 0 ]
  done
}

@test "the agents render of each file that asks names the ask rule" {
  ask_hosts
  for f in lib/radin-run.md lib/radin-batch-merge.md skills/radin-review/SKILL.md skills/radin-record/SKILL.md skills/radin-do/SKILL.md; do
    run env RADIN_LIB_DIR="$T/h" "$RENDER" "$REPO_ROOT/$f" agents
    [ "$status" -eq 0 ]
    [[ "$output" == *radin-ask-rule.md* ]]
  done
}

@test "the agents render of the leaf contract and explore rule names no claude-only or question tool" {
  for f in lib/radin-leaf-contract.md lib/radin-explore-rule.md; do
    run "$RENDER" "$REPO_ROOT/$f" agents
    [ "$status" -eq 0 ]
    [[ "$output" != *Monitor* ]]
    [[ "$output" != *Workflow* ]]
    [[ "$output" != *TaskStop* ]]
    [[ "$output" != *ToolSearch* ]]
    [[ "$output" != *"4 minutes"* ]]
    [[ "$output" != *AskUserQuestion* ]]
  done
  run "$RENDER" "$REPO_ROOT/lib/radin-leaf-contract.md" agents
  [[ "$output" == *"no question tool"* ]]
  run "$RENDER" "$REPO_ROOT/lib/radin-leaf-contract.md" claude
  [[ "$output" == *Monitor* ]]
  [[ "$output" == *Workflow* ]]
}

@test "the assembled factfind prompt carries the leaf rules of each host" {
  for host in claude agents; do
    H="$T/$host"
    mkdir -p "$H"
    cp -R "$REPO_ROOT/lib" "$H/lib"
    for f in "$H"/lib/*.md; do
      run env RADIN_LIB_DIR="$H/lib" "$RENDER" "$f" "$host"
      [ "$status" -eq 0 ]
      printf '%s\n' "$output" > "$f"
    done
    git init -q "$H/proj"
    git -C "$H/proj" config user.email t@t
    git -C "$H/proj" config user.name t
    git -C "$H/proj" commit -q --allow-empty -m init
    (cd "$H/proj" && RADIN_HOST=$host bash "$H/lib/radin-backlog.sh" add fix "t one" <<<"body")
    run bash -c "cd '$H/proj' && RADIN_HOST=$host bash '$H/lib/radin-prompt.sh' factfind t-one q"
    [ "$status" -eq 0 ]
    prompt=$(printf '%s\n' "$output" | awk -F'\t' '$1 == "prompt" { print $2 }')
    text=$(cat "$prompt")
    if [ "$host" = agents ]; then
      [ "$(printf '%s\n' "$output" | cut -f1)" = prompt ]
      [[ "$text" != *"<!-- host"* ]]
      [[ "$text" != *Monitor* ]]
      [[ "$text" != *Workflow* ]]
      [[ "$text" != *ToolSearch* ]]
    else
      [ "$(printf '%s\n' "$output" | cut -f1)" = "$(printf 'model\neffort\nprompt')" ]
      [[ "$text" == *ToolSearch* ]]
      [[ "$text" == *Monitor* ]]
    fi
  done
}

render_lib() {
  H="$T/$1"
  mkdir -p "$H"
  cp -R "$REPO_ROOT/lib" "$H/lib"
  for f in "$H"/lib/*.md; do
    run env RADIN_LIB_DIR="$H/lib" "$RENDER" "$f" "$2"
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" > "$f"
  done
}

@test "every prompt template drops its model and effort lines on agents" {
  for f in "$REPO_ROOT"/lib/radin-prompt-*.md; do
    run "$RENDER" "$f" agents
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | grep -c '^`\(model\|effort\)')" -eq 0 ]
    [[ "$output" != *RADIN_MODEL_* ]]
    [[ "$output" != *model-low* ]]
    run "$RENDER" "$f" claude
    [ "$(printf '%s\n' "$output" | grep -c '^`model: "')" -eq 1 ]
  done
}

@test "prompt.sh finds its templates under hosts/<host>/lib in the installed layout" {
  render_lib flat claude
  H="$T/inst"
  mkdir -p "$H/lib" "$H/hosts/claude"
  cp "$T"/flat/lib/*.sh "$H/lib/"
  mkdir "$H/hosts/claude/lib"
  mv "$T"/flat/lib/*.md "$H/hosts/claude/lib/"
  git init -q "$H/proj"
  git -C "$H/proj" config user.email t@t
  git -C "$H/proj" config user.name t
  git -C "$H/proj" commit -q --allow-empty -m init
  (cd "$H/proj" && RADIN_HOST=claude bash "$H/lib/radin-backlog.sh" add fix "t one" <<<"body")
  run bash -c "cd '$H/proj' && RADIN_HOST=claude bash '$H/lib/radin-prompt.sh' execution t-one"
  [ "$status" -eq 0 ]
}

@test "a claude lib without a model line still fails" {
  render_lib broken claude
  grep -v '^`model: "' "$T/broken/lib/radin-prompt-factfind.md" > "$T/broken/f.md"
  mv "$T/broken/f.md" "$T/broken/lib/radin-prompt-factfind.md"
  run env -u RADIN_HOST bash "$T/broken/lib/radin-prompt.sh" factfind t-one q
  [ "$status" -eq 1 ]
  [[ "$output" == *"no model line in"* ]]
}

@test "agents with a task marked complexity low still prints only the prompt" {
  render_lib low agents
  git init -q "$T/low/proj"
  git -C "$T/low/proj" config user.email t@t
  git -C "$T/low/proj" config user.name t
  git -C "$T/low/proj" commit -q --allow-empty -m init
  (cd "$T/low/proj" && RADIN_HOST=agents bash "$T/low/lib/radin-backlog.sh" add fix "t one" --complexity low <<<"body")
  run bash -c "cd '$T/low/proj' && RADIN_HOST=agents bash '$T/low/lib/radin-prompt.sh' execution t-one"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | cut -f1)" = prompt ]
}

@test "a skill token renders each host's value" {
  src 'Invoke `@@skill:grilling@@` now, then @@skill:ponytail-review@@.'
  run "$RENDER" "$T/in.md" claude
  [ "$status" -eq 0 ]
  [ "$output" = 'Invoke `/mattpocock-skills:grilling` now, then /ponytail:ponytail-review.' ]
  run "$RENDER" "$T/in.md" agents
  [ "$status" -eq 0 ]
  [ "$output" = 'Invoke `grilling` now, then ponytail-review.' ]
}

@test "an unknown skill name fails with FILE:LINE" {
  src ok 'x @@skill:nope@@'
  run "$RENDER" "$T/in.md" agents
  [ "$status" -eq 1 ]
  [[ "$output" == *"in.md:2: unknown skill name \"nope\""* ]]
}

@test "a malformed skill token fails with FILE:LINE" {
  src '@@skill:Bad Name@@'
  run "$RENDER" "$T/in.md" claude
  [ "$status" -eq 1 ]
  [[ "$output" == *"in.md:1: malformed skill token"* ]]
}

@test "a missing skill-names table fails" {
  src one
  mkdir -p "$T/empty"
  cp "$REPO_ROOT"/lib/forbid-*.txt "$T/empty/"
  RADIN_LIB_DIR="$T/empty" run "$RENDER" "$T/in.md" claude
  [ "$status" -eq 1 ]
  [[ "$output" == *"in.md: no skill-names-claude.txt"* ]]
}

@test "a token in a dropped host block is ignored" {
  src '<!-- host:claude -->' '@@skill:nope@@' '<!-- /host -->' '@@skill:research@@'
  run "$RENDER" "$T/in.md" agents
  [ "$status" -eq 0 ]
  [ "$output" = research ]
}

@test "radin-scope.sh names the host's own ponytail passes" {
  mkdir -p "$T/d"
  run bash "$REPO_ROOT/lib/radin-scope.sh" "$T/d"
  [[ "$output" == *$'passes\t/ponytail:ponytail-audit /ponytail:ponytail-debt'* ]]
  RADIN_HOST=agents run bash "$REPO_ROOT/lib/radin-scope.sh" "$T/d"
  [[ "$output" == *$'passes\tponytail-audit ponytail-debt'* ]]
}

@test "the agents render of radin-batch-recovery.md holds no model or effort token" {
  run "$RENDER" "$REPO_ROOT/lib/radin-batch-recovery.md" agents
  [ "$status" -eq 0 ]
  [[ "$output" != *RADIN_MODEL_* && "$output" != *RADIN_EFFORT_* ]]
  run "$RENDER" "$REPO_ROOT/lib/radin-batch-recovery.md" claude
  [[ "$output" == *'`model: "RADIN_MODEL_REVIEW"`, `effort: "RADIN_EFFORT_REVIEW"`'* ]]
}

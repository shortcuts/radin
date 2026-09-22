#!/usr/bin/env bats
# Exercises lib/radin-prompt.sh: one assembled sub-agent prompt per kind, with
# the guarded blocks a task does not need already dropped. The router reads
# this output instead of radin-execute-prompts.md, so a prompt that ships a
# surviving placeholder or the wrong category row is a failed dispatch.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  CLI="$REPO_ROOT/lib/radin-prompt.sh"
  BACKLOG="$REPO_ROOT/lib/radin-backlog.sh"
  STATE="$REPO_ROOT/lib/radin-state.sh"
  WORK="$(cd "$(mktemp -d)" && pwd -P)"
  # Only the dependency tests need a git repo; the rest never shell out to git.
  mkdir -p "$WORK/proj"
  NS="$WORK/proj/.claude/.radin"
}

teardown() {
  rm -rf "$WORK"
}

cli() {
  (cd "$WORK/proj" && bash "$CLI" "$@")
}

backlog() {
  (cd "$WORK/proj" && bash "$BACKLOG" "$@")
}

@test "an execution prompt drops every block its task has no input for" {
  backlog add chore "tidy up" <<<"Remove the dead flag."
  run cli execution tidy-up
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "$(printf 'model\tRADIN_MODEL_EXECUTION')" ]
  [ "${lines[1]}" = "--- prompt ---" ]
  # No plan, no skills, no deps, no acceptance: their blocks are gone, and the
  # no-plan inverse block is what survives.
  [[ "$output" == *"This task has no plan"* ]]
  [[ "$output" != *" in order: they are the plan"* ]]
  [[ "$output" != *"2a."* ]]
  [[ "$output" != *"2b."* ]]
  [[ "$output" != *"acceptance criteria"* ]]
  # Only the chore row of step 3 survives.
  [[ "$output" == *"/ponytail:ponytail"* ]]
  [[ "$output" != *"surgical-patch"* ]]
  [[ "$output" != *"safe-refactor"* ]]
  [[ "$output" != *"lean-build"* ]]
  # Every placeholder is substituted.
  [[ "$output" != *"TASK_FILE"* ]]
  [[ "$output" != *"NAMESPACE_DIR"* ]]
  [[ "$output" != *"TASK_ID"* ]]
  [[ "$output" == *"$NS/backlog/tasks/tidy-up.md"* ]]
}

@test "each category gets its own step 3 row" {
  backlog add fix "a bug" <<<"It breaks."
  run cli execution a-bug
  [[ "$output" == *"/caveman:surgical-patch"* ]]
  [[ "$output" != *"lean-build"* ]]
  backlog add feat "a feature" <<<"Add it."
  run cli execution a-feature
  [[ "$output" == *"/caveman:lean-build"* ]]
  [[ "$output" != *"surgical-patch"* ]]
  backlog add refactor "a cleanup" <<<"Restructure it."
  run cli execution a-cleanup
  [[ "$output" == *"/caveman:safe-refactor"* ]]
}

@test "a planned task with skills and acceptance keeps those blocks" {
  backlog add feat "big thing" --skill frontend-design <<'EOF'
Build the thing.

**Acceptance:**
- [ ] the button renders
EOF
  printf '# Plan\n' > "$WORK/proj/plan.md"
  backlog add-plan big-thing "$WORK/proj/plan.md"
  run cli execution big-thing
  [ "$status" -eq 0 ]
  [[ "$output" == *"Read $WORK/proj/plan.md in order"* ]]
  [[ "$output" != *"This task has no plan"* ]]
  [[ "$output" == *"2a."* ]]
  [[ "$output" == *"frontend-design"* ]]
  [[ "$output" == *"acceptance criteria"* ]]
  [[ "$output" == *"the button renders"* ]]
  [[ "$output" != *"ACCEPTANCE"* ]]
}

@test "a dependency's commit reaches the prompt without the router carrying it" {
  ( cd "$WORK/proj"
    git init -q .
    git config user.email t@t && git config user.name t
    printf 'a\n' > f.txt && git add -A && git commit -qm init )
  hash="$(cd "$WORK/proj" && git rev-parse HEAD)"
  backlog add fix "first" <<<"Do it first."
  backlog add fix "second" <<<"Do it second."
  backlog set-deps second first
  mkdir -p "$NS/state"
  printf 'first\t1\t\nsecond\t2\tfirst\n' |
    bash "$STATE" steps-init "$NS/state/BACKLOG_STEPS.json"
  bash "$STATE" completed-add "$NS/state/completed.json" first "$hash" "first"
  run cli execution second
  [ "$status" -eq 0 ]
  [[ "$output" == *"2b."* ]]
  [[ "$output" == *"first: $hash"* ]]
  [[ "$output" != *"DEPENDS_ON"* ]]
}

@test "an unresolved dependency yields no execution prompt" {
  backlog add fix "first" <<<"Do it first."
  backlog add fix "second" <<<"Do it second."
  backlog set-deps second first
  mkdir -p "$NS/state"
  printf 'first\t1\t\nsecond\t2\tfirst\n' |
    bash "$STATE" steps-init "$NS/state/BACKLOG_STEPS.json"
  run cli execution second
  [ "$status" -ne 0 ]
  [[ "$output" == *"unresolved"* ]]
}

@test "planning, debug and factfind prompts carry their own model and inputs" {
  backlog add fix "a bug" <<<"It breaks."
  run cli planning a-bug
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "$(printf 'model\tRADIN_MODEL_PLANNING')" ]
  [[ "$output" == *"STATUS: PLANNED"* ]]
  [[ "$output" != *"TASK_ID"* ]]

  run cli debug a-bug "the suite fails on auth_test"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "$(printf 'model\tRADIN_MODEL_DEBUG')" ]
  [[ "$output" == *"Reported failure: the suite fails on auth_test"* ]]
  [[ "$output" == *"Tree: $WORK/proj"* ]]
  [[ "$output" != *"FAILURE"* ]]

  run cli factfind a-bug "does the SDK retry 429s"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "$(printf 'model\tRADIN_MODEL_FACTFIND')" ]
  [[ "$output" == *"does the SDK retry 429s"* ]]
  [[ "$output" != *"QUESTION"* ]]
}

@test "debug and factfind refuse to assemble without their third argument" {
  backlog add fix "a bug" <<<"It breaks."
  run cli debug a-bug
  [ "$status" -ne 0 ]
  run cli factfind a-bug
  [ "$status" -ne 0 ]
  run cli execution no-such-task
  [ "$status" -ne 0 ]
  run cli wat a-bug
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown prompt kind"* ]]
}

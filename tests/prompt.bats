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

state() {
  (cd "$WORK/proj" && bash "$STATE" "$@")
}

# The CLI's two header lines, then the file they point at: what the leaf reads.
assembled() {
  out="$(cli "$@")" || return 1
  printf '%s\n' "$out"
  cat "$(printf '%s\n' "$out" | sed -n 's/^prompt	//p')"
}

@test "an execution prompt drops every block its task has no input for" {
  backlog add chore "tidy up" <<<"Remove the dead flag."
  run assembled execution tidy-up
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "$(printf 'model\tRADIN_MODEL_EXECUTION')" ]
  [ "${lines[1]}" = "$(printf 'prompt\t%s' "$NS/state/prompts/tidy-up-execution.md")" ]
  # No plan, no skills, no deps, no acceptance: their blocks are gone, and the
  # no-plan inverse block is what survives.
  [[ "$output" == *"This task has no plan"* ]]
  [[ "$output" != *" in order: they are the plan"* ]]
  [[ "$output" != *"2a."* ]]
  [[ "$output" != *"2b."* ]]
  [[ "$output" != *"acceptance criteria"* ]]
  [[ "$output" != *"FACTS"* ]]
  [[ "$output" != *"LOCATION"* ]]
  [[ "$output" != *"long form of the evidence"* ]]
  # Only the chore row of step 3 survives.
  [[ "$output" == *"/ponytail:ponytail"* ]]
  [[ "$output" != *"surgical-patch"* ]]
  [[ "$output" != *"safe-refactor"* ]]
  [[ "$output" != *"lean-build"* ]]
  # Every placeholder is substituted.
  [[ "$output" != *"TASK_FILE"* ]]
  [[ "$output" != *"NAMESPACE_DIR"* ]]
  [[ "$output" != *"TASK_ID"* ]]
  [[ "$output" != *"TASK_BODY"* ]]
  [[ "$output" != *"EPIC_CONTEXT"* ]]
  # The body is inlined, so the leaf is never sent its task file's path.
  [[ "$output" == *"Remove the dead flag."* ]]
  [[ "$output" != *"$NS/backlog/tasks/tidy-up.md"* ]]
}

@test "an epic's description reaches its child task's execution prompt" {
  backlog add chore "in an epic" <<<"Do the epic bit."
  backlog epic-add shipping <<<"Every shipping task assumes the queue is drained."
  backlog epic-move in-an-epic shipping
  run assembled execution in-an-epic
  [ "$status" -eq 0 ]
  [[ "$output" == *"Every shipping task assumes the queue is drained."* ]]
  [[ "$output" == *"<epic>"* ]]
  [[ "$output" == *"Do the epic bit."* ]]
  # A flat task gets neither the tag nor its framing sentence.
  backlog add chore "flat one" <<<"Do the flat bit."
  run assembled execution flat-one
  [ "$status" -eq 0 ]
  [[ "$output" != *"<epic>"* ]]
  [[ "$output" != *"Shared context for the epic"* ]]
}

@test "each category gets its own step 3 row" {
  backlog add fix "a bug" <<<"It breaks."
  run assembled execution a-bug
  [[ "$output" == *"/caveman:surgical-patch"* ]]
  [[ "$output" != *"lean-build"* ]]
  backlog add feat "a feature" <<<"Add it."
  run assembled execution a-feature
  [[ "$output" == *"/caveman:lean-build"* ]]
  [[ "$output" != *"surgical-patch"* ]]
  backlog add refactor "a cleanup" <<<"Restructure it."
  run assembled execution a-cleanup
  [[ "$output" == *"/caveman:safe-refactor"* ]]
}

@test "a planned task with skills and acceptance keeps those blocks" {
  backlog add feat "big thing" --skill frontend-design <<<"Build the thing."
  backlog set-meta big-thing acceptance "the button renders"
  printf '# Plan\n' > "$WORK/proj/plan.md"
  backlog add-plan big-thing "$WORK/proj/plan.md"
  run assembled execution big-thing
  [ "$status" -eq 0 ]
  [[ "$output" == *"Read $WORK/proj/plan.md in order"* ]]
  [[ "$output" != *"This task has no plan"* ]]
  [[ "$output" == *"2a."* ]]
  [[ "$output" == *"frontend-design"* ]]
  [[ "$output" == *"acceptance criteria"* ]]
  [[ "$output" == *"the button renders"* ]]
  [[ "$output" != *"ACCEPTANCE"* ]]
}

@test "the entry's facts and location reach the execution prompt" {
  backlog add fix "a bug" <<<"It breaks."
  backlog set-meta a-bug facts "$NS/state/facts/a-bug.md"
  backlog set-meta a-bug location "lib/x.sh:12"
  run assembled execution a-bug
  [ "$status" -eq 0 ]
  [[ "$output" == *"Read $NS/state/facts/a-bug.md as well"* ]]
  [[ "$output" == *"lib/x.sh:12 is the"* ]]
  [[ "$output" != *"FACTS"* ]]
  [[ "$output" != *"LOCATION"* ]]
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
    state steps-init
  printf '{"id":"first","commit":"%s","title":"first"}\n' "$hash" >> "$NS/state/completed.json"
  run assembled execution second
  [ "$status" -eq 0 ]
  [[ "$output" == *"2b."* ]]
  [[ "$output" == *"first: $hash"* ]]
  [[ "$output" != *"DEPENDS_ON"* ]]
}

@test "planning, debug and factfind prompts carry their own model and inputs" {
  backlog add fix "a bug" <<<"It breaks."
  run assembled planning a-bug
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "$(printf 'model\tRADIN_MODEL_PLANNING')" ]
  [[ "$output" == *"STATUS: PLANNED"* ]]
  [[ "$output" != *"TASK_ID"* ]]

  run assembled debug a-bug "the suite fails on auth_test"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "$(printf 'model\tRADIN_MODEL_DEBUG')" ]
  [[ "$output" == *"Reported failure: the suite fails on auth_test"* ]]
  [[ "$output" == *"Tree: $WORK/proj"* ]]
  [[ "$output" != *"FAILURE"* ]]

  run assembled factfind a-bug "does the SDK retry 429s"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "$(printf 'model\tRADIN_MODEL_FACTFIND')" ]
  [[ "$output" == *"does the SDK retry 429s"* ]]
  [[ "$output" != *"QUESTION"* ]]
}

@test "debug and factfind refuse to assemble without their third argument" {
  backlog add fix "a bug" <<<"It breaks."
  run assembled debug a-bug
  [ "$status" -ne 0 ]
  run assembled factfind a-bug
  [ "$status" -ne 0 ]
  run assembled execution no-such-task
  [ "$status" -ne 0 ]
  run assembled wat a-bug
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown prompt kind"* ]]
}

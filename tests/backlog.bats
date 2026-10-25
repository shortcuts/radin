#!/usr/bin/env bats
# Exercises lib/radin-backlog.sh: deterministic backlog operations against
# a JSONL index + one markdown file per task.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  CLI="$REPO_ROOT/lib/radin-backlog.sh"
  WORK="$(cd "$(mktemp -d)" && pwd -P)"
  git init -q "$WORK/proj"
  INDEX="$WORK/proj/.claude/.radin/backlog/index.jsonl"
  TASKS="$WORK/proj/.claude/.radin/backlog/tasks"
}

teardown() {
  rm -rf "$WORK"
}

cli() {
  (cd "$WORK/proj" && bash "$CLI" "$@")
}

# A plan that passes plan-lint. $1 is the path, $2 the Outcome line.
write_plan() {
  mkdir -p "$(dirname "$1")"
  {
    printf '## Outcome\n%s\n' "$2"
    for s in Decisions "Alternatives rejected"; do printf '## %s\nn/a: test\n' "$s"; done
    printf '## Changes\n- `a.txt` - edit\n  You see: a\n'
    for s in "Reach and reuse" "Rubrics triggered" "Modes and states" Order; do printf '## %s\nn/a: test\n' "$s"; done
    printf '## Testing\n- [ ] run it\n- [ ] Live: run it\n'
    for s in Risks "Out of scope"; do printf '## %s\nn/a: test\n' "$s"; done
  } >"$1"
}

@test "add writes meta flags with the entry and rejects a bad one whole" {
  cli add fix base <<<b >/dev/null 2>&1
  id="$(cli add feat t --acceptance "a" --acceptance "b" --planning needed --location x.c:3 --deps base 2>/dev/null <<<body)"
  [ "$id" = t ]
  run cli meta t
  [[ "$output" == *$'acceptance\ta'* ]]
  [[ "$output" == *$'acceptance\tb'* ]]
  [[ "$output" == *$'location\tx.c:3'* ]]
  [[ "$output" == *$'planning\tneeded'* ]]
  run cli list
  [[ "$output" == *"base"* ]]
  run cli add fix bad --deps nope <<<b
  [ "$status" -ne 0 ]
  [ "$(cli count)" -eq 2 ]
}

@test "add creates an index line and a task file" {
  run cli add fix "broken auth" <<<"Auth times out after 5s."
  [ "$status" -eq 0 ]
  [[ "$output" == *"id: broken-auth"* ]]
  [ "$(cli add fix "broken auth" 2>/dev/null <<<"again")" = "broken-auth-2" ]
  run cat "$INDEX"
  [[ "$output" == *'"id":"broken-auth"'* ]]
  [[ "$output" == *'"category":"fix"'* ]]
  [[ "$output" == *'"title":"broken auth"'* ]]
  run cat "$TASKS/broken-auth.md"
  [[ "$output" == *"Auth times out after 5s."* ]]
}

@test "add dedupes ids from identical titles" {
  cli add fix "dup title" <<<"body 1"
  cli add chore "dup title" <<<"body 2"
  [ -f "$TASKS/dup-title.md" ]
  [ -f "$TASKS/dup-title-2.md" ]
}

@test "add rejects unknown category and empty body" {
  run cli add wat "title" <<<"body"
  [ "$status" -ne 0 ]
  run cli add fix "title" <<<""
  [ "$status" -ne 0 ]
}

@test "find falls back to exact title, then case-insensitive substring" {
  cli add feat "Add OAuth support" <<<"body"
  run cli find "Add OAuth support"
  [ "${#lines[@]}" -eq 1 ]
  run cli find "oauth"
  [[ "$output" == *"Add OAuth support"* ]]
}

@test "add-plan puts the pointer on the task's own entry only, never in a body" {
  cli add feat "planned thing" <<<"the body"
  cli add feat "next thing" <<<"other body"
  write_plan "$WORK/proj/.claude/.radin/plans/planned-thing.md" "x"
  run cli add-plan "planned thing" ".claude/.radin/plans/planned-thing.md"
  [ "$status" -eq 0 ]
  run grep -F '"id":"planned-thing"' "$INDEX"
  [[ "$output" == *'"plan":[".claude/.radin/plans/planned-thing.md"]'* ]]
  run grep -F '"id":"next-thing"' "$INDEX"
  [[ "$output" != *'"plan"'* ]]
  # The body keeps the prose and nothing else.
  run cat "$TASKS/planned-thing.md"
  [ "$output" = "the body" ]
}

@test "add-plan refuses a plan that fails plan-lint and records no pointer" {
  cli add feat "bad plan" <<<"body"
  mkdir -p "$WORK/proj/.claude/.radin/plans"
  printf '## Outcome\nonly this\n' >"$WORK/proj/.claude/.radin/plans/bad-plan.md"
  run cli add-plan "bad plan" ".claude/.radin/plans/bad-plan.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing or out of order: ## Decisions"* ]]
  run grep -F '"id":"bad-plan"' "$INDEX"
  [[ "$output" != *'"plan"'* ]]
}

@test "remove deletes the task file and its index line" {
  cli add fix "keep me" <<<"body keep"
  cli add fix "drop me" <<<"body drop"
  run cli remove "drop me"
  [ "$status" -eq 0 ]
  [ ! -f "$TASKS/drop-me.md" ]
  [ -f "$TASKS/keep-me.md" ]
  run cat "$INDEX"
  [[ "$output" != *"drop-me"* ]]
  [[ "$output" == *"keep-me"* ]]
}

@test "list --meta carries each entry's meta lines on its row, joined by RS" {
  cli add feat "rich task" <<<"body"
  cli add fix "bare task" <<<"body"
  cli set-meta "rich task" acceptance "one" "two"
  run cli list --order created --meta
  [ "$status" -eq 0 ]
  [ "${lines[0]##*$'\037'}" = "acceptance"$'\t'"one"$'\036'"acceptance"$'\t'"two" ]
  [ "${lines[1]##*$'\037'}" = "" ]
}

# Epic support will nest a task under tasks/<epic-id>/, so the index's `file`
# field -- not a composed tasks/<id>.md -- is what every verb must follow.
nest_task() {
  cli add feat "nested thing" <<<"body"
  mkdir -p "$TASKS/epic-a"
  mv "$TASKS/nested-thing.md" "$TASKS/epic-a/nested-thing.md"
  printf '{"id":"nested-thing","category":"feat","title":"nested thing","file":"tasks/epic-a/nested-thing.md"}\n' >"$INDEX"
}

@test "append, show, retitle and remove follow a non-default file value" {
  nest_task
  run cli append nested-thing <<<"appended line"
  [ "$status" -eq 0 ]
  run cat "$TASKS/epic-a/nested-thing.md"
  [[ "$output" == *"appended line"* ]]
  run cli show
  [[ "$output" == *"appended line"* ]]
  run cli retitle nested-thing "renamed"
  [ "$status" -eq 0 ]
  run cat "$INDEX"
  [[ "$output" == *'"file":"tasks/epic-a/nested-thing.md"'* ]]
  run cli remove nested-thing
  [ "$status" -eq 0 ]
  [ ! -f "$TASKS/epic-a/nested-thing.md" ]
}

@test "retitle changes the title but never the id or file" {
  cli add fix "old name" <<<"body"
  run cli retitle old-name "new name"
  [ "$status" -eq 0 ]
  run cat "$INDEX"
  [[ "$output" == *'"id":"old-name"'* ]]
  [[ "$output" == *'"title":"new name"'* ]]
  [[ "$output" == *'"file":"tasks/old-name.md"'* ]]
  [ -f "$TASKS/old-name.md" ]
}

@test "add rejects a tab or newline in the title" {
  run cli add feat "$(printf 'a\tb')" <<<"body"
  [ "$status" -ne 0 ]
  run cli add feat "$(printf 'a\nb')" <<<"body"
  [ "$status" -ne 0 ]
  [ ! -f "$INDEX" ]
}

@test "epic-add creates the directory and DESCRIPTION.md, epics and epic-show read it" {
  run cli epic-add auth-overhaul <<<"Shared auth context."
  [ "$status" -eq 0 ]
  run cat "$TASKS/auth-overhaul/DESCRIPTION.md"
  [[ "$output" == *"Shared auth context."* ]]
  run cli epics
  [ "$output" = "auth-overhaul" ]
  run cli epic-show auth-overhaul
  [ "$status" -eq 0 ]
  [[ "$output" == *"Shared auth context."* ]]
}

@test "epic-add rejects a non-slug id and an existing epic" {
  cli epic-add ok <<<"d"
  run cli epic-add ok <<<"d"
  [ "$status" -ne 0 ]
  run cli epic-add "Not A Slug" <<<"d"
  [ "$status" -ne 0 ]
}

@test "epic-move moves a task in and back out, rewriting the file field" {
  cli epic-add auth <<<"ctx"
  cli add feat "drifter" <<<"body"
  run cli epic-move drifter auth
  [ "$status" -eq 0 ]
  [ -f "$TASKS/auth/drifter.md" ]
  run cat "$INDEX"
  [[ "$output" == *'"file":"tasks/auth/drifter.md"'* ]]
  run cli epic-move drifter --none
  [ "$status" -eq 0 ]
  [ -f "$TASKS/drifter.md" ]
  run cat "$INDEX"
  [[ "$output" == *'"file":"tasks/drifter.md"'* ]]
}

@test "remove does not leave an empty epic directory behind" {
  cli epic-add auth <<<"ctx"
  cli add feat "only child" <<<"body"
  cli epic-move only-child auth >/dev/null
  cli remove only-child
  [ ! -d "$TASKS/auth" ]
  run cli epics
  [ -z "$output" ]
}

@test "set-priority sets, changes and clears the priority" {
  cli add feat "ranked" <<<"b"
  run cli set-priority ranked 8
  [ "$status" -eq 0 ]
  [[ "$(cat "$INDEX")" == *'"priority":8'* ]]
  cli set-priority ranked 21
  [[ "$(cat "$INDEX")" == *'"priority":21'* ]]
  run cli set-priority ranked --none
  [ "$status" -eq 0 ]
  [[ "$(cat "$INDEX")" != *'"priority"'* ]]
  run cli set-priority ranked twelve
  [ "$status" -ne 0 ]
}

@test "set-priority takes only the Fibonacci scale, and off-scale stored values still load" {
  cli add feat "ranked" <<<"b"
  run cli set-priority ranked 7
  [ "$status" -ne 0 ]
  [[ "$output" == *"1 2 3 5 8 13 21"* ]]
  [[ "$(cat "$INDEX")" != *'"priority"'* ]]
  # A line written before the scale existed: validation is write-only, so it
  # keeps loading and listing untouched.
  cli set-priority ranked 21
  sed -i.bak 's/"priority":21/"priority":70/' "$INDEX"
  rm -f "$INDEX.bak"
  run cli list
  [ "$status" -eq 0 ]
  [[ "$output" == *"70"* ]]
  run cli find ranked
  [ "$status" -eq 0 ]
  [[ "$output" == *"70"* ]]
}

@test "set-deps sets and clears depends_on" {
  cli add feat "one" <<<"b"
  cli add feat "two" <<<"b"
  cli add feat "three" <<<"b"
  run cli set-deps three one,two
  [ "$status" -eq 0 ]
  [[ "$(cat "$INDEX")" == *'"depends_on":["one","two"]'* ]]
  run cli set-deps three --none
  [ "$status" -eq 0 ]
  [[ "$(cat "$INDEX")" != *'"depends_on"'* ]]
}

@test "set-deps refuses an unknown id, a self-reference and a cycle, writing nothing" {
  cli add feat "a task" <<<"b"
  cli add feat "b task" <<<"b"
  before="$(cat "$INDEX")"
  run cli set-deps a-task ghost
  [ "$status" -ne 0 ]
  [ "$(cat "$INDEX")" = "$before" ]
  run cli set-deps a-task a-task
  [ "$status" -ne 0 ]
  [ "$(cat "$INDEX")" = "$before" ]
  cli set-deps b-task a-task
  before="$(cat "$INDEX")"
  run cli set-deps a-task b-task
  [ "$status" -ne 0 ]
  [ "$(cat "$INDEX")" = "$before" ]
}

@test "set-deps and add --deps resolve titles, and refuse no match or several" {
  cli add fix "Broken Auth" <<<"b"
  cli add feat "three" <<<"b"
  run cli set-deps three "Broken Auth"
  [ "$status" -eq 0 ]
  [[ "$(cat "$INDEX")" == *'"depends_on":["broken-auth"]'* ]]
  run cli add feat "four" --deps "Broken Auth" <<<"b"
  [ "$status" -eq 0 ]
  [[ "$(grep '"id":"four"' "$INDEX")" == *'"depends_on":["broken-auth"]'* ]]
  run cli add feat "five" --deps ghost <<<"b"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no entry matches: ghost"* ]]
  cli add fix "Broken Auth" <<<"b"
  before="$(cat "$INDEX")"
  run cli set-deps three "Broken Auth"
  [ "$status" -ne 0 ]
  [[ "$output" == *"matches 2 entries"* ]]
  [ "$(cat "$INDEX")" = "$before" ]
}

@test "remove prunes the removed id from other entries' depends_on" {
  cli add feat "keeper" <<<"b"
  cli add feat "doomed" <<<"b"
  cli set-deps keeper doomed
  cli remove doomed
  [[ "$(cat "$INDEX")" != *'"depends_on"'* ]]
  run cli find keeper
  [ "$output" = "keeper	feat	keeper	tasks/keeper.md		" ]
}

@test "set-category and epic-move preserve priority and depends_on" {
  cli add feat "anchor" <<<"b"
  cli add feat "mover" <<<"b"
  cli set-priority mover 8 >/dev/null
  cli set-deps mover anchor >/dev/null
  cli epic-add grouped <<<"ctx"
  cli set-category mover fix
  cli epic-move mover grouped
  run cat "$INDEX"
  [[ "$output" == *'{"id":"mover","category":"fix","title":"mover","file":"tasks/grouped/mover.md"'*'"priority":8,"depends_on":["anchor"]}'* ]]
}

@test "a failed index rewrite leaves no .tmp behind and keeps the index intact" {
  cli add feat "keeper" <<<"b"
  cli add feat "doomed" <<<"b"
  before="$(cat "$INDEX")"
  mkdir -p "$WORK/fake"
  printf '#!/bin/sh\nexit 1\n' >"$WORK/fake/mv"
  chmod +x "$WORK/fake/mv"
  run env PATH="$WORK/fake:$PATH" bash -c "cd '$WORK/proj' && bash '$CLI' remove doomed"
  [ "$status" -ne 0 ]
  [ ! -e "$INDEX.tmp" ]
  [ "$(cat "$INDEX")" = "$before" ]
}

@test "list --order created gives index order, the default stays priority" {
  cli add feat "added first" <<<"b"
  cli set-priority added-first 1 >/dev/null
  cli add feat "added second" <<<"b"
  cli set-priority added-second 13 >/dev/null
  run cli list
  [ "$(printf '%s\n' "$output" | cut -d$'\037' -f1 | tr '\n' ' ')" = "added-second added-first " ]
  run cli list --order priority
  [ "$(printf '%s\n' "$output" | cut -d$'\037' -f1 | tr '\n' ' ')" = "added-second added-first " ]
  run cli list --order created
  [ "$(printf '%s\n' "$output" | cut -d$'\037' -f1 | tr '\n' ' ')" = "added-first added-second " ]
  run cli list --order bogus
  [ "$status" -ne 0 ]
  [[ "$output" == *"list "* ]]
}

@test "a title carrying a JSON-looking key and a backslash round-trips" {
  local evil='evil "file":"tasks/hack.md" and back\slash'
  cli add chore "$evil" <<<"escaping fixture"
  cli add feat "innocent" <<<"b"
  run cli list
  [[ "$output" == *"$evil"* ]]
  # The real file field, not the one smuggled into the title.
  [[ "$output" == *"tasks/evil-file-tasks-hack-md-and-back-slash.md"* ]]
  run cli find "$evil"
  [ "$status" -eq 0 ]
  [[ "$output" == *"$evil"* ]]
  run cli find 'back\slash'
  [ "$status" -eq 0 ]
  [[ "$output" == *"$evil"* ]]
  [[ "$output" != *"innocent"* ]]
}

# --- order -------------------------------------------------------------------

# Priorities descending, unset last, ties in index order: `order`'s baseline is
# the same contract `list` defaults to.
# Written straight to the index rather than through `add`/`set-priority`: 11
# tests share this fixture, and 8 forks each is most of what `make test` would
# pay for them. Those two verbs have their own tests above.
prioritized_backlog() {
  mkdir -p "$TASKS"
  cat >"$INDEX" <<'IDX'
{"id":"high","category":"feat","title":"high","file":"tasks/high.md","priority":21}
{"id":"mid-a","category":"feat","title":"mid a","file":"tasks/mid-a.md","priority":5}
{"id":"mid-b","category":"feat","title":"mid b","file":"tasks/mid-b.md","priority":5}
{"id":"low","category":"fix","title":"low","file":"tasks/low.md","priority":1}
IDX
}

@test "order moves a dependency up and leaves every other position alone" {
  prioritized_backlog
  cli set-deps mid-a low
  run cli order --report
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "1. high (id: high)" ]
  [ "${lines[1]}" = "2. low (id: low)" ]
  [ "${lines[2]}" = "3. mid a (id: mid-a)" ]
  [ "${lines[3]}" = "4. mid b (id: mid-b)" ]
  [ "${lines[4]}" = "dependency override: low moved above mid-a (priority 5)" ]
}

@test "order --report prints no override line when no edge is violated" {
  prioritized_backlog
  cli set-deps low high
  run cli order --report
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 4 ]
  [[ "$output" != *"dependency override"* ]]
}

@test "scope returns an epic's tasks plus their outside dependencies, and exits 1 on no match, 2 on several" {
  mkdir -p "$TASKS/ep"
  cat >"$INDEX" <<'IDX'
{"id":"out","category":"feat","title":"outside dep","file":"tasks/out.md"}
{"id":"a","category":"feat","title":"alpha thing","file":"tasks/ep/a.md","depends_on":["out"]}
{"id":"b","category":"feat","title":"beta thing","file":"tasks/ep/b.md"}
{"id":"c","category":"feat","title":"gamma thing","file":"tasks/c.md"}
IDX
  run cli scope ep
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "ids"$'\t'"out,a,b" ]
  [ "${lines[1]}" = "dependencies"$'\t'"out" ]
  run cli scope c
  [ "$status" -eq 0 ]
  [ "$output" = "ids"$'\t'"c" ]
  run cli scope nothing-here
  [ "$status" -eq 1 ]
  run cli scope thing
  [ "$status" -eq 2 ]
  [[ "$output" == *"candidate"$'\t'"a"* ]]
}

@test "order --first and --only derive the deferred set; two selectors are refused" {
  prioritized_backlog
  run cli order --steps --first
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "high"$'\t'"1"$'\t\t'"pending" ]
  [ "${lines[1]}" = "mid-a"$'\t'"2"$'\t\t'"deferred" ]
  [ "${lines[3]}" = "low"$'\t'"4"$'\t\t'"deferred" ]
  run cli order --steps --only mid-b,low
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "high"$'\t'"1"$'\t\t'"deferred" ]
  [ "${lines[2]}" = "mid-b"$'\t'"3"$'\t\t'"pending" ]
  [ "${lines[3]}" = "low"$'\t'"4"$'\t\t'"pending" ]
  run cli order --steps --only nope
  [ "$status" -ne 0 ]
  run cli order --steps --only 4,mid-a
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "high"$'\t'"1"$'\t\t'"deferred" ]
  [ "${lines[1]}" = "mid-a"$'\t'"2"$'\t\t'"pending" ]
  [ "${lines[3]}" = "low"$'\t'"4"$'\t\t'"pending" ]
  run cli order --steps --only 9
  [ "$status" -eq 1 ]
  run cli order --steps --only "mid b"
  [ "${lines[2]}" = "mid-b"$'\t'"3"$'\t\t'"pending" ]
  run cli order --steps --only mid
  [ "$status" -eq 2 ]
  [[ "$output" == *"candidate"$'\t'"mid-a"* ]]
  run cli order --steps --only low --first
  [ "$status" -ne 0 ]
}

@test "list --planned appends P for planned tasks and empty for unplanned" {
  cli add feat "planned one" <<<"body"
  cli add feat "unplanned one" <<<"body"
  write_plan "$WORK/proj/.claude/.radin/plans/planned-one.md" "x"
  cli add-plan planned-one ".claude/.radin/plans/planned-one.md" >/dev/null
  run cli list --planned
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  # planned-one has a P in the last field
  [[ "${lines[0]}" == *$'\037'"P" ]]
  # unplanned-one has an empty last field
  [[ "${lines[1]}" == *$'\037'"" ]]
}

# --- field -------------------------------------------------------------------

# --- duplicates --------------------------------------------------------------

# --- plan-target -------------------------------------------------------------

# --- files -------------------------------------------------------------------

mkplan() {
  printf '%s\n' "## Outcome" "- \`not/a/change.sh\` — outcome bullet" "" "## Changes" "" \
    "- \`$2\` — first" "- \`$3\` — second" "  - \`nested/x\` — ignored" "" \
    '```' "- \`in/fence.sh\` — snippet" '```' "" "## Order" "- \`order/item\` — x" >"$1"
}

# --- add-plan sidecar ---------------------------------------------------------

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

@test "env --export prints source-able export lines" {
  cd "$WORK/proj"
  run bash "$CLI" env --export
  [ "$status" -eq 0 ]
  [[ "$output" == *"export REPO_ROOT="* ]]
  [[ "$output" == *"export BACKLOG_INDEX="* ]]
}

@test "add creates an index line and a task file" {
  run cli add fix "broken auth" <<<"Auth times out after 5s."
  [ "$status" -eq 0 ]
  [[ "$output" == *"id: broken-auth"* ]]
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

@test "list prints id, category, title, file, priority and depends-on for every task" {
  cli add feat "f thing" <<<"body f"
  cli add fix "b thing" <<<"body b"
  run cli list
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [[ "${lines[0]}" == "f-thing"$'\t'"feat"$'\t'"f thing"$'\t'"tasks/f-thing.md"$'\t'$'\t' ]]
  [[ "${lines[1]}" == "b-thing"$'\t'"fix"$'\t'"b thing"$'\t'"tasks/b-thing.md"$'\t'$'\t' ]]
}

@test "find matches by exact id first" {
  cli add fix "auth bug" <<<"body a"
  run cli find "auth-bug"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "${lines[0]}" == "auth-bug"$'\t'"fix"$'\t'"auth bug"$'\t'"tasks/auth-bug.md"$'\t'$'\t' ]]
}

@test "find falls back to exact title, then case-insensitive substring" {
  cli add feat "Add OAuth support" <<<"body"
  run cli find "Add OAuth support"
  [ "${#lines[@]}" -eq 1 ]
  run cli find "oauth"
  [[ "$output" == *"Add OAuth support"* ]]
}

@test "find fails when nothing matches" {
  cli add feat "something" <<<"body"
  run cli find "nope"
  [ "$status" -ne 0 ]
}

@test "add-plan appends the pointer to the task's own file only" {
  cli add feat "planned thing" <<<"the body"
  cli add feat "next thing" <<<"other body"
  run cli add-plan "planned thing" ".claude/.radin/plans/planned-thing.md"
  [ "$status" -eq 0 ]
  run cat "$TASKS/planned-thing.md"
  [[ "$output" == *"the body"* ]]
  [[ "$output" == *"**Plan:** .claude/.radin/plans/planned-thing.md"* ]]
  run cat "$TASKS/next-thing.md"
  [[ "$output" != *"**Plan:**"* ]]
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

@test "remove refuses ambiguous titles" {
  cli add fix "dup title" <<<"body 1"
  cli add chore "dup title" <<<"body 2"
  run cli remove "dup"
  [ "$status" -ne 0 ]
  [[ "$output" == *"2 entries"* ]]
}

@test "show renders grouped-by-category markdown from the index and task files" {
  cli add feat "f thing" <<<"body f"
  cli add fix "b thing" <<<"body b"
  run cli show
  [[ "$output" == *"# Backlog"* ]]
  [[ "$output" == *"## feat"* ]]
  [[ "$output" == *"### f thing"* ]]
  [[ "$output" == *"body f"* ]]
  [[ "$output" == *"## fix"* ]]
  [[ "$output" == *"### b thing"* ]]
}

@test "show <category> prints only that section" {
  cli add feat "f thing" <<<"body f"
  cli add fix "b thing" <<<"body b"
  run cli show fix
  [[ "$output" == *"## fix"* ]]
  [[ "$output" == *"b thing"* ]]
  [[ "$output" != *"f thing"* ]]
}

@test "reconcile drops entries whose id is in completed.json, keeps the rest" {
  cli add fix "done task" <<<"body done"
  cli add feat "still open" <<<"body open"
  mkdir -p "$WORK/proj/.claude/.radin/state"
  printf '{"id":"done-task","commit":"abc123"}\n' > "$WORK/proj/.claude/.radin/state/completed.json"
  run cli reconcile "$WORK/proj/.claude/.radin/state/completed.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"done-task"* ]]
  [ ! -f "$TASKS/done-task.md" ]
  [ -f "$TASKS/still-open.md" ]
  run cat "$INDEX"
  [[ "$output" != *"done-task"* ]]
  [[ "$output" == *"still-open"* ]]
}

@test "reconcile is a no-op when completed.json is absent or lists nothing in the backlog" {
  cli add feat "keep me" <<<"body"
  run cli reconcile "$WORK/proj/.claude/.radin/state/completed.json"
  [ "$status" -eq 0 ]
  [ -f "$TASKS/keep-me.md" ]
  mkdir -p "$WORK/proj/.claude/.radin/state"
  printf '{"id":"never-added","commit":"x"}\n' > "$WORK/proj/.claude/.radin/state/completed.json"
  run cli reconcile "$WORK/proj/.claude/.radin/state/completed.json"
  [ "$status" -eq 0 ]
  [ -f "$TASKS/keep-me.md" ]
}

@test "count prints the entry count, 0 without an index" {
  run cli count
  [ "$output" = "0" ]
  cli add feat "one" <<<"body"
  cli add fix "two" <<<"body"
  run cli count
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]
}

@test "add --skill appends a canonical skill line after the body" {
  run cli add feat "styled thing" --skill /frontend-design <<<"the body"
  [ "$status" -eq 0 ]
  run cat "$TASKS/styled-thing.md"
  [[ "${lines[0]}" == "the body" ]]
  [[ "${lines[1]}" == "**Skill:** Invoke /frontend-design to tackle this task." ]]
}

@test "add rejects an unknown option" {
  run cli add feat "thing" --wat x <<<"body"
  [ "$status" -ne 0 ]
}

@test "meta prints plan and skill lines, nothing for a bare task" {
  cli add feat "rich task" --skill /frontend-design <<<"body"
  cli add fix "bare task" <<<"body"
  cli add-plan "rich task" ".claude/.radin/plans/rich-task.md"
  run cli meta "rich task"
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "skill"$'\t'"Invoke /frontend-design to tackle this task." ]]
  [[ "${lines[1]}" == "plan"$'\t'".claude/.radin/plans/rich-task.md" ]]
  run cli meta "bare task"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "meta prints one acceptance line per criterion" {
  cli add feat "no criteria" <<'EOF'
Body prose.
- a bullet that is not under an Acceptance label

**Priority:** 5.
EOF
  run cli meta "no criteria"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  cli add feat "one criterion" <<'EOF'
Body prose.

**Acceptance:**
- the parser prints exactly one line
EOF
  run cli meta "one criterion"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "${lines[0]}" == "acceptance"$'\t'"the parser prints exactly one line" ]]

  cli add feat "several criteria" <<'EOF'
Body prose.

**Acceptance:**
- plain bullet
- [ ] unticked checkbox
- [x] ticked checkbox
  - indented sub-bullet ends the list
- not collected, the list already ended

**Priority:** 10. **Depends on:** nothing.
EOF
  run cli meta "several criteria"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 3 ]
  [[ "${lines[0]}" == "acceptance"$'\t'"plain bullet" ]]
  [[ "${lines[1]}" == "acceptance"$'\t'"unticked checkbox" ]]
  [[ "${lines[2]}" == "acceptance"$'\t'"ticked checkbox" ]]

  cli add feat "criteria then plan" <<'EOF'
Body prose.

**Acceptance:**
- one thing

**Priority:** 3.
EOF
  cli add-plan "criteria then plan" ".claude/.radin/plans/criteria-then-plan.md"
  run cli meta "criteria then plan"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [[ "${lines[0]}" == "acceptance"$'\t'"one thing" ]]
  [[ "${lines[1]}" == "plan"$'\t'".claude/.radin/plans/criteria-then-plan.md" ]]
}

@test "append adds stdin text to the task's file only" {
  cli add feat "target" <<<"original body"
  cli add feat "other" <<<"other body"
  run cli append target <<<"**Decision:** keep both."
  [ "$status" -eq 0 ]
  run cat "$TASKS/target.md"
  [[ "$output" == *"original body"* ]]
  [[ "$output" == *"**Decision:** keep both."* ]]
  run cat "$TASKS/other.md"
  [[ "$output" != *"Decision"* ]]
}

@test "append refuses an empty body" {
  cli add feat "target" <<<"body"
  run cli append target <<<""
  [ "$status" -ne 0 ]
}

@test "works outside a git repo (PWD fallback)" {
  mkdir -p "$WORK/plain"
  run bash -c "cd '$WORK/plain' && bash '$CLI' add chore 'note' <<<'a note'"
  [ "$status" -eq 0 ]
  [ -s "$WORK/plain/.claude/.radin/backlog/index.jsonl" ]
  [ -s "$WORK/plain/.claude/.radin/backlog/tasks/note.md" ]
}

@test "path prints the task file's absolute path" {
  cli add feat "pathy thing" <<<"body"
  run cli path pathy-thing
  [ "$status" -eq 0 ]
  [ "$output" = "$TASKS/pathy-thing.md" ]
}

# Epic support will nest a task under tasks/<epic-id>/, so the index's `file`
# field -- not a composed tasks/<id>.md -- is what every verb must follow.
nest_task() {
  cli add feat "nested thing" <<<"body"
  mkdir -p "$TASKS/epic-a"
  mv "$TASKS/nested-thing.md" "$TASKS/epic-a/nested-thing.md"
  printf '{"id":"nested-thing","category":"feat","title":"nested thing","file":"tasks/epic-a/nested-thing.md"}\n' >"$INDEX"
}

@test "path follows a non-default file value" {
  nest_task
  run cli path nested-thing
  [ "$status" -eq 0 ]
  [ "$output" = "$TASKS/epic-a/nested-thing.md" ]
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

@test "set-category moves a task and keeps its id, title and body" {
  cli add feat "movable" <<<"body text"
  run cli set-category movable chore
  [ "$status" -eq 0 ]
  run cat "$INDEX"
  [[ "$output" == *'"id":"movable"'* ]]
  [[ "$output" == *'"category":"chore"'* ]]
  [[ "$output" == *'"title":"movable"'* ]]
  run cat "$TASKS/movable.md"
  [[ "$output" == *"body text"* ]]
}

@test "set-category rejects an unknown category" {
  cli add feat "movable" <<<"body"
  run cli set-category movable wat
  [ "$status" -ne 0 ]
  run cat "$INDEX"
  [[ "$output" == *'"category":"feat"'* ]]
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

@test "retitle escapes quotes in the new title" {
  cli add fix "quotable" <<<"body"
  cli retitle quotable 'say "hi"'
  run cli find quotable
  [ "$status" -eq 0 ]
  [[ "$output" == *'say "hi"'* ]]
}

@test "set-category leaves every other entry untouched" {
  cli add feat "first" <<<"b1"
  cli add fix "second" <<<"b2"
  cli set-category first chore
  run cli list
  [[ "$output" == *"second"* ]]
  run grep -c . "$INDEX"
  [ "$output" = "2" ]
}

@test "add rejects a tab or newline in the title" {
  run cli add feat "$(printf 'a\tb')" <<<"body"
  [ "$status" -ne 0 ]
  run cli add feat "$(printf 'a\nb')" <<<"body"
  [ "$status" -ne 0 ]
  [ ! -f "$INDEX" ]
}

@test "retitle rejects a tab or newline in the new title" {
  cli add fix "keepme" <<<"body"
  run cli retitle keepme "$(printf 'a\tb')"
  [ "$status" -ne 0 ]
  run cli retitle keepme "$(printf 'a\nb')"
  [ "$status" -ne 0 ]
  run cat "$INDEX"
  [[ "$output" == *'"title":"keepme"'* ]]
}

@test "path and add-plan follow the index line's file field, not the TSV span" {
  mkdir -p "$TASKS"
  printf '{"id":"tabbed","category":"fix","title":"a\tb","file":"tasks/tabbed.md"}\n' >"$INDEX"
  printf 'body\n' >"$TASKS/tabbed.md"
  run cli path tabbed
  [ "$status" -eq 0 ]
  [ "$output" = "$TASKS/tabbed.md" ]
  cli add-plan tabbed "/tmp/p.md"
  run cat "$TASKS/tabbed.md"
  [[ "$output" == *"**Plan:** /tmp/p.md"* ]]
}

@test "epic-add creates the directory and DESCRIPTION.md, epics lists it" {
  run cli epic-add auth-overhaul <<<"Shared auth context."
  [ "$status" -eq 0 ]
  run cat "$TASKS/auth-overhaul/DESCRIPTION.md"
  [[ "$output" == *"Shared auth context."* ]]
  run cli epics
  [ "$output" = "auth-overhaul" ]
}

@test "epic-show prints the epic description" {
  cli epic-add auth-overhaul <<<"Shared auth context."
  run cli epic-show auth-overhaul
  [ "$status" -eq 0 ]
  [[ "$output" == *"Shared auth context."* ]]
}

@test "epic-show is silent for an empty description" {
  printf '' | cli epic-add bare
  run cli epic-show bare
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "epic-show rejects an unknown epic" {
  run cli epic-show ghost
  [ "$status" -eq 1 ]
  [[ "$output" == *"no such epic"* ]]
}

@test "planned lists only tasks with a plan pointer" {
  cli add feat "with plan" <<<"b1"
  cli add feat "without plan" <<<"b2"
  cli add-plan with-plan "plans/with-plan.md"
  run cli planned
  [ "$status" -eq 0 ]
  [ "$output" = "with-plan" ]
}

@test "planned prints nothing when no task is planned" {
  cli add feat "no plan" <<<"b"
  run cli planned
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "epic-add rejects a non-slug id and an existing epic" {
  cli epic-add ok <<<"d"
  run cli epic-add ok <<<"d"
  [ "$status" -ne 0 ]
  run cli epic-add "Not A Slug" <<<"d"
  [ "$status" -ne 0 ]
}

@test "add --epic nests the task file and path resolves it" {
  cli epic-add auth <<<"ctx"
  run cli add feat "login form" --epic auth <<<"body"
  [ "$status" -eq 0 ]
  run cat "$INDEX"
  [[ "$output" == *'"file":"tasks/auth/login-form.md"'* ]]
  [ -f "$TASKS/auth/login-form.md" ]
  run cli path login-form
  [ "$output" = "$TASKS/auth/login-form.md" ]
}

@test "add --epic rejects an unknown epic" {
  run cli add feat "nope" --epic ghost <<<"body"
  [ "$status" -ne 0 ]
}

@test "add dedupes an id against a task inside another epic" {
  cli epic-add one <<<"ctx"
  cli epic-add two <<<"ctx"
  cli add feat "same title" --epic one <<<"b1"
  cli add fix "same title" --epic two <<<"b2"
  [ -f "$TASKS/one/same-title.md" ]
  [ -f "$TASKS/two/same-title-2.md" ]
}

@test "list output has no epic row" {
  cli epic-add auth <<<"ctx"
  cli add feat "child" --epic auth <<<"body"
  run cli list
  [ "$(printf '%s\n' "$output" | grep -c .)" = "1" ]
  [[ "$output" != *"auth"$'\t'* ]]
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

@test "epic-remove refuses a non-empty epic and deletes nothing" {
  cli epic-add auth <<<"ctx"
  cli add feat "child" --epic auth <<<"body"
  run cli epic-remove auth
  [ "$status" -ne 0 ]
  [ -f "$TASKS/auth/child.md" ]
  [ -f "$TASKS/auth/DESCRIPTION.md" ]
}

@test "epic-remove deletes an epic with no child tasks" {
  cli epic-add auth <<<"ctx"
  run cli epic-remove auth
  [ "$status" -eq 0 ]
  [ ! -d "$TASKS/auth" ]
}

@test "remove does not leave an empty epic directory behind" {
  cli epic-add auth <<<"ctx"
  cli add feat "only child" --epic auth <<<"body"
  cli remove only-child
  [ ! -d "$TASKS/auth" ]
  run cli epics
  [ -z "$output" ]
}

@test "show prints an epic's description once above its children" {
  cli epic-add auth <<<"Shared auth context."
  cli add feat "login form" --epic auth <<<"child body"
  cli add feat "flat one" <<<"flat body"
  run cli show
  [ "$status" -eq 0 ]
  [[ "$output" == *"### epic: auth"* ]]
  [[ "$output" == *"Shared auth context."* ]]
  [[ "$output" == *"#### login form"* ]]
  [[ "$output" == *"### flat one"* ]]
  [ "$(printf '%s\n' "$output" | grep -c 'Shared auth context.')" = "1" ]
}

@test "add --priority and --depends-on round-trip through list" {
  cli add feat "first" <<<"b1"
  run cli add fix "second" --priority 70 --depends-on first <<<"b2"
  [ "$status" -eq 0 ]
  run cat "$INDEX"
  [[ "$output" == *'"priority":70'* ]]
  [[ "$output" == *'"depends_on":["first"]'* ]]
  run cli find second
  [ "$output" = "second	fix	second	tasks/second.md	70	first" ]
}

@test "add rejects a non-integer priority and an unknown dependency" {
  run cli add feat "bad prio" --priority high <<<"b"
  [ "$status" -ne 0 ]
  run cli add feat "bad dep" --depends-on ghost <<<"b"
  [ "$status" -ne 0 ]
  [ ! -f "$TASKS/bad-dep.md" ]
  [ ! -s "$INDEX" ]
}

@test "set-priority sets, changes and clears the priority" {
  cli add feat "ranked" <<<"b"
  run cli set-priority ranked 40
  [ "$status" -eq 0 ]
  [[ "$(cat "$INDEX")" == *'"priority":40'* ]]
  cli set-priority ranked 90
  [[ "$(cat "$INDEX")" == *'"priority":90'* ]]
  run cli set-priority ranked --none
  [ "$status" -eq 0 ]
  [[ "$(cat "$INDEX")" != *'"priority"'* ]]
  run cli set-priority ranked twelve
  [ "$status" -ne 0 ]
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

@test "remove prunes the removed id from other entries' depends_on" {
  cli add feat "keeper" <<<"b"
  cli add feat "doomed" <<<"b"
  cli set-deps keeper doomed
  cli remove doomed
  [[ "$(cat "$INDEX")" != *'"depends_on"'* ]]
  run cli find keeper
  [ "$output" = "keeper	feat	keeper	tasks/keeper.md		" ]
}

@test "remove keeps the other dependencies of a pruned entry" {
  cli add feat "dep one" <<<"b"
  cli add feat "dep two" <<<"b"
  cli add feat "needy" <<<"b"
  cli set-deps needy dep-one,dep-two
  cli remove dep-one
  [[ "$(cat "$INDEX")" == *'"depends_on":["dep-two"]'* ]]
}

@test "remove prunes every dependent in one rewrite and keeps their other keys" {
  cli add feat "doomed" <<<"b"
  cli add feat "first" --priority 70 --depends-on doomed <<<"b"
  cli add feat "second" --priority 20 --depends-on doomed <<<"b"
  cli remove doomed
  run cat "$INDEX"
  [[ "$output" == *'{"id":"first","category":"feat","title":"first","file":"tasks/first.md","priority":70}'* ]]
  [[ "$output" == *'{"id":"second","category":"feat","title":"second","file":"tasks/second.md","priority":20}'* ]]
}

@test "list orders by priority descending with unset entries last" {
  cli add feat "low" --priority 10 <<<"b"
  cli add feat "none at all" <<<"b"
  cli add feat "high" --priority 90 <<<"b"
  cli add feat "mid" --priority 50 <<<"b"
  run cli list
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | cut -f1 | tr '\n' ' ')" = "high mid low none-at-all " ]
}

@test "an entry written before priority existed still parses and round-trips" {
  cli add feat "legacy" <<<"b"
  printf '{"id":"old","category":"fix","title":"old one","file":"tasks/old.md"}\n' >>"$INDEX"
  printf 'old body\n' >"$TASKS/old.md"
  run cli find old
  [ "$output" = "old	fix	old one	tasks/old.md		" ]
  cli retitle old "renamed old"
  run cat "$INDEX"
  [[ "$output" == *'{"id":"old","category":"fix","title":"renamed old","file":"tasks/old.md"}'* ]]
  [[ "$output" != *'"priority"'* ]]
}

@test "set-category and epic-move preserve priority and depends_on" {
  cli add feat "anchor" <<<"b"
  cli add feat "mover" --priority 60 --depends-on anchor <<<"b"
  cli epic-add grouped <<<"ctx"
  cli set-category mover fix
  cli epic-move mover grouped
  run cat "$INDEX"
  [[ "$output" == *'{"id":"mover","category":"fix","title":"mover","file":"tasks/grouped/mover.md","priority":60,"depends_on":["anchor"]}'* ]]
}

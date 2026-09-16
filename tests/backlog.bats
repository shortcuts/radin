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
  [[ "${lines[0]}" == "f-thing"$'\037'"feat"$'\037'"f thing"$'\037'"tasks/f-thing.md"$'\037'$'\037' ]]
  [[ "${lines[1]}" == "b-thing"$'\037'"fix"$'\037'"b thing"$'\037'"tasks/b-thing.md"$'\037'$'\037' ]]
}


@test "find falls back to exact title, then case-insensitive substring" {
  cli add feat "Add OAuth support" <<<"body"
  run cli find "Add OAuth support"
  [ "${#lines[@]}" -eq 1 ]
  run cli find "oauth"
  [[ "$output" == *"Add OAuth support"* ]]
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



@test "add --skill appends a canonical skill line after the body" {
  run cli add feat "styled thing" --skill /frontend-design <<<"the body"
  [ "$status" -eq 0 ]
  run cat "$TASKS/styled-thing.md"
  [[ "${lines[0]}" == "the body" ]]
  [[ "${lines[1]}" == "**Skill:** Invoke /frontend-design to tackle this task." ]]
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


@test "planned lists only tasks with a plan pointer" {
  cli add feat "with plan" <<<"b1"
  cli add feat "without plan" <<<"b2"
  cli add-plan with-plan "plans/with-plan.md"
  run cli planned
  [ "$status" -eq 0 ]
  [ "$output" = "with-plan" ]
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



@test "show prints flat tasks first, then each epic group in name order" {
  cli epic-add beta <<<"Beta context."
  cli epic-add alpha </dev/null
  cli add feat "flat one" <<<"flat body"
  cli add feat "beta child" --epic beta <<<"beta body"
  cli add fix "alpha child" --epic alpha <<<"alpha body"
  cli add feat "flat two" <<<"flat two body"
  cli add feat "alpha extra" --epic alpha <<<"alpha extra body"
  run cli show
  [ "$status" -eq 0 ]
  [ "$output" = "$(cat <<'EOF'
# Backlog

## feat

### flat one
flat body

### flat two
flat two body

### epic: alpha

#### alpha extra
alpha extra body

### epic: beta
Beta context.

#### beta child
beta body

## fix

### epic: alpha

#### alpha child
alpha body
EOF
  )" ]
}

@test "add --priority and --depends-on round-trip through list" {
  cli add feat "first" <<<"b1"
  run cli add fix "second" --priority 13 --depends-on first <<<"b2"
  [ "$status" -eq 0 ]
  run cat "$INDEX"
  [[ "$output" == *'"priority":13'* ]]
  [[ "$output" == *'"depends_on":["first"]'* ]]
  run cli find second
  [ "$output" = "second	fix	second	tasks/second.md	13	first" ]
}

@test "add rejects an off-scale priority and an unknown dependency" {
  run cli add feat "bad prio" --priority high <<<"b"
  [ "$status" -ne 0 ]
  run cli add feat "x" --priority 4 <<<"b"
  [ "$status" -ne 0 ]
  run cli add feat "bad dep" --depends-on ghost <<<"b"
  [ "$status" -ne 0 ]
  [ ! -f "$TASKS/bad-dep.md" ]
  [ ! -s "$INDEX" ]
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


@test "remove prunes the removed id from other entries' depends_on" {
  cli add feat "keeper" <<<"b"
  cli add feat "doomed" <<<"b"
  cli set-deps keeper doomed
  cli remove doomed
  [[ "$(cat "$INDEX")" != *'"depends_on"'* ]]
  run cli find keeper
  [ "$output" = "keeper	feat	keeper	tasks/keeper.md		" ]
}



@test "list orders by priority descending with unset entries last" {
  cli add feat "low" --priority 3 <<<"b"
  cli add feat "none at all" <<<"b"
  cli add feat "high" --priority 21 <<<"b"
  cli add feat "mid" --priority 8 <<<"b"
  run cli list
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | cut -d$'\037' -f1 | tr '\n' ' ')" = "high mid low none-at-all " ]
}


@test "set-category and epic-move preserve priority and depends_on" {
  cli add feat "anchor" <<<"b"
  cli add feat "mover" --priority 8 --depends-on anchor <<<"b"
  cli epic-add grouped <<<"ctx"
  cli set-category mover fix
  cli epic-move mover grouped
  run cat "$INDEX"
  [[ "$output" == *'{"id":"mover","category":"fix","title":"mover","file":"tasks/grouped/mover.md","priority":8,"depends_on":["anchor"]}'* ]]
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

@test "help exits 0 and documents every dispatcher command" {
  run cli help
  [ "$status" -eq 0 ]
  # Derived from the script, not a second hand-maintained list: a new `case`
  # label with no header line is exactly the drift this guards against.
  local label
  while IFS= read -r label; do
    label="${label%)}"
    [[ "$output" == *"  $label "* ]] || {
      echo "help does not document: $label"
      false
    }
  done < <(grep -oE '^[a-z][a-z-]*\)$' "$CLI")
}



@test "list --category filters and rejects an unknown category" {
  cli add feat "a feat" <<<"b1"
  cli add fix "a fix" <<<"b2"
  run cli list --category fix
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c .)" -eq 1 ]
  [[ "$output" == *"a fix"* ]]
  run cli list --category bogus
  [ "$status" -ne 0 ]
  [[ "$output" == *"list "* ]]
}

@test "list --priority-min and --priority-max bound and drop unset priorities" {
  cli add feat "lowest" --priority 1 <<<"b"
  cli add feat "middle" --priority 5 <<<"b"
  cli add feat "highest" --priority 13 <<<"b"
  cli add feat "unset one" <<<"b"
  run cli list --priority-min 5
  [ "$(printf '%s\n' "$output" | cut -d$'\037' -f1 | tr '\n' ' ')" = "highest middle " ]
  run cli list --priority-max 5
  [ "$(printf '%s\n' "$output" | cut -d$'\037' -f1 | tr '\n' ' ')" = "middle lowest " ]
  run cli list --priority-min notanint
  [ "$status" -ne 0 ]
}

@test "list --order created gives index order, the default stays priority" {
  cli add feat "added first" --priority 1 <<<"b"
  cli add feat "added second" --priority 13 <<<"b"
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

@test "list --epic keeps only that epic's children and rejects an unknown epic" {
  cli epic-add shipping <<<"epic ctx"
  cli add feat "inside" --epic shipping <<<"b"
  cli add feat "outside" <<<"b"
  run cli list --epic shipping
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c .)" -eq 1 ]
  [[ "$output" == *"inside"* ]]
  run cli list --epic nosuchepic
  [ "$status" -ne 0 ]
}



@test "a title carrying a JSON-looking key and a backslash round-trips" {
  local evil='evil "file":"tasks/hack.md" and back\slash'
  cli add chore "$evil" <<<"escaping fixture"
  cli add feat "innocent" <<<"b"
  run cli list
  [[ "$output" == *"$evil"* ]]
  # The real file field, not the one smuggled into the title.
  [[ "$output" == *"tasks/evil-file-tasks-hack-md-and-back-slash.md"* ]]
  run cli list --json
  [[ "$output" == *'"file":"tasks/evil-file-tasks-hack-md-and-back-slash.md"'* ]]
  run cli find "$evil"
  [ "$status" -eq 0 ]
  [[ "$output" == *"$evil"* ]]
  run cli find 'back\slash'
  [ "$status" -eq 0 ]
  [[ "$output" == *"$evil"* ]]
  [[ "$output" != *"innocent"* ]]
}


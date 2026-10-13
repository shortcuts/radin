#!/usr/bin/env bats
# Exercises lib/radin-scope.sh: deterministic review-scope resolution.
# gh is stubbed via MOCK_BIN so PR checks run offline.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  CLI="$REPO_ROOT/lib/radin-scope.sh"
  WORK="$(cd "$(mktemp -d)" && pwd -P)"
  MOCK_BIN="$(mktemp -d)"
  export PATH="$MOCK_BIN:/usr/bin:/bin:/usr/sbin:/sbin"
  git init -q -b main "$WORK/repo"
  ( cd "$WORK/repo"
    git config user.email t@t && git config user.name t
    printf 'a\n' > f.txt && git add -A && git commit -qm init )
}

teardown() {
  rm -rf "$WORK" "$MOCK_BIN"
}

cli() {
  (cd "$WORK/repo" && bash "$CLI" "$@")
}

# gh stub: "pr view <n>" succeeds only for 123.
# Uses compiled mock binary, not shell script (20ms startup time per call).
# $1 is the optional commit hash to return when --json is present.
mock_gh() {
  MOCK_GH="${1:-pr}"
  export MOCK_GH
  ln -f "$REPO_ROOT/tests/helpers/mock" "$MOCK_BIN/gh" 2>/dev/null || true
}

@test "no argument resolves to the branch diff against main's merge-base" {
  ( cd "$WORK/repo"
    git checkout -qb feature
    printf 'b\n' > f.txt && git commit -qam change )
  run cli
  [ "$status" -eq 0 ]
  base="$(cd "$WORK/repo" && git merge-base main HEAD)"
  [[ "$output" == *"type"$'\t'"branch-diff"* ]]
  [[ "$output" == *"git diff $base..HEAD"* ]]
  [[ "$output" == *"passes"$'\t'"/ponytail:ponytail-review"* ]]
}

@test "a commit hash resolves to a commit scope" {
  hash="$(cd "$WORK/repo" && git rev-parse HEAD)"
  run cli "$hash"
  [ "$status" -eq 0 ]
  [[ "$output" == *"type"$'\t'"commit"* ]]
  [[ "$output" == *"git diff $hash^..$hash"* ]]
  [[ "$output" == *"passes"$'\t'"/ponytail:ponytail-review"* ]]
}

@test "staged resolves to the index diff, with no commit list" {
  ( cd "$WORK/repo" && printf 'a\nb\n' > f.txt && git add f.txt )
  run cli staged
  [ "$status" -eq 0 ]
  [[ "$output" == *"type"$'\t'"staged"* ]]
  [[ "$output" == *"command"$'\t'"git diff --cached"* ]]
  [[ "$output" == *"passes"$'\t'"/ponytail:ponytail-review"* ]]
  run cli --commits staged
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run bash -c "printf 'f.txt:2\nf.txt:1\n' | (cd '$WORK/repo' && bash '$CLI' --in-scope staged)"
  [ "${lines[0]}" = "in"$'\t'"f.txt:2" ]
  [ "${lines[1]}" = "out"$'\t'"f.txt:1" ]
}

@test "a directory resolves to a dir scope" {
  mkdir -p "$WORK/repo/src"
  run cli "src"
  [ "$status" -eq 0 ]
  [[ "$output" == *"type"$'\t'"dir"* ]]
  [[ "$output" == *"passes"$'\t'"/ponytail:ponytail-audit /ponytail:ponytail-debt"* ]]
  [[ "$output" != *"ponytail-review"* ]]
}

@test "#-prefixed PR resolves via gh, fails when gh doesn't know it" {
  mock_gh
  run cli "#123"
  [ "$status" -eq 0 ]
  [[ "$output" == *"type"$'\t'"pr"* ]]
  [[ "$output" == *"gh pr diff 123"* ]]
  run cli "#999"
  [ "$status" -eq 1 ]
}

@test "a GitHub PR URL resolves with --repo" {
  mock_gh
  run cli "https://github.com/algolia/foo/pull/123"
  [ "$status" -eq 0 ]
  [[ "$output" == *"gh pr diff 123 --repo algolia/foo"* ]]
}

@test "an unrecognized argument exits 1" {
  run cli "blorp zonk"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not a commit, PR, directory, range, or since-date"* ]]
}

@test "a date phrase resolves to the range starting before its oldest commit" {
  ( cd "$WORK/repo"
    GIT_COMMITTER_DATE=2020-01-01T00:00:00 git commit -q --amend --no-edit --date=2020-01-01T00:00:00
    printf 'b\n' > f.txt && git commit -qam second )
  second="$(cd "$WORK/repo" && git rev-parse HEAD)"
  run cli "since yesterday"
  [ "$status" -eq 0 ]
  [[ "$output" == *"type"$'\t'"range"* ]]
  [[ "$output" == *"git diff $second~1..HEAD"* ]]
}

@test "a date window that reaches the root commit starts from the empty tree" {
  ( cd "$WORK/repo"
    printf 'b\n' > f.txt && git commit -qam second )
  run cli "since yesterday"
  [ "$status" -eq 0 ]
  empty="$(cd "$WORK/repo" && git hash-object -t tree /dev/null)"
  [[ "$output" == *"git diff $empty..HEAD"* ]]
}

@test "an argument valid as several readings exits 2 listing candidates" {
  mock_gh
  # "123" is a PR gh knows AND an existing directory.
  mkdir -p "$WORK/repo/123"
  run cli "123"
  [ "$status" -eq 2 ]
  [[ "$output" == *"ambiguous"* ]]
  [[ "$output" == *"pr"* ]]
  [[ "$output" == *"dir"* ]]
}

@test "a commit-count range resolves, and one longer than the history does not" {
  ( cd "$WORK/repo"
    printf 'b\n' > f.txt && git commit -qam second )
  run cli "last commit"
  [ "$status" -eq 0 ]
  [[ "$output" == *"type"$'\t'"range"* ]]
  [[ "$output" == *"git diff HEAD~1..HEAD"* ]]
  run cli "last 1 commits"
  [ "$status" -eq 0 ]
  [[ "$output" == *"git diff HEAD~1..HEAD"* ]]
  run cli "last 99 commits"
  [ "$status" -ne 0 ]
  [[ "$output" == *"history is shorter"* ]]
}

@test "a rev..rev range resolves, an unknown revision does not" {
  ( cd "$WORK/repo"
    printf 'b\n' > f.txt && git commit -qam second )
  run cli "HEAD~1..HEAD"
  [ "$status" -eq 0 ]
  [[ "$output" == *"type"$'\t'"range"* ]]
  [[ "$output" == *"command"$'\t'"git diff HEAD~1..HEAD"* ]]
  run cli "deadbeefdeadbeef..HEAD"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not a revision"* ]]
}

@test "--in-scope keeps a citation the diff introduced and drops the rest" {
  ( cd "$WORK/repo"
    printf 'a\nb\nc\nd\ne\nf\ng\nh\n' > f.txt
    printf 'x\n' > other.txt
    git add -A && git commit -qm grow
    sed -i.bak 's/^h$/H/' f.txt && rm -f f.txt.bak
    git commit -qam touch-last-line )
  hash="$(cd "$WORK/repo" && git rev-parse HEAD)"
  run bash -c "printf 'f.txt:8\nf.txt:1\nother.txt:1\n' | (cd '$WORK/repo' && bash '$CLI' --in-scope '$hash')"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "in"$'\t'"f.txt:8" ]
  [ "${lines[1]}" = "out"$'\t'"f.txt:1" ]
  [ "${lines[2]}" = "out"$'\t'"other.txt:1" ]
  [ "${lines[3]}" = "dropped"$'\t'"2" ]
}

@test "--in-scope on a dir scope keeps what is under the path" {
  mkdir -p "$WORK/repo/src"
  run bash -c "printf 'src/a.c:3\n./src/b.c:9\nlib/c.c:1\n' | (cd '$WORK/repo' && bash '$CLI' --in-scope src)"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "in"$'\t'"src/a.c:3" ]
  [ "${lines[1]}" = "in"$'\t'"./src/b.c:9" ]
  [ "${lines[2]}" = "out"$'\t'"lib/c.c:1" ]
  [ "${lines[3]}" = "dropped"$'\t'"1" ]
}

@test "--in-scope still exits 0 when every citation is dropped" {
  ( cd "$WORK/repo"
    printf 'b\n' > f.txt && git commit -qam second )
  hash="$(cd "$WORK/repo" && git rev-parse HEAD)"
  run bash -c "printf 'nowhere.c:1\n' | (cd '$WORK/repo' && bash '$CLI' --in-scope '$hash')"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "out"$'\t'"nowhere.c:1" ]
  [ "${lines[1]}" = "dropped"$'\t'"1" ]
}

@test "--in-scope forwards a resolution failure's exit code" {
  run bash -c "printf 'a.c:1\n' | (cd '$WORK/repo' && bash '$CLI' --in-scope 'blorp zonk')"
  [ "$status" -eq 1 ]
}

@test "--attribute maps a cited line to the task and plan of the scope commit that wrote it" {
  ( cd "$WORK/repo"
    printf 'a\nb\n' > f.txt && git commit -qam second )
  head="$(cd "$WORK/repo" && git rev-parse HEAD)"
  mkdir -p "$WORK/repo/.claude/.radin/state"
  printf '{"id":"my-task","commit":"%s","title":"t","plan":".claude/.radin/plans/my-task.md"}\n' "$head" \
    >> "$WORK/repo/.claude/.radin/state/completed.json"

  run bash -c "printf 'f.txt:1\nf.txt:2\n' | (cd '$WORK/repo' && bash '$CLI' --attribute 'HEAD~1..HEAD')"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "f.txt:1"$'\t'"none"$'\t'"none" ]
  [ "${lines[1]}" = "f.txt:2"$'\t'"my-task"$'\t'".claude/.radin/plans/my-task.md" ]
}

@test "--attribute prints none for an untraced commit, an unparsable citation and a dir scope" {
  ( cd "$WORK/repo"
    printf 'a\nb\n' > f.txt && git commit -qam second )
  run bash -c "printf 'f.txt:2\nf.txt:x\nnope.c:1\n' | (cd '$WORK/repo' && bash '$CLI' --attribute 'HEAD~1..HEAD')"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "f.txt:2"$'\t'"none"$'\t'"none" ]
  [ "${lines[1]}" = "f.txt:x"$'\t'"none"$'\t'"none" ]
  [ "${lines[2]}" = "nope.c:1"$'\t'"none"$'\t'"none" ]

  mkdir -p "$WORK/repo/src"
  run bash -c "printf 'f.txt:1\n' | (cd '$WORK/repo' && bash '$CLI' --attribute src)"
  [ "$status" -eq 0 ]
  [ "$output" = "f.txt:1"$'\t'"none"$'\t'"none" ]

  run bash -c "printf 'f.txt:1\n' | (cd '$WORK/repo' && bash '$CLI' --attribute 'blorp zonk')"
  [ "$status" -eq 1 ]
}

@test "--commits prints the scope's commit list, hash then subject" {
  ( cd "$WORK/repo"
    printf 'b\n' > f.txt && git commit -qam second )
  head="$(cd "$WORK/repo" && git rev-parse HEAD)"

  run cli --commits "$head"
  [ "$status" -eq 0 ]
  [ "$output" = "$head second" ]

  run cli --commits "HEAD~1..HEAD"
  [ "$status" -eq 0 ]
  [ "$output" = "$head second" ]

  mkdir -p "$WORK/repo/src"
  run cli --commits src
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  run cli --commits "blorp zonk"
  [ "$status" -eq 1 ]
}

# Records completion $2 on commit $1 with branch $3 and created stamp $4.
record_stamped() {
  mkdir -p "$WORK/repo/.claude/.radin/state"
  printf '{"id":"%s","commit":"%s","title":"t","branch":"%s","created":"%s"}\n' "$2" "$1" "$3" "$4" \
    >> "$WORK/repo/.claude/.radin/state/completed.json"
}

@test "--specs lists tasks by created date: in-scope commit, reflog-recovered commit, pending entry" {
  ( cd "$WORK/repo"
    git checkout -qb feat
    printf 'b\n' > f.txt && git commit -qam second )
  head="$(cd "$WORK/repo" && git rev-parse HEAD)"
  # A squashed-away commit: gone from history, still in the branch reflog.
  ( cd "$WORK/repo"
    printf 'c\n' > f.txt && git commit -qam third )
  lost="$(cd "$WORK/repo" && git rev-parse HEAD)"
  ( cd "$WORK/repo"
    git reset -q --hard HEAD~1
    printf 'c2\n' > f.txt && git commit -qam third-squashed )
  record_stamped "$head" kept-task feat 2026-01-02T00:00:00Z
  record_stamped "$lost" squashed-task feat 2026-01-01T00:00:00Z
  record_stamped cafe1234cafe1234 elsewhere-task feat 2026-01-03T00:00:00Z
  ( cd "$WORK/repo" && bash "$REPO_ROOT/lib/radin-backlog.sh" add fix "pending one" <<<"b" ) >/dev/null

  run cli --specs
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "squashed-task"$'\t'"2026-01-01T00:00:00Z"$'\t'"feat"$'\t'"$lost"$'\t'"reflog" ]]
  [[ "${lines[1]}" == "kept-task"$'\t'"2026-01-02T00:00:00Z"$'\t'"feat"$'\t'"$head"$'\t'"commit" ]]
  [[ "${lines[2]}" == "pending-one"$'\t'"20"*$'\t'"feat"$'\t'$'\t'"pending" ]]
  [ "${#lines[@]}" -eq 3 ]
}

@test "--specs stops with exit 4 when a recorded commit is gone and HEAD has no branch" {
  record_stamped cafe1234cafe1234 gone-task feat 2026-01-01T00:00:00Z
  ( cd "$WORK/repo" && git checkout -q --detach )
  run cli --specs HEAD
  [ "$status" -eq 4 ]
  [[ "$output" == *"no branch"* ]]
}

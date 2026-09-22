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
mock_gh() {
  cat > "$MOCK_BIN/gh" <<'EOF'
#!/bin/sh
if [ "$1" = "pr" ] && [ "$2" = "view" ] && [ "$3" = "123" ]; then exit 0; fi
exit 1
EOF
  chmod +x "$MOCK_BIN/gh"
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
}

@test "a commit hash resolves to a commit scope" {
  hash="$(cd "$WORK/repo" && git rev-parse HEAD)"
  run cli "$hash"
  [ "$status" -eq 0 ]
  [[ "$output" == *"type"$'\t'"commit"* ]]
  [[ "$output" == *"git diff $hash^..$hash"* ]]
}

@test "a directory resolves to a dir scope" {
  mkdir -p "$WORK/repo/src"
  run cli "src"
  [ "$status" -eq 0 ]
  [[ "$output" == *"type"$'\t'"dir"* ]]
  [[ "$output" == *"src"* ]]
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
    printf 'b\n' > f.txt && git commit -qam second )
  oldest="$(cd "$WORK/repo" && git log --since=yesterday --format=%H | tail -1)"
  run cli "since yesterday"
  [ "$status" -eq 0 ]
  [[ "$output" == *"type"$'\t'"range"* ]]
  # The window reaches the root commit, so the left side is the empty tree.
  empty="$(cd "$WORK/repo" && git hash-object -t tree /dev/null)"
  [ "$oldest" = "$(cd "$WORK/repo" && git rev-list --max-parents=0 HEAD)" ]
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

@test "every resolved type names the ponytail passes it calls for" {
  mkdir -p "$WORK/repo/src"
  run cli "src"
  [ "$status" -eq 0 ]
  [[ "$output" == *"passes"$'\t'"/ponytail:ponytail-audit /ponytail:ponytail-debt"* ]]
  [[ "$output" != *"ponytail-review"* ]]
  hash="$(cd "$WORK/repo" && git rev-parse HEAD)"
  run cli "$hash"
  [[ "$output" == *"passes"$'\t'"/ponytail:ponytail-review"* ]]
  run cli
  [[ "$output" == *"passes"$'\t'"/ponytail:ponytail-review"* ]]
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

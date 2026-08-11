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

@test "syntax is valid" {
  run bash -n "$CLI"
  [ "$status" -eq 0 ]
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

@test "an unrecognized argument exits 1 (natural-language ranges stay the caller's job)" {
  run cli "since yesterday"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not a commit, PR, or directory"* ]]
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

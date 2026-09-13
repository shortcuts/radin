#!/usr/bin/env bats
# Exercises lib/radin-update.sh: the CLI path that refreshes radin itself and
# every companion tool. install.sh is stubbed, so nothing here installs.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  CLI="$REPO_ROOT/lib/radin-update.sh"
  TEST_HOME="$(mktemp -d)"
  MOCK_BIN="$(mktemp -d)"
  export PATH="$MOCK_BIN:/usr/bin:/bin:/usr/sbin:/sbin"
  mkdir -p "$TEST_HOME/.claude/.radin"

  # A curl that writes a stub installer, so the tarball path is testable
  # without the network.
  cat > "$MOCK_BIN/curl" <<'EOF'
#!/bin/sh
out=""
prev=""
for arg in "$@"; do
  if [ "$prev" = "-o" ]; then out="$arg"; fi
  prev="$arg"
done
printf '#!/bin/sh\necho "downloaded installer args: $*"\n' > "$out"
EOF
  chmod +x "$MOCK_BIN/curl"
}

teardown() {
  rm -rf "$TEST_HOME" "$MOCK_BIN"
}

# A dev clone with a stub install.sh and an upstream to pull from.
make_clone() {
  local upstream="$TEST_HOME/upstream" clone="$TEST_HOME/clone"
  git init -q --bare "$upstream"
  git init -q "$clone"
  git -C "$clone" config user.email t@t
  git -C "$clone" config user.name t
  printf '#!/bin/sh\necho "clone installer args: $*"\n' > "$clone/install.sh"
  git -C "$clone" add install.sh
  git -C "$clone" commit -qm init
  git -C "$clone" remote add origin "$upstream"
  git -C "$clone" push -q -u origin HEAD:main
  printf '%s\n' "$clone" > "$TEST_HOME/.claude/.radin/install_root"
  printf '%s' "$clone"
}

@test "syntax is valid" {
  run bash -n "$CLI"
  [ "$status" -eq 0 ]
}

@test "pulls a dev clone, then re-runs its install.sh in update mode" {
  clone="$(make_clone)"
  run env HOME="$TEST_HOME" bash "$CLI"
  [ "$status" -eq 0 ]
  [[ "$output" == *"pulling $clone"* ]]
  [[ "$output" == *"clone installer args: --update"* ]]
}

# Pulling over someone's uncommitted work is the one destructive thing this
# path could do, so it stops instead.
@test "refuses to pull a dirty dev clone" {
  clone="$(make_clone)"
  echo "local work" >> "$clone/install.sh"
  run env HOME="$TEST_HOME" bash "$CLI"
  [ "$status" -eq 1 ]
  [[ "$output" == *"uncommitted changes"* ]]
  [[ "$output" != *"clone installer args"* ]]
}

@test "downloads the newest installer when the source is a tarball install" {
  mkdir -p "$TEST_HOME/.claude/radin"
  : > "$TEST_HOME/.claude/radin/.radin-version"
  printf '%s\n' "$TEST_HOME/.claude/radin" > "$TEST_HOME/.claude/.radin/install_root"
  run env HOME="$TEST_HOME" bash "$CLI"
  [ "$status" -eq 0 ]
  [[ "$output" == *"downloaded installer args: --update"* ]]
}

@test "downloads the installer when no install_root was ever recorded" {
  run env HOME="$TEST_HOME" bash "$CLI"
  [ "$status" -eq 0 ]
  [[ "$output" == *"downloaded installer args: --update"* ]]
}

@test "passes extra flags through to the installer" {
  run env HOME="$TEST_HOME" bash "$CLI" --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"downloaded installer args: --update --yes"* ]]
}

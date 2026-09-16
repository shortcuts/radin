# Builds a C helper (or the C TUI) once per checkout, rebuilding only when the
# source is newer: the cost lands on the first test that needs it.
cc_build() {
  local src="$1" out="$2"
  if [ ! -x "$out" ] || [ "$src" -nt "$out" ]; then
    command -v cc >/dev/null 2>&1 || return 1
    cc -O1 -o "$out.$$" "$src" 2>/dev/null || return 1
    mv -f "$out.$$" "$out"
  fi
}

pty_build() {
  PTY_RUN="$BATS_TEST_DIRNAME/helpers/pty-run"
  cc_build "$PTY_RUN.c" "$PTY_RUN"
}

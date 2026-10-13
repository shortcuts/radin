#!/usr/bin/env bats
# AGENTS.md hard rules: shell files stay bash 3.2 (no mapfile, associative
# arrays, case-conversion expansions, uname branch), and install.sh never
# `rm`s under ~/.claude beyond the one allowlisted line below.
#
# Ceilings: a literal grep, not a parser -- a construct spelled through `eval`
# or a path held in a variable escapes both checks.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  FILES="install.sh bin/radin lib/*.sh tests/bench-tui.sh"
  # Known exceptions, in file order: removes a skill radin renamed, then the
  # radin-installed thermo-nuclear copy right before the fresh npx copy is
  # renamed over it.
  RM_ALLOWED='rm -rf "$HOME/.claude/skills/$s"
rm -rf "$HOME/.claude/skills/thermo-nuclear"'
}

@test "no bash 4+ or uname construct in the shell files" {
  cd "$REPO_ROOT" || return 1
  # shellcheck disable=SC2086
  run grep -nE '^[^#]*(\<(mapfile|readarray|uname)\>|(declare|typeset|local)[[:space:]]+-[a-zA-Z]*A|\$\{[A-Za-z_0-9]+(,,|\^\^)\})' $FILES
  echo "$output"
  [ "$status" -eq 1 ]
}

@test "the only rms under ~/.claude in install.sh and lib/ are the allowlisted ones" {
  cd "$REPO_ROOT" || return 1
  hits="$(grep -nE '^[^#]*\brm[[:space:]].*\.claude' install.sh lib/*.sh |
    grep -v '^lib/radin-uninstall.sh:' | sed 's/^[^:]*:[0-9]*:[[:space:]]*//')"
  echo "$hits"
  [ "$hits" = "$RM_ALLOWED" ]
}

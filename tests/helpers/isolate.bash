# Points every host path variable at one temp home, so no test reads or writes
# a real Claude, Codex or opencode file.
isolate_env() {
  export HOME="$1"
  export XDG_CONFIG_HOME="$1/.config"
  export CODEX_HOME="$1/.codex"
  unset OPENCODE_CONFIG CLAUDE_CONFIG_DIR OPENCODE
  # Tests assert on progress lines; install.sh prints them only with details on.
  export RADIN_DETAILS=1
}

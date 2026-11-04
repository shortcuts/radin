# Points every host path variable at one temp home, so no test reads or writes
# a real Claude, Codex or opencode file.
isolate_env() {
  export HOME="$1"
  export XDG_CONFIG_HOME="$1/.config"
  export CODEX_HOME="$1/.codex"
  unset OPENCODE_CONFIG CLAUDE_CONFIG_DIR
}

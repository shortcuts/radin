use std::path::Path;
use std::process::Command;

pub fn isolate(cmd: &mut Command, home: &Path) {
    cmd.env("HOME", home)
        .env("XDG_CONFIG_HOME", home.join(".config"))
        .env("CODEX_HOME", home.join(".codex"))
        .env("RADIN_DETAILS", "1")
        .env_remove("OPENCODE_CONFIG")
        .env_remove("CLAUDE_CONFIG_DIR")
        .env_remove("OPENCODE");
}

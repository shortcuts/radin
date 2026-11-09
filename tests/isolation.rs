mod common;

use std::process::Command;

#[test]
fn isolate_points_every_host_path_under_the_given_home() {
    let home = tempfile::tempdir().unwrap();
    let mut cmd = Command::new("sh");
    cmd.args([
        "-c",
        r#"printf "%s|%s|%s|%s|%s" "$HOME" "$XDG_CONFIG_HOME" "$CODEX_HOME" "${OPENCODE_CONFIG-unset}" "${CLAUDE_CONFIG_DIR-unset}""#,
    ])
    .env("CODEX_HOME", "/nonexistent/c")
    .env("XDG_CONFIG_HOME", "/nonexistent/x")
    .env("OPENCODE_CONFIG", "/nonexistent/o")
    .env("CLAUDE_CONFIG_DIR", "/nonexistent/d");
    common::isolate(&mut cmd, home.path());
    let out = String::from_utf8(cmd.output().unwrap().stdout).unwrap();
    let h = home.path().display();
    assert_eq!(out, format!("{h}|{h}/.config|{h}/.codex|unset|unset"));
}

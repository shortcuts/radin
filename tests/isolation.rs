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

fn sum(home: &std::path::Path, opencode_config: Option<&std::path::Path>) -> String {
    let mut cmd = Command::new("make");
    cmd.args(["-s", "real-setup-sum"])
        .current_dir(env!("CARGO_MANIFEST_DIR"));
    common::isolate(&mut cmd, home);
    if let Some(p) = opencode_config {
        cmd.env("OPENCODE_CONFIG", p);
    }
    let o = cmd.output().unwrap();
    assert!(o.status.success());
    String::from_utf8(o.stdout).unwrap()
}

#[test]
fn real_setup_sum_tracks_every_watched_path() {
    let w = tempfile::tempdir().unwrap();
    let home = w.path().canonicalize().unwrap().join("h");
    let (codex, oc) = (home.join(".codex"), home.join(".config/opencode"));
    for d in [&codex, &oc, &home.join(".radin")] {
        std::fs::create_dir_all(d).unwrap();
    }
    let custom = w.path().join("custom.json");
    let clean = sum(&home, Some(&custom));
    for p in [
        codex.join("AGENTS.md"),
        codex.join("hooks.json"),
        codex.join("config.toml"),
        oc.join("AGENTS.md"),
        oc.join("opencode.json"),
        home.join(".radin/manifest.json"),
        custom.clone(),
    ] {
        assert!(
            clean.contains(&format!("{} absent\n", p.display())),
            "{p:?}"
        );
    }
    std::fs::write(codex.join("AGENTS.md"), "one\n").unwrap();
    std::fs::write(oc.join("opencode.json"), "{}\n").unwrap();
    std::fs::write(&custom, "{}\n").unwrap();
    let first = sum(&home, Some(&custom));
    for p in [
        codex.join("AGENTS.md"),
        oc.join("opencode.json"),
        custom.clone(),
    ] {
        assert!(!first.contains(&format!("{} absent", p.display())), "{p:?}");
    }
    std::fs::write(codex.join("AGENTS.md"), "two\n").unwrap();
    assert_ne!(sum(&home, Some(&custom)), first);
}

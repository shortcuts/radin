mod common;

use std::process::{Command, Output};

fn radin(args: &[&str], env: &[(&str, &str)]) -> Output {
    let home = tempfile::tempdir().unwrap();
    let mut cmd = Command::new(env!("CARGO_BIN_EXE_radin"));
    cmd.args(args).envs(env.iter().copied());
    common::isolate(&mut cmd, home.path());
    cmd.output().unwrap()
}

fn text(b: &[u8]) -> String {
    String::from_utf8(b.to_vec()).unwrap()
}

#[test]
fn help_exits_0_with_usage_on_stdout() {
    let o = radin(&["help"], &[]);
    assert_eq!(o.status.code(), Some(0));
    assert_eq!(text(&o.stdout), radin::USAGE);
}

#[test]
fn bogus_host_flag_exits_2() {
    let o = radin(&["--host", "bogus", "help"], &[]);
    assert_eq!(o.status.code(), Some(2));
    assert_eq!(
        text(&o.stderr),
        "radin: unknown host 'bogus' (expected claude|agents)\n"
    );
}

#[test]
fn host_flag_alone_exits_2() {
    assert_eq!(radin(&["--host"], &[]).status.code(), Some(2));
}

#[test]
fn bogus_env_host_exits_2() {
    assert_eq!(
        radin(&["help"], &[("RADIN_HOST", "bogus")]).status.code(),
        Some(2)
    );
}

#[test]
fn state_reads_its_stdin_and_runs_in_the_current_directory() {
    use std::io::Write;
    let w = tempfile::tempdir().unwrap();
    let repo = w.path().canonicalize().unwrap().join("proj");
    std::fs::create_dir(&repo).unwrap();
    for a in [
        &["init", "-q"][..],
        &["commit", "-q", "--allow-empty", "-m", "i"],
    ] {
        assert!(common::git_in(&repo, a).status.success());
    }
    let mut cmd = Command::new(env!("CARGO_BIN_EXE_radin"));
    cmd.args(["state", "steps-init"]).current_dir(&repo);
    common::isolate(&mut cmd, &w.path().join("home"));
    let mut child = cmd
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(b"x\t1\t\tpending\n")
        .unwrap();
    let o = child.wait_with_output().unwrap();
    assert_eq!(o.status.code(), Some(0), "{}", text(&o.stderr));
    assert_eq!(
        text(&o.stdout),
        format!(
            "steps-init: wrote 1 entries to {}/.radin/state/BACKLOG_STEPS.json\n",
            repo.display()
        )
    );
}

#[test]
fn no_subcommand_off_a_terminal_prints_usage_to_stderr() {
    let o = radin(&[], &[]);
    assert_eq!(o.status.code(), Some(1));
    assert_eq!(text(&o.stderr), radin::USAGE);
}

#[test]
fn unknown_word_exits_1() {
    assert_eq!(radin(&["frobnicate"], &[]).status.code(), Some(1));
}

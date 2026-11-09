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

fn in_proj(
    dir: &std::path::Path,
    home: &std::path::Path,
    args: &[&str],
    env: &[(&str, &str)],
    stdin: &str,
) -> Output {
    use std::io::Write;
    let mut cmd = Command::new(env!("CARGO_BIN_EXE_radin"));
    cmd.args(args).current_dir(dir);
    common::isolate(&mut cmd, home);
    cmd.envs(env.iter().copied());
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
        .write_all(stdin.as_bytes())
        .unwrap();
    child.wait_with_output().unwrap()
}

fn proj() -> (tempfile::TempDir, std::path::PathBuf, std::path::PathBuf) {
    let w = tempfile::tempdir().unwrap();
    let root = w.path().canonicalize().unwrap();
    let p = root.join("proj");
    std::fs::create_dir(&p).unwrap();
    let h = root.join("home");
    (w, p, h)
}

#[test]
fn every_host_writes_the_same_radin_dir() {
    let (_w, p, h) = proj();
    let add = |args: &[&str]| in_proj(&p, &h, args, &[], "body\n");
    assert_eq!(
        add(&["backlog", "add", "feat", "one thing"]).status.code(),
        Some(0)
    );
    assert_eq!(
        add(&["--host", "agents", "backlog", "add", "feat", "two thing"])
            .status
            .code(),
        Some(0)
    );
    assert!(p.join(".radin/backlog/index.jsonl").is_file());
    assert!(!p.join(".claude").exists() && !p.join(".agents").exists());
    for args in [
        &["--host=agents", "backlog", "count"][..],
        &["--host", "claude", "backlog", "count"],
    ] {
        assert_eq!(text(&in_proj(&p, &h, args, &[], "").stdout).trim(), "2");
    }
}

#[test]
fn host_after_the_subcommand_is_not_the_dispatchers() {
    let (_w, p, h) = proj();
    in_proj(&p, &h, &["backlog", "--host", "agents"], &[], "");
    assert!(!p.join(".agents").exists());
}

#[test]
fn host_all_is_an_unknown_host() {
    let o = radin(&["--host", "all", "backlog", "count"], &[]);
    assert_eq!(o.status.code(), Some(2));
    assert_eq!(
        text(&o.stderr),
        "radin: unknown host 'all' (expected claude|agents)\n"
    );
}

#[test]
fn state_verbs_read_radin_for_every_host() {
    let (_w, p, h) = proj();
    let git = |a: &[&str]| {
        let mut full = vec!["-c", "user.email=t@t", "-c", "user.name=t"];
        full.extend_from_slice(a);
        let o = common::git_in(&p, &full);
        assert!(o.status.success(), "{a:?}");
        text(&o.stdout)
    };
    git(&["init", "-q", "."]);
    git(&["commit", "-q", "--allow-empty", "-m", "init"]);
    std::fs::create_dir_all(p.join(".radin")).unwrap();
    std::fs::write(p.join(".radin/x"), "x\n").unwrap();
    git(&["add", "-f", ".radin/x"]);
    git(&["commit", "-q", "-m", "touch state"]);
    let hash = git(&["rev-parse", "HEAD"]);
    let o = in_proj(
        &p,
        &h,
        &[
            "--host",
            "agents",
            "state",
            "task-done",
            "some-id",
            hash.trim(),
        ],
        &[],
        "",
    );
    assert_eq!(o.status.code(), Some(3));
    assert!(text(&o.stdout).contains("under .radin/") || text(&o.stderr).contains("under .radin/"));
    std::fs::write(p.join(".radin/y"), "y\n").unwrap();
    let o = in_proj(&p, &h, &["state", "dirty-check"], &[], "");
    assert_eq!(text(&o.stdout), "");
}

#[test]
fn inside_opencode_no_flag_still_writes_radin() {
    let (_w, p, h) = proj();
    let o = in_proj(
        &p,
        &h,
        &["backlog", "add", "feat", "one thing"],
        &[("OPENCODE", "1")],
        "body\n",
    );
    assert_eq!(o.status.code(), Some(0));
    assert!(p.join(".radin/backlog/index.jsonl").is_file());
    assert!(!p.join(".agents").exists());
}

#[test]
fn state_skips_a_socket_stdin_that_never_closes() {
    // Claude Code's Bash tool hands commands an open socket on stdin.
    let (_keep, theirs) = std::os::unix::net::UnixStream::pair().unwrap();
    let home = tempfile::tempdir().unwrap();
    let mut cmd = Command::new(env!("CARGO_BIN_EXE_radin"));
    cmd.args(["state", "wave-cap"])
        .current_dir(home.path())
        .stdin(std::os::fd::OwnedFd::from(theirs))
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null());
    common::isolate(&mut cmd, home.path());
    let mut child = cmd.spawn().unwrap();
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
    while child.try_wait().unwrap().is_none() {
        if std::time::Instant::now() > deadline {
            child.kill().unwrap();
            panic!("radin state blocked on a socket stdin");
        }
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
}

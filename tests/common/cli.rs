#![allow(dead_code)]
use std::path::Path;
use std::process::{Command, Stdio};

pub struct Run {
    pub code: i32,
    pub out: String,
    pub err: String,
}

pub fn git(dir: &Path, args: &[&str]) -> String {
    let o = Command::new("git")
        .args(["-c", "user.name=t", "-c", "user.email=t@t"])
        .args(args)
        .current_dir(dir)
        .output()
        .unwrap();
    assert!(o.status.success(), "git {args:?}: {:?}", o);
    String::from_utf8(o.stdout).unwrap()
}

pub fn radin(dir: &Path, home: &Path, args: &[&str]) -> Run {
    radin_with(dir, home, args, "", &[])
}

pub fn radin_with(
    dir: &Path,
    home: &Path,
    args: &[&str],
    stdin: &str,
    env: &[(&str, &str)],
) -> Run {
    use std::io::Write;
    let mut cmd = Command::new(env!("CARGO_BIN_EXE_radin"));
    cmd.args(args)
        .current_dir(dir)
        .envs(env.iter().copied())
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    super::common::isolate(&mut cmd, home);
    let mut child = cmd.spawn().unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(stdin.as_bytes())
        .unwrap();
    let o = child.wait_with_output().unwrap();
    Run {
        code: o.status.code().unwrap(),
        out: String::from_utf8_lossy(&o.stdout).into_owned(),
        err: String::from_utf8_lossy(&o.stderr).into_owned(),
    }
}

pub fn stub(dir: &Path, name: &str, body: &str) {
    use std::os::unix::fs::PermissionsExt;
    let p = dir.join(name);
    std::fs::write(&p, format!("#!/bin/sh\n{body}")).unwrap();
    std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o755)).unwrap();
}

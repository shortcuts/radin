use crate::{Ctx, Out};
use std::path::PathBuf;
use std::process::Command;

const INSTALLER_URL: &str =
    "https://github.com/shortcuts/radin/releases/latest/download/radin-installer.sh";

fn fail(msg: String) -> Out {
    (1, String::new(), format!("radin update: {msg}\n"))
}

/// Fetches the newest release installer, runs it, then runs the new binary's `install --update`.
pub fn run(c: &Ctx, args: &[String]) -> Out {
    let url = (c.env)("RADIN_INSTALLER_URL")
        .filter(|u| !u.is_empty())
        .unwrap_or_else(|| INSTALLER_URL.into());
    let tmp = std::env::temp_dir().join(format!("radin-installer-{}.sh", std::process::id()));
    let got = Command::new("curl")
        .args(["-fsSL", &url, "-o"])
        .arg(&tmp)
        .status();
    match got {
        Err(_) => return fail("curl not found -- install curl, then re-run.".into()),
        Ok(s) if !s.success() => return fail(format!("could not download {url}")),
        Ok(_) => {}
    }
    let ran = Command::new("sh").arg(&tmp).status();
    let _ = std::fs::remove_file(&tmp);
    if !ran.is_ok_and(|s| s.success()) {
        return fail("the release installer failed.".into());
    }
    let cargo = (c.env)("CARGO_HOME")
        .filter(|d| !d.is_empty())
        .map_or_else(|| c.home.join(".cargo"), PathBuf::from);
    let code = Command::new(cargo.join("bin/radin"))
        .args(["install", "--update"])
        .args(args)
        .status()
        .map_or(1, |s| s.code().unwrap_or(1));
    (code, String::new(), String::new())
}

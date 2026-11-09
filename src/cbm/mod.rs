mod config;
mod hooks;

pub use config::{allow, unallow, unallow_legacy};

use crate::{jsonedit, Ctx, Out};
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;

pub(crate) const NAME: &str = "codebase-memory-mcp";

pub(crate) fn die(prefix: &str, msg: &str) -> Out {
    (1, String::new(), format!("{prefix}: {msg}\n"))
}

pub(crate) fn jctx(c: &Ctx) -> jsonedit::Ctx {
    jsonedit::Ctx {
        home: Some(c.home.to_string_lossy().into_owned()),
        path: (c.env)("PATH"),
    }
}

fn executable(p: &Path) -> bool {
    fs::metadata(p).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
}

/// Upstream's installer targets ~/.local/bin, which is not on every PATH.
pub(crate) fn which(c: &Ctx) -> Option<String> {
    let path = (c.env)("PATH").unwrap_or_default();
    path.split(':')
        .map(|d| Path::new(if d.is_empty() { "." } else { d }).join(NAME))
        .chain([c.home.join(".local/bin").join(NAME)])
        .find(|p| executable(p))
        .map(|p| p.to_string_lossy().into_owned())
}

pub(crate) fn which_or_die(c: &Ctx, prefix: &str) -> Result<String, Out> {
    which(c).ok_or_else(|| {
        die(
            prefix,
            &format!("{NAME} not found on PATH or in ~/.local/bin -- run radin's install.sh first"),
        )
    })
}

pub fn run_hooks(c: &Ctx, args: &[String]) -> Out {
    let p = "radin-cbm-hooks";
    let bin = match which_or_die(c, p) {
        Ok(b) => b,
        Err(e) => return e,
    };
    let repo = args.get(1).map(String::as_str).unwrap_or("");
    match args.first().map(String::as_str) {
        Some("claude-md") => hooks::claude_md(c),
        Some("mcp") => hooks::mcp(c, repo, &bin),
        Some("all") => hooks::all(c, repo, &bin),
        _ => die(
            p,
            "usage: radin hooks <claude-md|mcp [repo-root]|all [repo-root]>",
        ),
    }
}

pub fn run_wire(c: &Ctx) -> Out {
    config::install(c)
}

pub fn run_repair(c: &Ctx) -> Out {
    config::repair(c)
}

use super::S;
use crate::backlog::Io;
use std::path::Path;
use std::process::Command;

use crate::paths::git as g_raw;

/// Stdout of `git -C dir args` on success, None on a non-zero exit.
pub fn g(dir: &Path, args: &[&str]) -> Option<String> {
    g_raw(dir, args)
}

/// Trimmed stdout, empty on failure.
pub fn gt(dir: &Path, args: &[&str]) -> String {
    g(dir, args).unwrap_or_default().trim_end().to_string()
}

pub fn ok(dir: &Path, args: &[&str]) -> bool {
    g(dir, args).is_some()
}

/// Runs git and forwards its stdout and stderr, in the order git wrote them, to the error stream, as the bash `>&2` calls did.
pub fn gx(dir: &Path, args: &[&str], io: &mut Io) -> bool {
    let mut run = || -> std::io::Result<bool> {
        let (mut rd, wr) = std::io::pipe()?;
        let mut cmd = Command::new("git");
        cmd.args(args)
            .current_dir(dir)
            .stdout(wr.try_clone()?)
            .stderr(wr);
        let mut child = cmd.spawn()?;
        drop(cmd);
        let mut buf = String::new();
        std::io::Read::read_to_string(&mut rd, &mut buf)?;
        io.err.push_str(&buf);
        Ok(child.wait()?.success())
    };
    run().unwrap_or(false)
}

pub fn dirty_files(dir: &Path) -> String {
    gt(
        dir,
        &["status", "--porcelain", "--", ".", ":(exclude).radin"],
    )
}

/// `git add -A` without .radin; git rejects an exclude pathspec for an ignored path.
pub fn stage_all(dir: &Path) {
    if ok(dir, &["check-ignore", "-q", ".radin"]) {
        g(dir, &["add", "-A"]);
    } else {
        g(dir, &["add", "-A", "--", ".", ":(exclude).radin"]);
    }
}

pub fn commit_dirty(dir: &Path, body: &str) -> bool {
    stage_all(dir);
    let staged = gt(dir, &["diff", "--cached", "--name-only"]);
    let names: Vec<&str> = staged
        .lines()
        .map(|l| l.rsplit('/').next().unwrap_or(l))
        .collect();
    let mut label = names.iter().take(3).copied().collect::<Vec<_>>().join(", ");
    if names.len() > 3 {
        label += &format!(" +{} more", names.len() - 3);
    }
    ok(
        dir,
        &[
            "commit",
            "--no-verify",
            "-q",
            "-m",
            &format!("wip: update {label}"),
            "-m",
            body,
        ],
    )
}

/// Commits everything but .radin as unfinished work of task `id`; --no-verify so a failing hook never strands work.
pub fn wip_commit(dir: &Path, id: &str, body: &str) -> String {
    stage_all(dir);
    g(
        dir,
        &[
            "commit",
            "--no-verify",
            "-q",
            "-m",
            &format!("wip({id}): unfinished work, task not complete"),
            "-m",
            body,
        ],
    );
    gt(dir, &["rev-parse", "--short", "HEAD"])
}

/// The worktree holding `branch`, read from `git worktree list --porcelain` text.
pub fn branch_worktree(porcelain: &str, branch: &str) -> String {
    let want = format!("branch refs/heads/{branch}");
    let mut w = "";
    for l in porcelain.lines() {
        if let Some(p) = l.strip_prefix("worktree ") {
            w = p;
        } else if l == want {
            return w.to_string();
        }
    }
    String::new()
}

impl S<'_> {
    pub fn git(&self, args: &[&str]) -> Option<String> {
        g(&self.root, args)
    }

    pub fn gt(&self, args: &[&str]) -> String {
        gt(&self.root, args)
    }

    pub fn git_ok(&self, args: &[&str]) -> bool {
        ok(&self.root, args)
    }

    pub fn branch_exists(&self, branch: &str) -> bool {
        self.git_ok(&[
            "rev-parse",
            "--verify",
            "-q",
            &format!("refs/heads/{branch}"),
        ])
    }

    pub fn radin_branches(&self) -> Vec<String> {
        self.gt(&[
            "for-each-ref",
            "--format=%(refname:short)",
            "refs/heads/radin/",
        ])
        .lines()
        .map(String::from)
        .collect()
    }

    /// Base branch: baseline.json's, else the checkout's own unless detached or a radin/* branch.
    pub fn resolve_base(&self) -> String {
        let b = std::fs::read_to_string(self.state.join("baseline.json"))
            .map(|t| super::store::get(&t, "base_branch"))
            .unwrap_or_default();
        if !b.is_empty() {
            return b;
        }
        let b = self.gt(&["rev-parse", "--abbrev-ref", "HEAD"]);
        if b == "HEAD" || b.starts_with("radin/") {
            String::new()
        } else {
            b
        }
    }

    /// True when merging `commit` into `branch` changes nothing: the work landed under any hash.
    pub fn landed(&self, commit: &str, branch: &str) -> bool {
        let merged = self
            .git(&["merge-tree", "--write-tree", branch, commit])
            .unwrap_or_default();
        let tree = self.gt(&["rev-parse", &format!("{branch}^{{tree}}")]);
        merged.lines().next().unwrap_or("") == tree
    }

    pub fn task_dir(&self, id: &str) -> std::path::PathBuf {
        let mut wt = self.root.as_os_str().to_owned();
        wt.push(format!("-{id}"));
        let wt = std::path::PathBuf::from(wt);
        if wt.is_dir() {
            wt
        } else {
            self.root.clone()
        }
    }
}

use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::process::Command;

pub fn radin_home(home: &Path) -> PathBuf {
    home.join(".radin")
}

#[derive(Debug, PartialEq, Eq)]
pub struct Namespace {
    pub repo_root: PathBuf,
    pub namespace_dir: PathBuf,
    pub backlog_index: PathBuf,
    pub backlog_tasks_dir: PathBuf,
    pub created: bool,
}

pub(crate) fn git(cwd: &Path, args: &[&str]) -> Option<String> {
    let out = Command::new("git")
        .args(args)
        .current_dir(cwd)
        .output()
        .ok()?;
    out.status
        .success()
        .then(|| String::from_utf8_lossy(&out.stdout).into_owned())
}

impl Namespace {
    pub fn locate(cwd: &Path) -> Namespace {
        let revs = git(
            cwd,
            &[
                "rev-parse",
                "--show-toplevel",
                "--git-dir",
                "--git-common-dir",
            ],
        )
        .unwrap_or_default();
        let mut l = revs.lines();
        let mut root = match l.next() {
            Some(r) if !r.is_empty() => PathBuf::from(r),
            _ => cwd.to_path_buf(),
        };
        let (git_dir, common) = (l.next().unwrap_or(""), l.next().unwrap_or(""));
        if git_dir != common {
            let branch = git(cwd, &["symbolic-ref", "--short", "-q", "HEAD"]).unwrap_or_default();
            let id = branch.trim_end().strip_prefix("radin/").unwrap_or("");
            let parent = root
                .to_str()
                .and_then(|r| r.strip_suffix(&format!("-{id}")));
            if let (false, Some(p)) = (id.is_empty(), parent) {
                let p = PathBuf::from(p);
                if p != root && p.join(".radin").is_dir() {
                    root = p;
                }
            }
        }
        let namespace_dir = root.join(".radin");
        Namespace {
            backlog_index: namespace_dir.join("backlog/index.jsonl"),
            backlog_tasks_dir: namespace_dir.join("backlog/tasks"),
            created: !namespace_dir.exists(),
            repo_root: root,
            namespace_dir,
        }
    }

    pub fn ensure_dirs(&self) -> io::Result<()> {
        for d in ["state/facts", "plans", "reviews", "backlog/tasks"] {
            fs::create_dir_all(self.namespace_dir.join(d))?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn git_in(dir: &Path, args: &[&str]) {
        let st = Command::new("git")
            .args(["-c", "user.name=t", "-c", "user.email=t@t"])
            .args(args)
            .current_dir(dir)
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .env("GIT_CONFIG_SYSTEM", "/dev/null")
            .status()
            .unwrap();
        assert!(st.success(), "git {args:?}");
    }

    fn work() -> (tempfile::TempDir, PathBuf) {
        let t = tempfile::tempdir().unwrap();
        let p = t.path().canonicalize().unwrap();
        (t, p)
    }

    fn proj(w: &Path) -> PathBuf {
        let p = w.join("proj");
        fs::create_dir(&p).unwrap();
        git_in(&p, &["init", "-q"]);
        git_in(&p, &["commit", "-q", "--allow-empty", "-m", "init"]);
        p
    }

    #[test]
    fn radin_home_is_dot_radin() {
        assert_eq!(radin_home(Path::new("/h")), PathBuf::from("/h/.radin"));
    }

    #[test]
    fn resolves_to_repo_root_from_a_subdirectory_and_creates_dirs() {
        let (_t, w) = work();
        let p = proj(&w);
        fs::create_dir(p.join("sub")).unwrap();
        let ns = Namespace::locate(&p.join("sub"));
        assert_eq!(ns.repo_root, p);
        assert_eq!(ns.backlog_index, p.join(".radin/backlog/index.jsonl"));
        assert_eq!(ns.backlog_tasks_dir, p.join(".radin/backlog/tasks"));
        assert!(ns.created);
        assert!(!p.join(".radin").exists());
        ns.ensure_dirs().unwrap();
        for d in ["state/facts", "plans", "reviews", "backlog/tasks"] {
            assert!(p.join(".radin").join(d).is_dir(), "{d}");
        }
        assert!(!Namespace::locate(&p).created);
    }

    #[test]
    fn a_users_linked_worktree_keeps_its_own_namespace() {
        let (_t, w) = work();
        let p = proj(&w);
        fs::create_dir(p.join(".radin")).unwrap();
        git_in(
            &p,
            &[
                "worktree",
                "add",
                "-q",
                w.join("proj-wt").to_str().unwrap(),
                "-b",
                "feature",
            ],
        );
        let ns = Namespace::locate(&w.join("proj-wt"));
        assert_eq!(ns.repo_root, w.join("proj-wt"));
        assert_eq!(
            ns.backlog_index,
            w.join("proj-wt/.radin/backlog/index.jsonl")
        );
    }

    #[test]
    fn a_radin_task_worktree_resolves_to_the_checkout_that_prepared_it() {
        let (_t, w) = work();
        let p = proj(&w);
        git_in(
            &p,
            &[
                "worktree",
                "add",
                "-q",
                w.join("proj-wt").to_str().unwrap(),
                "-b",
                "feature",
            ],
        );
        fs::create_dir(w.join("proj-wt/.radin")).unwrap();
        let task = w.join("proj-wt-fix-a");
        git_in(
            &w.join("proj-wt"),
            &[
                "worktree",
                "add",
                "-q",
                task.to_str().unwrap(),
                "-b",
                "radin/fix-a",
            ],
        );
        let ns = Namespace::locate(&task);
        assert_eq!(ns.repo_root, w.join("proj-wt"));
        assert_eq!(
            ns.backlog_index,
            w.join("proj-wt/.radin/backlog/index.jsonl")
        );
        assert!(!task.join(".claude").exists());
    }

    #[test]
    fn task_worktree_without_a_parent_namespace_keeps_its_own_root() {
        let (_t, w) = work();
        let p = proj(&w);
        let task = w.join("proj-fix-a");
        git_in(
            &p,
            &[
                "worktree",
                "add",
                "-q",
                task.to_str().unwrap(),
                "-b",
                "radin/fix-a",
            ],
        );
        assert_eq!(Namespace::locate(&task).repo_root, task);
    }

    #[test]
    fn falls_back_to_cwd_outside_git() {
        let (_t, w) = work();
        let plain = w.join("plain dir");
        fs::create_dir(&plain).unwrap();
        let ns = Namespace::locate(&plain);
        assert_eq!(ns.repo_root, plain);
        assert_eq!(ns.namespace_dir, plain.join(".radin"));
    }
}

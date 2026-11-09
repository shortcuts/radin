use super::git::{branch_worktree, commit_dirty, dirty_files, g, gt, ok, wip_commit};
use super::plan_cover::plan_covers_file;
use super::store::get;
use super::{die, S};
use crate::backlog::Fail;
use std::path::{Path, PathBuf};

pub struct Routed {
    /// (task id, files moved onto its branch)
    pub to_tasks: Vec<(String, usize)>,
    pub main_hash: Option<String>,
}

struct Cand {
    id: String,
    branch: String,
    dir: PathBuf,
    plan: Vec<String>,
}

/// Dirty paths of `dir`; a rename or copy entry is skipped so main takes it whole.
fn single_paths(dir: &Path) -> Vec<String> {
    let raw = gt(
        dir,
        &[
            "status",
            "--porcelain",
            "-z",
            "--untracked-files=all",
            "--",
            ".",
            ":(exclude).radin",
        ],
    );
    let mut parts = raw.split('\0');
    let mut out = Vec::new();
    while let Some(e) = parts.next() {
        if e.len() < 4 {
            continue;
        }
        if e.starts_with(['R', 'C']) || e[1..2].starts_with(['R', 'C']) {
            parts.next();
        } else {
            out.push(e[3..].to_string());
        }
    }
    out
}

/// Branches with a live worktree whose task has no running leaf and no uncommitted work.
fn candidates(s: &S) -> Vec<Cand> {
    let worktrees = s.gt(&["worktree", "list", "--porcelain"]);
    s.radin_branches()
        .into_iter()
        .filter_map(|branch| {
            let id = branch.trim_start_matches("radin/").to_string();
            let running = s.steps.is_file()
                && s.entry(&id)
                    .is_some_and(|e| get(&e, "status") == "in_progress");
            let wt = branch_worktree(&worktrees, &branch);
            (!running
                && !wt.is_empty()
                && Path::new(&wt).is_dir()
                && dirty_files(Path::new(&wt)).is_empty())
            .then(|| Cand {
                plan: s.plan_files(&id),
                dir: PathBuf::from(wt),
                id,
                branch,
            })
        })
        .collect()
}

/// Copies `file` from main into `c`'s worktree, or deletes it there when main deleted it.
fn copy_over(root: &Path, c: &Cand, file: &str) -> bool {
    let (from, to) = (root.join(file), c.dir.join(file));
    if !from.exists() {
        return !to.exists() || std::fs::remove_file(&to).is_ok();
    }
    to.parent()
        .is_none_or(|p| std::fs::create_dir_all(p).is_ok())
        && std::fs::copy(from, to).is_ok()
}

/// Drops `file` from main after its bytes sit in a commit.
fn clean_main(root: &Path, file: &str) {
    g(root, &["reset", "-q", "--", file]);
    if ok(root, &["cat-file", "-e", &format!("HEAD:{file}")]) {
        g(root, &["checkout", "HEAD", "--", file]);
    } else {
        let _ = std::fs::remove_file(root.join(file));
    }
}

/// Undoes a failed move inside the task worktree.
fn clean_task(c: &Cand, file: &str) {
    g(&c.dir, &["reset", "-q", "--", file]);
    if ok(&c.dir, &["cat-file", "-e", &format!("HEAD:{file}")]) {
        g(&c.dir, &["checkout", "HEAD", "--", file]);
    } else {
        let _ = std::fs::remove_file(c.dir.join(file));
    }
}

/// Moves dirty files that one idle task's plan names onto its branch, then commits the rest in main.
pub fn route(s: &S, why: &str) -> Result<Routed, Fail> {
    let files = single_paths(&s.root);
    let cands = candidates(s);
    let mut moves: Vec<(usize, String)> = Vec::new();
    for f in files {
        let mut hit = cands
            .iter()
            .enumerate()
            .filter(|(_, c)| plan_covers_file(&s.root, &f, &c.plan));
        if let (Some((i, c)), None) = (hit.next(), hit.next()) {
            if ok(&s.root, &["diff", "--quiet", "HEAD", &c.branch, "--", &f]) {
                moves.push((i, f));
            }
        }
    }
    let mut to_tasks = Vec::new();
    for (i, c) in cands.iter().enumerate() {
        let mine: Vec<&String> = moves.iter().filter(|m| m.0 == i).map(|m| &m.1).collect();
        if mine.is_empty() {
            continue;
        }
        let before = gt(&c.dir, &["rev-parse", "HEAD"]);
        let copied: Vec<&String> = mine
            .iter()
            .copied()
            .filter(|f| copy_over(&s.root, c, f))
            .collect();
        let hash = wip_commit(
            &c.dir,
            &c.id,
            "Left uncommitted in the main checkout; radin moved it onto this task.",
        );
        if gt(&c.dir, &["rev-parse", "HEAD"]) == before {
            copied.iter().for_each(|f| clean_task(c, f));
            continue;
        }
        copied.iter().for_each(|f| clean_main(&s.root, f));
        s.journal(
            "wip-commit",
            &c.id,
            &format!(
                "{hash} on {} -- leftover files from the main checkout",
                c.branch
            ),
        );
        to_tasks.push((c.id.clone(), copied.len()));
    }
    let mut main_hash = None;
    if !dirty_files(&s.root).is_empty() {
        if !commit_dirty(&s.root, why) {
            return Err(die("cannot commit the dirty main checkout"));
        }
        let r = s.gt(&["rev-parse", "--short", "HEAD"]);
        s.journal(
            "wip-commit",
            "",
            &format!("{r} in {} -- left in the main checkout", s.root.display()),
        );
        main_hash = Some(r);
    }
    Ok(Routed {
        to_tasks,
        main_hash,
    })
}

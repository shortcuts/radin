use super::git::{branch_worktree, commit_dirty, dirty_files, g, gt, gx, ok, wip_commit};
use super::leftover;
use super::store::{self, get, json_escape};
use super::{arg, die, mkdir, write, S};
use crate::backlog::{Fail, Io, R};
use std::fmt::Write;
use std::path::Path;

impl S<'_> {
    /// The unmerged dependency of `id` whose branch holds every other unmerged dependency's tip.
    pub fn stack_parent(&self, id: &str) -> String {
        let deps = self
            .entry(id)
            .map(|e| store::deps_csv(&e))
            .unwrap_or_default();
        let cands: Vec<&str> = deps
            .split(',')
            .filter(|d| {
                !d.is_empty()
                    && self.completed_get(d).is_none()
                    && self.exists(&format!("unmerged/{d}"))
                    && self.branch_exists(&format!("radin/{d}"))
            })
            .collect();
        cands
            .iter()
            .find(|c| {
                cands.iter().all(|o| {
                    self.git_ok(&[
                        "merge-base",
                        "--is-ancestor",
                        &format!("radin/{o}"),
                        &format!("radin/{c}"),
                    ])
                })
            })
            .map_or_else(String::new, |c| c.to_string())
    }

    fn stack_depth(&self, id: &str) -> usize {
        let (mut d, mut id) = (0, id.to_string());
        while d < 1000 {
            let p = self
                .read(&format!("stacked/{id}"))
                .split(' ')
                .next()
                .unwrap_or("")
                .trim()
                .to_string();
            if p.is_empty() || !self.branch_exists(&format!("radin/{p}")) {
                break;
            }
            d += 1;
            id = p;
        }
        d
    }
}

fn must(ok: bool) -> Result<(), Fail> {
    if ok {
        Ok(())
    } else {
        Err(Fail {
            code: 1,
            msg: String::new(),
        })
    }
}

fn prepare_commit(s: &S, dir: &Path, id: &str, io: &mut Io) -> Result<(), Fail> {
    if dirty_files(dir).is_empty() {
        return Ok(());
    }
    if !commit_dirty(
        dir,
        &format!("radin committed these before task {id} started. Amend or split as needed."),
    ) {
        return Err(die(format!(
            "cannot commit the uncommitted changes in {}",
            dir.display()
        )));
    }
    let r = gt(dir, &["rev-parse", "--short", "HEAD"]);
    s.journal(
        "wip-commit",
        id,
        &format!(
            "{r} in {} -- uncommitted before task {id} started",
            dir.display()
        ),
    );
    let _ = writeln!(
        io.err,
        "radin: committed uncommitted changes in {} as {r} before task {id}",
        dir.display()
    );
    Ok(())
}

fn apply_claim(s: &S, dir: &Path, id: &str, io: &mut Io) {
    let rel = format!("stash-claims/{id}");
    let h = s.read(&rel).trim().to_string();
    if h.is_empty() {
        return;
    }
    let claim = s.state.join(&rel);
    let mv = |ext: &str| {
        let _ = std::fs::rename(&claim, s.state.join(format!("{rel}.{ext}")));
    };
    if ok(dir, &["stash", "apply", &h]) {
        mv("applied");
        s.journal("stash-apply", id, &h);
        let _ = writeln!(
            io.err,
            "radin: applied stash {h} into {} as the base of task {id}",
            dir.display()
        );
    } else {
        g(dir, &["reset", "--hard", "-q"]);
        g(dir, &["clean", "-fdq", "-e", ".radin"]);
        mv("failed");
        s.journal("stash-apply-failed", id, &h);
        let _ = writeln!(
            io.err,
            "radin: stash {h} did not apply to {}; the tree starts clean",
            dir.display()
        );
    }
}

fn restack(s: &S, id: &str, parent: &str, io: &mut Io) -> Result<(), Fail> {
    let (branch, start) = (format!("radin/{id}"), format!("radin/{parent}"));
    let is_ancestor = |a: &str, b: &str| s.git_ok(&["merge-base", "--is-ancestor", a, b]);
    if !is_ancestor(&start, &branch) {
        if !is_ancestor(&branch, &start) {
            let _ = writeln!(io.err, "prepare: {branch} does not contain {start}");
            s.journal(
                "stack-missed",
                id,
                &format!("{branch} does not contain {start}"),
            );
            return Ok(());
        }
        must(gx(&s.root, &["branch", "-f", &branch, &start], io))?;
    }
    if s.read(&format!("stacked/{id}")).is_empty() {
        mkdir(s, "stacked");
        let tip = s.gt(&["rev-parse", "--short=12", &start]);
        write(s, &format!("stacked/{id}"), &format!("{parent} {tip}\n"));
    }
    Ok(())
}

pub fn prepare(s: &S, a: &[String], io: &mut Io) -> R {
    let id = arg(a, 0);
    if id.is_empty() {
        return Err(die("usage: prepare <id>"));
    }
    let Some((worktree, branch_mode)) = s.session_get() else {
        return Err(die(format!("no recorded worktree/branch preference in {}/state/session.json -- run session-set first", s.ns.display())));
    };
    let branch = format!("radin/{id}");
    let wt = s.task_dir_path(id);
    let parent = s.stack_parent(id);
    let start = if parent.is_empty() {
        String::new()
    } else {
        format!("radin/{parent}")
    };
    let mut made = false;
    let mut wt_record = String::new();
    let wts = wt.to_string_lossy().into_owned();
    let res: Result<(), Fail> = (|| {
        let reuses = if worktree == "yes" {
            !wt.is_dir()
        } else {
            branch_mode == "yes"
        };
        if reuses && !parent.is_empty() && s.branch_exists(&branch) {
            restack(s, id, &parent, io)?;
        }
        if worktree == "yes" {
            if wt.is_dir() {
                if !s.is_registered_worktree(&wt) {
                    return Err(die(format!(
                        "{wts} exists but is not a registered worktree of this repo"
                    )));
                }
                prepare_commit(s, &wt, id, io)?;
            } else if s.branch_exists(&branch) {
                must(gx(&s.root, &["worktree", "add", &wts, &branch], io))?;
            } else {
                let mut args = vec!["worktree", "add", &wts, "-b", &branch];
                if !start.is_empty() {
                    args.push(&start);
                }
                must(gx(&s.root, &args, io))?;
                made = true;
            }
            s.journal("prepare", id, &format!("worktree={wts} branch={branch}"));
            wt_record = wts.clone();
        } else {
            prepare_commit(s, &s.root, id, io)?;
            if branch_mode == "yes" {
                if s.branch_exists(&branch) {
                    must(gx(&s.root, &["checkout", &branch], io))?;
                } else {
                    let mut args = vec!["checkout", "-b", &branch];
                    if !start.is_empty() {
                        args.push(&start);
                    }
                    must(gx(&s.root, &args, io))?;
                    made = true;
                }
                s.journal("prepare", id, &format!("branch={branch}"));
            } else {
                s.journal("prepare", id, "current checkout, current branch");
            }
        }
        Ok(())
    })();
    res?;
    let dir = if wt_record.is_empty() {
        s.root.clone()
    } else {
        wt.clone()
    };
    if made {
        s.rm(&format!("stacked/{id}"));
        if !parent.is_empty() {
            mkdir(s, "stacked");
            write(
                s,
                &format!("stacked/{id}"),
                &format!("{parent} {}\n", s.gt(&["rev-parse", "--short=12", &start])),
            );
        }
    }
    apply_claim(s, &dir, id, io);
    mkdir(s, "prepared");
    let real = gt(&dir, &["rev-parse", "--abbrev-ref", "HEAD"]);
    write(
        s,
        &format!("prepared/{id}.json"),
        &format!(
            "{{\"branch\":\"{}\",\"worktree\":\"{}\"}}\n",
            json_escape(&real),
            json_escape(&wt_record)
        ),
    );
    let _ = writeln!(io.out, "{}", dir.display());
    Ok(0)
}

impl S<'_> {
    fn task_dir_path(&self, id: &str) -> std::path::PathBuf {
        let mut p = self.root.as_os_str().to_owned();
        p.push(format!("-{id}"));
        p.into()
    }

    /// Git lists a worktree by its real path, so both sides are canonicalized.
    fn is_registered_worktree(&self, wt: &Path) -> bool {
        let want = std::fs::canonicalize(wt).ok();
        self.gt(&["worktree", "list", "--porcelain"])
            .lines()
            .filter_map(|l| l.strip_prefix("worktree "))
            .any(|p| std::fs::canonicalize(p).ok() == want)
    }
}

fn drop_branch(s: &S, id: &str, branch: &str, wt: &str, io: &mut Io) {
    if !wt.is_empty() && Path::new(wt).is_dir() && !gx(&s.root, &["worktree", "remove", wt], io) {
        let _ = writeln!(
            io.err,
            "merge: kept {branch}, worktree {wt} would not remove"
        );
        s.journal(
            "merge-kept",
            id,
            &format!("branch {branch} kept, worktree {wt} would not remove"),
        );
        return;
    }
    if !gx(&s.root, &["branch", "-D", branch], io) {
        let _ = writeln!(io.err, "merge: kept {branch}, branch -D failed");
        s.journal(
            "merge-kept",
            id,
            &format!("branch {branch} kept, branch -D failed"),
        );
    }
}

/// Files a follow-up for task `id` whose unfinished work landed at `hash`, and points its dependents at it.
fn follow_up(s: &S, id: &str, hash: &str, io: &mut Io) -> bool {
    let mark = format!("landing/{id}.follow-up");
    if !s.read(&mark).is_empty() {
        return true;
    }
    let Some(row) = s.find_row(id) else {
        return false;
    };
    let (note, reason) = match s.entry(id).filter(|_| s.steps.is_file()) {
        Some(e) => (get(&e, "note"), get(&e, "reason")),
        None => Default::default(),
    };
    let mut body = format!(
        "Task {id} stopped unfinished. Its branch landed on the base at {hash}, so no work stays on a side branch. Finish what it left. `radin state trace {id}` names its plan and facts.\n\n**Why unfinished:** {}",
        if note.is_empty() { "no reason recorded" } else { &note }
    );
    if reason == "deferred" {
        body += &format!("\n**Open decision:** {note}");
    }
    let (code, out, _) = s.bl(
        &["add", &row[1], &format!("Finish: {}", row[2])],
        &format!("{body}\n"),
    );
    if code != 0 {
        return false;
    }
    let fid = out.trim_end_matches('\n').to_string();
    mkdir(s, "landing");
    write(s, &mark, &format!("{fid}\n"));
    for l in s
        .bl_ok(&["list", "--order", "created"])
        .unwrap_or_default()
        .lines()
    {
        let f: Vec<&str> = l.split('\u{1f}').collect();
        let deps = f.get(5).copied().unwrap_or("");
        if deps.split(',').any(|d| d == id) {
            let new: Vec<&str> = deps
                .split(',')
                .map(|d| if d == id { fid.as_str() } else { d })
                .collect();
            s.bl(&["set-deps", f[0], &new.join(",")], "");
        }
    }
    s.journal("follow-up", id, &fid);
    let _ = writeln!(io.out, "follow-up\t{id}\t{fid}");
    true
}

fn record_landed(s: &S, id: &str, hash: &str, io: &mut Io) -> bool {
    if !s.exists(&format!("unmerged/{id}")) {
        if s.find_row(id).is_none() {
            s.rm(&format!("landing/{id}"));
            s.rm(&format!("conflict/{id}"));
            return true;
        }
        if !follow_up(s, id, hash, io) {
            let _ = writeln!(
                io.err,
                "merge: landed {id} but could not file its follow-up, it stays on the backlog"
            );
            return false;
        }
    }
    mkdir(s, "prepared");
    s.touch(&format!("prepared/{id}.merged"));
    let mut d = Io::default();
    let r = super::done::task_done(s, id, hash, &mut d);
    io.err.push_str(&d.out);
    io.err.push_str(&d.err);
    if matches!(r, Ok(0)) {
        for rel in [
            format!("unmerged/{id}"),
            format!("landing/{id}"),
            format!("landing/{id}.follow-up"),
            format!("conflict/{id}"),
            format!("stacked/{id}"),
        ] {
            s.rm(&rel);
        }
        true
    } else {
        if let Err(e) = r {
            io.err.push_str(&e.msg);
        }
        let _ = writeln!(
            io.err,
            "merge: landed {id} but could not record it done, it stays blocked"
        );
        s.journal(
            "done-unmerged",
            id,
            "merged into the base but task-done failed",
        );
        false
    }
}

fn squash_merge_one(s: &S, id: &str, branch: &str, wt: &str, tip: &str, io: &mut Io) -> bool {
    let subject = s.gt(&["log", "-1", "--format=%s", branch]);
    if !(gx(&s.root, &["merge", "--squash", branch], io)
        && gx(&s.root, &["commit", "-q", "-m", &subject], io))
    {
        gx(&s.root, &["reset", "--merge"], io);
        let _ = writeln!(io.out, "conflict\t{branch}");
        return false;
    }
    let _ = writeln!(io.out, "merged\t{branch}\t{tip}");
    record_landed(s, id, &s.gt(&["rev-parse", "--short=12", "HEAD"]), io);
    drop_branch(s, id, branch, wt, io);
    true
}

pub fn reconcile(s: &S, io: &mut Io) -> R {
    let base = s.resolve_base();
    if base.is_empty() {
        return Ok(0);
    }
    for dir in ["unmerged", "landing", "conflict"] {
        for (uid, path) in s.files_in(dir) {
            if uid.ends_with(".follow-up") || !path.is_file() {
                continue;
            }
            let uhash = std::fs::read_to_string(&path)
                .unwrap_or_default()
                .trim_end_matches('\n')
                .to_string();
            if s.branch_exists(&format!("radin/{uid}")) {
                continue;
            }
            if s.exists(&format!("conflict/{uid}")) || s.landed(&uhash, &base) {
                if record_landed(s, &uid, &uhash, io) {
                    let _ = writeln!(io.out, "adopted\tradin/{uid}");
                }
            } else if s.git_ok(&[
                "rev-parse",
                "--verify",
                "-q",
                &format!("{uhash}^{{commit}}"),
            ]) {
                gx(&s.root, &["branch", &format!("radin/{uid}"), &uhash], io);
                let _ = writeln!(io.out, "restored\tradin/{uid}\t{uhash}");
            } else {
                let _ = writeln!(io.out, "skipped\tradin/{uid}\tcommit {uhash} is gone");
            }
        }
    }
    if s.radin_branches().is_empty() {
        return Ok(0);
    }
    let routed = leftover::route(
        s,
        "radin committed these so the landing is not blocked. Amend or split as needed.",
    )?;
    for (id, n) in &routed.to_tasks {
        let _ = writeln!(io.out, "committed\t{id}\t{n} files moved to radin/{id}");
    }
    if let Some(r) = routed.main_hash {
        let _ = writeln!(
            io.out,
            "committed\t-\tbase checkout was dirty, saved as {r}"
        );
    }
    if !gx(&s.root, &["checkout", "-q", &base], io) {
        return Err(die(format!("cannot check out {base}")));
    }
    let worktrees = s.gt(&["worktree", "list", "--porcelain"]);
    let mut order: Vec<(usize, String)> = s
        .radin_branches()
        .into_iter()
        .map(|b| (s.stack_depth(b.trim_start_matches("radin/")), b))
        .collect();
    order.sort_by_key(|(d, _)| *d);
    let (mut merged, mut conflicts): (Vec<String>, Vec<String>) = (Vec::new(), Vec::new());
    for (_, rb) in order {
        let rid = rb.trim_start_matches("radin/").to_string();
        if s.steps.is_file()
            && s.entry(&rid)
                .is_some_and(|e| get(&e, "status") == "in_progress")
        {
            let _ = writeln!(io.out, "skipped\t{rb}\tin progress");
            continue;
        }
        let wt = branch_worktree(&worktrees, &rb);
        let wt_dir =
            (!wt.is_empty() && Path::new(&wt).is_dir()).then(|| Path::new(&wt).to_path_buf());
        if let Some(d) = &wt_dir {
            if !dirty_files(d).is_empty() {
                wip_commit(
                    d,
                    &rid,
                    &format!("Left uncommitted in {wt}; reconcile landed it."),
                );
            }
        }
        let stacked = format!("stacked/{rid}");
        if s.state.join(&stacked).is_file() {
            let mark = s.read(&stacked);
            let mut f = mark.split_whitespace();
            let (sparent, sbase) = (f.next().unwrap_or(""), f.next().unwrap_or(""));
            if s.branch_exists(&format!("radin/{sparent}")) {
                let _ = writeln!(io.out, "skipped\t{rb}\twaiting on radin/{sparent}");
                continue;
            }
            let rdir = wt_dir.clone().unwrap_or_else(|| s.root.clone());
            if gx(&rdir, &["rebase", "--onto", &base, sbase, &rb], io) {
                s.rm(&stacked);
                gx(&s.root, &["checkout", "-q", &base], io);
            } else {
                gx(&rdir, &["rebase", "--abort"], io);
                gx(&s.root, &["checkout", "-q", &base], io);
                mkdir(s, "conflict");
                write(
                    s,
                    &format!("conflict/{rid}"),
                    &format!("{}\n", s.gt(&["rev-parse", "--short=12", &rb])),
                );
                let _ = writeln!(io.out, "conflict\t{rb}");
                conflicts.push(rb);
                continue;
            }
        }
        let tip = s.gt(&["rev-parse", "--short=12", &rb]);
        if s.landed(&tip, &base) {
            let ahead: u64 = s
                .gt(&["rev-list", "--count", &format!("{base}..{rb}")])
                .parse()
                .unwrap_or(0);
            if s.exists(&format!("unmerged/{rid}")) || ahead > 0 {
                record_landed(s, &rid, &tip, io);
            }
            drop_branch(s, &rid, &rb, &wt, io);
            let _ = writeln!(io.out, "removed\t{rb}");
            continue;
        }
        if !s.exists(&format!("unmerged/{rid}")) {
            mkdir(s, "landing");
            write(s, &format!("landing/{rid}"), &format!("{tip}\n"));
        }
        if squash_merge_one(s, &rid, &rb, &wt, &tip, io) {
            merged.push(rb);
        } else {
            mkdir(s, "conflict");
            write(s, &format!("conflict/{rid}"), &format!("{tip}\n"));
            conflicts.push(rb);
        }
    }
    gx(&s.root, &["worktree", "prune"], io);
    s.journal(
        "reconcile",
        "",
        &format!(
            "merged={} conflict={}",
            merged.join(","),
            conflicts.join(",")
        ),
    );
    Ok(if conflicts.is_empty() { 0 } else { 3 })
}

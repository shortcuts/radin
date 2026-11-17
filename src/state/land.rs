use super::git::{branch_worktree, commit_dirty, dirty_files, g, gt, gx, ok, wip_commit};
use super::leftover;
use super::store::get;
use super::{arg, die, S};
use crate::backlog::{Fail, Io, R};
use std::fmt::Write;
use std::path::Path;

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

pub(super) fn prepare_commit(s: &S, dir: &Path, id: &str, io: &mut Io) -> Result<(), Fail> {
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

/// The lane's worktree on `radin/<lane>`, created or verified as registered.
pub(super) fn ensure_lane_tree(s: &S, lane: &str, io: &mut Io) -> Result<std::path::PathBuf, Fail> {
    let (branch, wt) = (format!("radin/{lane}"), s.lane_dir_path(lane));
    let wts = wt.to_string_lossy().into_owned();
    if wt.is_dir() {
        if !s.is_registered_worktree(&wt) {
            return Err(die(format!(
                "{wts} exists but is not a registered worktree of this repo"
            )));
        }
    } else if s.branch_exists(&branch) {
        must(gx(&s.root, &["worktree", "add", &wts, &branch], io))?;
    } else {
        must(gx(&s.root, &["worktree", "add", &wts, "-b", &branch], io))?;
    }
    Ok(wt)
}

/// Records the lane HEAD before a task's first attempt; a retry keeps the original.
fn record_lane_base(s: &S, dir: &Path, id: &str) {
    let rel = format!("lane-base/{id}");
    let old = s.read(&rel);
    let old = old.trim();
    if old.is_empty() || !ok(dir, &["merge-base", "--is-ancestor", old, "HEAD"]) {
        s.set_marker(id, &rel, &format!("{}\n", gt(dir, &["rev-parse", "HEAD"])));
    }
}

/// Merges a parked task's `radin/wip/<id>` back into its lane tree.
fn resume_wip(s: &S, dir: &Path, id: &str, io: &mut Io) -> Result<(), Fail> {
    let wip = format!("radin/wip/{id}");
    if !s.branch_exists(&wip) {
        return Ok(());
    }
    let msg = format!("resume {id} from {wip}");
    if !gx(
        dir,
        &[
            "merge",
            "--no-ff",
            "--no-verify",
            "--no-edit",
            "-m",
            &msg,
            &wip,
        ],
        io,
    ) {
        g(dir, &["merge", "--abort"]);
        return Err(die(format!(
            "resume of {id} from {wip} conflicts with the lane"
        )));
    }
    g(&s.root, &["branch", "-D", &wip]);
    s.journal("resume", id, &wip);
    Ok(())
}

pub fn prepare(s: &S, a: &[String], io: &mut Io) -> R {
    let id = arg(a, 0);
    if id.is_empty() {
        return Err(die("usage: prepare <id>"));
    }
    let dir = if s.lane_mode() == "lanes" {
        let lane = super::lanes::task_epic(s, id)?;
        let wt = ensure_lane_tree(s, &lane, io)?;
        if super::park::merge_in_progress(&wt) {
            return Err(die(format!(
                "lane {lane} has a merge in progress; run state lane-sync {id}"
            )));
        }
        prepare_commit(s, &wt, id, io)?;
        record_lane_base(s, &wt, id);
        resume_wip(s, &wt, id, io)?;
        s.journal(
            "prepare",
            id,
            &format!("worktree={} branch=radin/{lane}", wt.display()),
        );
        wt
    } else {
        prepare_commit(s, &s.root, id, io)?;
        resume_wip(s, &s.root, id, io)?;
        s.journal("prepare", id, "current checkout, current branch");
        s.root.clone()
    };
    apply_claim(s, &dir, id, io);
    let _ = writeln!(io.out, "{}", dir.display());
    Ok(0)
}

impl S<'_> {
    pub(super) fn lane_dir_path(&self, lane: &str) -> std::path::PathBuf {
        let mut p = self.root.as_os_str().to_owned();
        p.push(format!("-{lane}"));
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

pub(super) fn drop_branch(s: &S, id: &str, branch: &str, wt: &str, io: &mut Io) {
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
        &[
            "add",
            &row[1],
            &format!("Finish: {}", row[2]),
            "--origin",
            id,
        ],
        &format!("{body}\n"),
    );
    if code != 0 {
        return false;
    }
    let fid = out.trim_end_matches('\n').to_string();
    s.set_marker(id, &mark, &format!("{fid}\n"));
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

fn finished_on_branch(s: &S, id: &str) -> bool {
    super::branches::last_event(s, id, &["done-unmerged", "in_progress", "done"]).as_deref()
        == Some("done-unmerged")
}

fn record_landed(s: &S, id: &str, hash: &str, io: &mut Io) -> bool {
    let clear = |s: &S| {
        for rel in [
            format!("landing/{id}"),
            format!("landing/{id}.follow-up"),
            format!("conflict/{id}"),
        ] {
            s.clear_marker(id, &rel);
        }
    };
    if !finished_on_branch(s, id) {
        if s.find_row(id).is_none() {
            clear(s);
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
    let mut d = Io::default();
    let r = super::done::record_done(s, id, hash, &mut d);
    io.err.push_str(&d.out);
    io.err.push_str(&d.err);
    if matches!(r, Ok(0)) {
        clear(s);
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

/// Commits a dirty root checkout and checks out the base, so a merge into it starts clean.
pub(super) fn settle_checkout(s: &S, base: &str, io: &mut Io) -> Result<(), Fail> {
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
    if !gx(&s.root, &["checkout", "-q", base], io) {
        return Err(die(format!("cannot check out {base}")));
    }
    Ok(())
}

pub fn reconcile(s: &S, io: &mut Io) -> R {
    let base = s.resolve_base();
    if base.is_empty() {
        return Ok(0);
    }
    for dir in ["landing", "conflict"] {
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
                    s.journal("reconcile-adopted", &uid, &format!("radin/{uid}"));
                }
            } else if s.git_ok(&[
                "rev-parse",
                "--verify",
                "-q",
                &format!("{uhash}^{{commit}}"),
            ]) {
                gx(&s.root, &["branch", &format!("radin/{uid}"), &uhash], io);
                let _ = writeln!(io.out, "restored\tradin/{uid}\t{uhash}");
                s.journal("reconcile-restored", &uid, &format!("radin/{uid} {uhash}"));
            } else {
                let _ = writeln!(io.out, "skipped\tradin/{uid}\tcommit {uhash} is gone");
                s.journal(
                    "reconcile-skipped",
                    &uid,
                    &format!("commit {uhash} is gone"),
                );
            }
        }
    }
    if s.radin_branches().is_empty() {
        return Ok(0);
    }
    settle_checkout(s, &base, io)?;
    let worktrees = s.gt(&["worktree", "list", "--porcelain"]);
    let lanes = super::lanes::lane_names(s)?;
    let (mut merged, mut conflicts): (Vec<String>, Vec<String>) = (Vec::new(), Vec::new());
    for rb in s.radin_branches() {
        let rid = rb.trim_start_matches("radin/").to_string();
        if super::lanes::is_lane(s, &lanes, &rid) {
            let _ = writeln!(io.out, "skipped\t{rb}\tlane");
            continue;
        }
        if s.steps.is_file()
            && s.entry(&rid)
                .is_some_and(|e| get(&e, "status") == "in_progress")
        {
            let _ = writeln!(io.out, "skipped\t{rb}\tin progress");
            s.journal("reconcile-skipped", &rid, "in progress");
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
        let tip = s.gt(&["rev-parse", "--short=12", &rb]);
        if s.landed(&tip, &base) {
            let ahead: u64 = s
                .gt(&["rev-list", "--count", &format!("{base}..{rb}")])
                .parse()
                .unwrap_or(0);
            if finished_on_branch(s, &rid) || ahead > 0 {
                record_landed(s, &rid, &tip, io);
            }
            drop_branch(s, &rid, &rb, &wt, io);
            let _ = writeln!(io.out, "removed\t{rb}");
            continue;
        }
        s.set_marker(&rid, &format!("landing/{rid}"), &format!("{tip}\n"));
        if squash_merge_one(s, &rid, &rb, &wt, &tip, io) {
            merged.push(rb);
        } else {
            s.set_marker(&rid, &format!("conflict/{rid}"), &format!("{tip}\n"));
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

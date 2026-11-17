use super::git::{dirty_files, g, gt, gx, ok, stage_all};
use super::land::{ensure_lane_tree, prepare_commit};
use super::{arg, die, S};
use crate::backlog::{Fail, Io, R};
use std::fmt::Write;
use std::path::Path;

pub fn merge_in_progress(dir: &Path) -> bool {
    let p = gt(dir, &["rev-parse", "--git-path", "MERGE_HEAD"]);
    !p.is_empty() && dir.join(p).exists()
}

fn conflicted(dir: &Path) -> bool {
    !gt(dir, &["diff", "--name-only", "--diff-filter=U"]).is_empty()
}

/// Merges the base branch into the lane before a task; exit 3 leaves a conflicted merge for the merge agent.
pub fn lane_sync(s: &S, a: &[String], io: &mut Io) -> R {
    let id = arg(a, 0);
    let abort = arg(a, 1) == "--abort";
    if id.is_empty() || a.len() > 2 || (a.len() == 2 && !abort) {
        return Err(die("usage: lane-sync <id> [--abort]"));
    }
    if s.lane_mode() != "lanes" {
        return Ok(0);
    }
    let lane = super::lanes::task_epic(s, id)?;
    let dir = ensure_lane_tree(s, &lane, io)?;
    let mid = merge_in_progress(&dir);
    if abort {
        if mid {
            g(&dir, &["merge", "--abort"]);
            let _ = writeln!(io.out, "aborted\t{lane}");
        } else {
            let _ = writeln!(io.out, "current\t{lane}");
        }
        return Ok(0);
    }
    if mid {
        if conflicted(&dir) {
            let _ = writeln!(io.out, "conflict\t{lane}\t{}", dir.display());
            return Ok(3);
        }
        if !gx(&dir, &["commit", "--no-verify", "--no-edit"], io) {
            return Err(die(format!("cannot finish the merge in {}", dir.display())));
        }
        return synced(s, &dir, id, &lane, io);
    }
    let base = s.resolve_base();
    if base.is_empty() {
        let _ = writeln!(io.out, "skipped\t{lane}\tno base branch");
        return Ok(0);
    }
    if ok(&dir, &["merge-base", "--is-ancestor", &base, "HEAD"]) {
        let _ = writeln!(io.out, "current\t{lane}");
        return Ok(0);
    }
    prepare_commit(s, &dir, id, io)?;
    let msg = format!("merge {base} into radin/{lane}");
    if gx(
        &dir,
        &["merge", "--no-verify", "--no-edit", "-m", &msg, &base],
        io,
    ) {
        return synced(s, &dir, id, &lane, io);
    }
    if merge_in_progress(&dir) && conflicted(&dir) {
        s.journal("lane-sync-conflict", id, &format!("{base} into {lane}"));
        let _ = writeln!(io.out, "conflict\t{lane}\t{}", dir.display());
        return Ok(3);
    }
    g(&dir, &["merge", "--abort"]);
    Err(die(format!("cannot merge {base} into radin/{lane}")))
}

fn synced(s: &S, dir: &Path, id: &str, lane: &str, io: &mut Io) -> R {
    let h = gt(dir, &["rev-parse", "--short=12", "HEAD"]);
    s.journal("lane-sync", id, &format!("{lane} at {h}"));
    let _ = writeln!(io.out, "synced\t{lane}\t{h}");
    Ok(0)
}

/// Moves an unrecovered lane task's partial work to `radin/wip/<id>` and resets the lane to its pre-task commit.
pub fn park(s: &S, id: &str, reason: &str) -> Result<Option<String>, Fail> {
    if s.lane_mode() != "lanes" || s.prepared_field(id, "lane").is_empty() {
        return Ok(None);
    }
    let base = s.read(&format!("lane-base/{id}")).trim().to_string();
    let dir = s.task_dir(id);
    if base.is_empty() || dir == s.root {
        return Ok(None);
    }
    if dirty_files(&dir).is_empty() && gt(&dir, &["rev-parse", "HEAD"]) == base {
        s.rm(&format!("lane-base/{id}"));
        s.journal("park-none", id, "no work since the lane base");
        return Ok(None);
    }
    stage_all(&dir);
    let subject = format!("wip({id}): parked, {reason}");
    if !ok(
        &dir,
        &[
            "commit",
            "--allow-empty",
            "--no-verify",
            "-q",
            "-m",
            &subject,
        ],
    ) {
        return Err(die(format!("cannot commit the partial work of {id}")));
    }
    let wip = format!("radin/wip/{id}");
    if s.branch_exists(&wip) && !s.git_ok(&["merge-base", "--is-ancestor", &wip, "HEAD"]) {
        return Err(die(format!("{wip} exists and holds work HEAD lacks")));
    }
    let tip = gt(&dir, &["rev-parse", "HEAD"]);
    if !s.git_ok(&["branch", "-f", &wip, &tip]) || s.gt(&["rev-parse", &wip]) != tip {
        return Err(die(format!("cannot point {wip} at {tip}")));
    }
    if !ok(&dir, &["reset", "--hard", "-q", &base]) {
        return Err(die(format!("cannot reset {} to {base}", dir.display())));
    }
    s.rm(&format!("lane-base/{id}"));
    let tip = &tip[..12.min(tip.len())];
    s.journal(
        "park",
        id,
        &format!("branch={wip} tip={tip} reason={reason}"),
    );
    s.entry_note(id, &format!("parked on {wip}: {reason}"));
    Ok(Some(format!("parked\t{id}\t{wip}\t{tip}\n")))
}

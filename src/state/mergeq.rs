use super::git::{dirty_files, g, gt, gx};
use super::land::{ensure_lane_tree, settle_checkout};
use super::park::{merge_in_progress, sync_lane};
use super::{arg, die, write, S};
use crate::backlog::{Io, R};
use std::fmt::Write;

fn parse(text: &str) -> Vec<(String, String)> {
    text.lines()
        .filter_map(|l| l.split_once('\t'))
        .map(|(e, st)| (e.to_string(), st.to_string()))
        .collect()
}

fn read(s: &S) -> Vec<(String, String)> {
    parse(&s.read("merge-queue"))
}

fn save(s: &S, q: &[(String, String)]) {
    let text: String = q.iter().map(|(e, st)| format!("{e}\t{st}\n")).collect();
    write(s, "merge-queue", &text);
}

fn set(s: &S, epic: &str, status: &str) {
    let q: Vec<_> = read(s)
        .into_iter()
        .map(|(e, st)| {
            let st = if e == epic { status.to_string() } else { st };
            (e, st)
        })
        .collect();
    save(s, &q);
}

pub(super) fn status(s: &S, epic: &str) -> String {
    read(s)
        .into_iter()
        .find(|(e, _)| e == epic)
        .map(|(_, st)| st)
        .unwrap_or_default()
}

pub(super) fn remove(s: &S, epic: &str) {
    let q: Vec<_> = read(s).into_iter().filter(|(e, _)| e != epic).collect();
    save(s, &q);
}

fn base_of(s: &S) -> Result<String, crate::backlog::Fail> {
    let base = s.resolve_base();
    if base.is_empty() {
        return Err(die("no base branch"));
    }
    Ok(base)
}

/// A lane whose epic has no ready task joins the queue; a lane with nothing to merge is `merged` at once.
pub fn lane_queue(s: &S, a: &[String], io: &mut Io) -> R {
    let epic = arg(a, 0);
    if epic.is_empty() || a.len() > 1 {
        return Err(die("usage: lane-queue <epic>"));
    }
    if s.lane_mode() != "lanes" {
        return Ok(0);
    }
    let mut q = read(s);
    if let Some(i) = q.iter().position(|(e, _)| e == epic) {
        let _ = writeln!(io.out, "queued\t{epic}\t{}", i + 1);
        return Ok(0);
    }
    if let Some(why) = super::lanes::queue_blocker(s, epic)? {
        return Err(die(why));
    }
    let base = base_of(s)?;
    let branch = format!("radin/{epic}");
    let ahead = s.branch_exists(&branch)
        && s.gt(&["rev-list", "--count", &format!("{base}..{branch}")]) != "0";
    if !ahead {
        q.push((epic.to_string(), "merged".into()));
        save(s, &q);
        s.journal("lane-queue", "", &format!("{epic} empty"));
        let _ = writeln!(io.out, "empty\t{epic}");
        return Ok(0);
    }
    q.push((epic.to_string(), "queued".into()));
    save(s, &q);
    s.journal("lane-queue", "", &format!("{epic} position {}", q.len()));
    let _ = writeln!(io.out, "queued\t{epic}\t{}", q.len());
    Ok(0)
}

/// Merges the head lane into the base with `--no-ff`; exit 2 waits for the previous lane's `lane-done`, exit 3 hands a conflict to the sync agent.
pub fn lane_merge(s: &S, a: &[String], io: &mut Io) -> R {
    let abort = arg(a, 0) == "--abort";
    if a.len() > 1 || (a.len() == 1 && !abort) {
        return Err(die("usage: lane-merge [--abort]"));
    }
    if s.lane_mode() != "lanes" {
        return Ok(1);
    }
    let Some((epic, st)) = read(s).into_iter().find(|(_, st)| st != "held") else {
        return Ok(1);
    };
    if st == "merged" {
        let _ = writeln!(io.out, "waiting\t{epic}");
        return Ok(2);
    }
    let dir = ensure_lane_tree(s, &epic, io)?;
    if abort {
        if merge_in_progress(&dir) {
            g(&dir, &["merge", "--abort"]);
        }
        set(s, &epic, "held");
        s.journal("lane-held", "", &epic);
        let _ = writeln!(io.out, "held\t{epic}");
        return Ok(0);
    }
    if !merge_in_progress(&dir) && !dirty_files(&dir).is_empty() {
        return Err(die(format!("lane {epic} has uncommitted changes")));
    }
    let base = base_of(s)?;
    let mut sync = Io::default();
    let code = sync_lane(s, &dir, &epic, "", &mut sync)?;
    io.err.push_str(&sync.err);
    if code != 0 {
        io.out.push_str(&sync.out);
        return Ok(code);
    }
    settle_checkout(s, &base, io)?;
    let msg = format!("merge lane {epic}");
    let branch = format!("radin/{epic}");
    if !gx(
        &s.root,
        &[
            "merge",
            "--no-ff",
            "--no-verify",
            "--no-edit",
            "-m",
            &msg,
            &branch,
        ],
        io,
    ) {
        g(&s.root, &["merge", "--abort"]);
        return Err(die(format!("cannot merge {branch} into {base}")));
    }
    set(s, &epic, "merged");
    let h = gt(&s.root, &["rev-parse", "--short=12", "HEAD"]);
    s.journal("lane-merge", "", &format!("{epic} at {h}"));
    let _ = writeln!(io.out, "merged\t{epic}\t{h}");
    Ok(0)
}

#[cfg(test)]
mod tests {
    use super::parse;

    #[test]
    fn the_queue_keeps_file_order_and_drops_malformed_lines() {
        let q = parse("eb\tqueued\nbroken\nea\theld\n");
        assert_eq!(
            q,
            [("eb".into(), "queued".into()), ("ea".into(), "held".into())]
        );
    }
}

use super::git::{branch_worktree, dirty_files, g, gt};
use super::land::drop_branch;
use super::lanes::{is_lane, lane_names};
use super::mergeq::{base_of, enqueue, read, save, set};
use super::park::{merge_in_progress, park};
use super::{gate, mkdir, write, S};
use crate::backlog::{Io, R};
use std::fmt::Write;
use std::path::Path;

fn keep(s: &S, io: &mut Io, kept: &mut Vec<String>, epic: &str, why: &str) {
    if kept.iter().any(|k| k == epic) {
        return;
    }
    kept.push(epic.to_string());
    s.journal("lane-kept", epic, why);
    let _ = writeln!(io.out, "kept\tradin/{epic}\t{why}");
}

/// Rebuilds the merge queue after a dead session: parks unverified lane work, queues each lane branch, lists the wip tasks that resume.
pub fn lanes_recover(s: &S, io: &mut Io) -> R {
    let base = base_of(s)?;
    let names = lane_names(s)?;
    let branches: Vec<String> = s
        .radin_branches()
        .into_iter()
        .filter(|b| is_lane(s, &names, b.trim_start_matches("radin/")))
        .collect();
    let markers = s.files_in("lane-base");
    let wips = s.wip_branches();
    let rows = read(s);
    if branches.is_empty() && markers.is_empty() && wips.is_empty() && rows.is_empty() {
        return Ok(1);
    }
    if !(branches.is_empty() && markers.is_empty() && rows.is_empty()) {
        write(s, "lane-mode", "lanes\n");
    }
    let porcelain = s.gt(&["worktree", "list", "--porcelain"]);
    let tree = |b: &str| {
        let w = branch_worktree(&porcelain, b);
        (!w.is_empty() && Path::new(&w).is_dir()).then(|| Path::new(&w).to_path_buf())
    };
    for b in &branches {
        if let Some(d) = tree(b).filter(|d| merge_in_progress(d)) {
            g(&d, &["merge", "--abort"]);
            s.journal(
                "lane-recover-abort",
                b.trim_start_matches("radin/"),
                &d.to_string_lossy(),
            );
        }
    }
    let mut kept: Vec<String> = Vec::new();
    for (id, _) in &markers {
        match park(s, id, "session died") {
            Ok(Some(line)) => io.out.push_str(&line),
            Ok(None) => {}
            Err(e) => {
                let lane = s.prepared_field(id, "lane");
                keep(
                    s,
                    io,
                    &mut kept,
                    &lane,
                    e.msg.trim().trim_start_matches("radin-state: "),
                );
            }
        }
    }
    for b in &branches {
        let epic = b.trim_start_matches("radin/");
        if let Some(d) = tree(b).filter(|d| !dirty_files(d).is_empty()) {
            keep(
                s,
                io,
                &mut kept,
                epic,
                &format!("uncommitted changes in {}", d.display()),
            );
        }
    }
    let mut q: Vec<(String, String)> = rows
        .into_iter()
        .filter(|(e, st)| {
            st == "merged" || (s.branch_exists(&format!("radin/{e}")) && !kept.contains(e))
        })
        .map(|(e, st)| (e, if st == "held" { "queued".into() } else { st }))
        .collect();
    let mut fresh: Vec<(String, String)> = Vec::new();
    for b in &branches {
        let epic = b.trim_start_matches("radin/");
        if kept.iter().any(|k| k == epic) || q.iter().any(|(e, _)| e == epic) {
            continue;
        }
        if s.gt(&["rev-list", "--count", &format!("{base}..{b}")]) == "0" {
            let wt = tree(b)
                .map(|d| d.to_string_lossy().into_owned())
                .unwrap_or_default();
            drop_branch(s, "", b, &wt, io);
            let _ = writeln!(io.out, "dropped\t{b}");
        } else {
            fresh.push((s.gt(&["log", "-1", "--format=%ct", b]), epic.to_string()));
        }
    }
    fresh.sort();
    for (_, epic) in fresh {
        enqueue(&mut q, &epic, "queued");
    }
    save(s, &q);
    mkdir(s, "lanes");
    for (epic, _) in &q {
        write(s, &format!("lanes/{epic}"), "running\n");
    }
    for (epic, st) in q.clone() {
        let recorded = s
            .read(&format!("gate/{epic}"))
            .lines()
            .any(|l| l.starts_with("merge\t"));
        if st != "merged" || recorded || gate::state_of(s, &epic) != "run" {
            continue;
        }
        let found = gt(
            &s.root,
            &[
                "log",
                "--merges",
                "-1",
                "--format=%H",
                "--grep",
                &format!("^merge lane {epic}$"),
                &base,
            ],
        );
        if found.is_empty() {
            set(s, &epic, "queued");
        } else {
            gate::record_merge(s, &epic, &found[..12.min(found.len())]);
        }
    }
    for (id, _) in s.files_in("hotfix") {
        let lane = format!("hotfix-{id}");
        if s.read(&format!("hotfix/{id}")).trim() == "open"
            && !q.iter().any(|(e, _)| *e == lane)
            && !s.branch_exists(&format!("radin/{lane}"))
        {
            gate::close_hotfix(s, &id);
        }
    }
    for (i, (epic, st)) in read(s).iter().enumerate() {
        match st.as_str() {
            "merged" => {
                let _ = writeln!(io.out, "merged\t{epic}\t-");
            }
            _ => {
                let _ = writeln!(io.out, "queued\t{epic}\t{}", i + 1);
            }
        }
    }
    for w in &wips {
        let id = w.trim_start_matches("radin/wip/");
        if s.task_title(id).is_empty() {
            let _ = writeln!(io.out, "kept\t{w}\ttask is not on the backlog");
        } else {
            let _ = writeln!(io.out, "resume\t{id}\t{w}");
        }
    }
    s.journal(
        "lanes-recover",
        "",
        &format!("queued={} kept={} wip={}", q.len(), kept.len(), wips.len()),
    );
    Ok(0)
}

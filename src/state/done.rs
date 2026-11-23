use super::git::{dirty_files, g, ok, wip_commit};
use super::plan_cover::plan_extras;
use super::queue::{deps_check, release_ready};
use super::store::{self, get, json_escape, num, MAX_ATTEMPTS};
use super::{arg, die, mkdir, write, S};
use crate::backlog::{Fail, Io, R};
use std::fmt::Write;

fn first_line(s: &str) -> &str {
    s.lines().next().unwrap_or("")
}

/// True while the last `**Progress:**` or `**Decision:**` line of the task file records an owner deferral.
pub fn owner_deferred(s: &S, id: &str) -> bool {
    let Ok(path) = s.field(id, "TASK_FILE") else {
        return false;
    };
    let body = std::fs::read_to_string(path).unwrap_or_default();
    body.lines()
        .filter_map(|l| {
            l.strip_prefix("**Progress:**")
                .or_else(|| l.strip_prefix("**Decision:**"))
        })
        .next_back()
        .is_some_and(|t| t.trim_start().to_lowercase().starts_with("defer"))
}

pub fn task_next(s: &S, want: &str, lane: Option<&str>, io: &mut Io) -> R {
    if want.is_empty() && s.exists("teardown") {
        return Ok(1);
    }
    let lane_epics = match lane {
        Some(e) => {
            if s.read(&format!("lanes/{e}")).trim() != "running" {
                return Err(die(format!("lane {e} is not running")));
            }
            Some(super::lanes::epic_map(s)?)
        }
        None => None,
    };
    release_ready(s)?;
    loop {
        let (pid, order) = if want.is_empty() {
            let p = match (&lane_epics, lane) {
                (Some(m), Some(e)) => s.next_pending_in(m, e),
                _ => s.next_pending(),
            };
            match p {
                Some(p) => p,
                None => return Ok(1),
            }
        } else {
            (want.to_string(), num(&s.need_entry(want)?, "order"))
        };
        let skip = |io: &mut Io, msg: &str| {
            let _ = writeln!(io.out, "blocked\t{pid}\t{msg}");
        };
        let blocked = if let Some(m) = deps_check(s, &pid)?.1 {
            Some(("dependency", m))
        } else if let Err(e) = s.field(&pid, "TASK_FILE") {
            let e = first_line(&e);
            Some((
                "entry-gone",
                format!(
                    "backlog entry is gone: {}",
                    e.strip_prefix("radin-backlog: ").unwrap_or(e)
                ),
            ))
        } else {
            None
        };
        if let Some((reason, msg)) = blocked {
            s.set_blocked(&pid, reason, &msg)?;
            skip(io, &msg);
            if want.is_empty() {
                continue;
            }
            return Ok(1);
        }
        if want.is_empty() && owner_deferred(s, &pid) {
            s.set_blocked(
                &pid,
                "deferred",
                "owner deferral stands; state retry re-runs it",
            )?;
            continue;
        }
        let planning = s.field(&pid, "PLANNING").is_ok() && s.field(&pid, "PLAN_PATHS").is_err();
        let entry = s.need_entry(&pid)?;
        let claimed = if planning {
            let n = num(&entry, "attempts");
            s.claim(
                &pid,
                "pending",
                &format!("planning dispatch {} of {MAX_ATTEMPTS}", n + 1),
            )?
        } else {
            if get(&entry, "note").starts_with("planning dispatch") {
                s.write_entry(&pid, "pending", 0, "", None)?;
            }
            s.claim(&pid, "in_progress", "")?
        };
        if !claimed {
            skip(io, &format!("dispatched {MAX_ATTEMPTS} times without a terminal status (MAX_ATTEMPTS), marked blocked"));
            if want.is_empty() {
                continue;
            }
            return Ok(1);
        }
        let kind = if planning { "planning" } else { "execution" };
        if !planning {
            if let Ok(dropped) = s.field(&pid, "SKILLS_DROPPED") {
                let title = s.task_title(&pid);
                for inst in dropped.lines().filter(|l| !l.is_empty()) {
                    let t = if title.is_empty() { &pid } else { &title };
                    s.journal("skill-dropped", &pid, &format!("{t} — {inst}"));
                }
            }
        }
        let (code, prompt, err) = (s.c.cli)(&s.root, &["prompt", kind, &pid], "");
        if code != 0 {
            io.err.push_str(&err);
            return Ok(code);
        }
        let _ = writeln!(
            io.out,
            "id\t{pid}\norder\t{order}\nkind\t{kind}\n{}",
            prompt.trim_end_matches('\n')
        );
        return Ok(0);
    }
}

/// A leaf's "STATUS: <word> — [measured|inferred] <text>[; long form: <path>]" line, recorded as a labeled backlog line.
fn record_status_line(
    s: &S,
    word: &str,
    label: &str,
    id: &str,
    line: &str,
) -> Result<String, Fail> {
    let head = format!("STATUS: {word} — ");
    let Some(rest) = line.strip_prefix(&head) else {
        return Err(die(format!("not a 'STATUS: {word}' line: {line}")));
    };
    let (mut body, mut longform) = (rest.to_string(), String::new());
    if let Some(i) = rest.rfind("; long form: ") {
        body = rest[..i].to_string();
        longform = rest[i + "; long form: ".len()..].to_string();
    }
    if !(body.starts_with("[measured] ") || body.starts_with("[inferred] ")) {
        body = format!("[guess] {body}");
    }
    s.bl_must(&["append", id], &format!("**{label}:** {body}\n"))?;
    if !longform.is_empty() {
        s.bl_must(&["set-meta", id, "facts", &longform], "")?;
    }
    Ok(body)
}

pub fn task_fact(s: &S, a: &[String], io: &mut Io) -> R {
    let (id, line) = (arg(a, 0), arg(a, 1));
    if id.is_empty() || line.is_empty() {
        return Err(die("usage: task-fact <id> \"<the STATUS: FOUND line>\""));
    }
    let body = record_status_line(s, "FOUND", "Fact", id, line)?;
    s.journal("fact", id, &body);
    let _ = writeln!(io.out, "task-fact: recorded on {id}");
    Ok(0)
}

pub fn task_diagnosis(s: &S, a: &[String], io: &mut Io) -> R {
    let (id, line) = (arg(a, 0), arg(a, 1));
    if id.is_empty() || line.is_empty() {
        return Err(die(
            "usage: task-diagnosis <id> \"<the STATUS: DIAGNOSED line>\"",
        ));
    }
    let body = record_status_line(s, "DIAGNOSED", "Root cause", id, line)?;
    s.journal("diagnosis", id, &body);
    let _ = writeln!(io.out, "task-diagnosis: recorded on {id}");
    Ok(0)
}

pub fn base_failing(s: &S, a: &[String], io: &mut Io) -> R {
    let id = arg(a, 0);
    if id.is_empty() || id.contains('/') {
        return Err(die("usage: base-failing <id> [--set]"));
    }
    let rel = format!("base-failing/{id}.txt");
    if arg(a, 1) != "--set" {
        let names = s.read(&rel);
        io.out.push_str(&names);
        return Ok(i32::from(names.is_empty()));
    }
    let mut names: Vec<&str> =
        s.c.stdin
            .lines()
            .map(str::trim)
            .filter(|l| !l.is_empty())
            .collect();
    names.sort_unstable();
    names.dedup();
    if names.is_empty() {
        s.rm(&rel);
    } else {
        mkdir(s, "base-failing");
        write(s, &rel, &format!("{}\n", names.join("\n")));
    }
    Ok(0)
}

pub fn task_done(s: &S, id: &str, hash: &str, io: &mut Io) -> R {
    if id.is_empty() || hash.is_empty() {
        return Err(die("usage: task-done <id> <commit-hash>"));
    }
    let dir = s.task_dir(id);
    let rev = |r: &str| {
        ok(
            &dir,
            &[
                "rev-parse",
                "--verify",
                "--quiet",
                &format!("{r}^{{commit}}"),
            ],
        )
    };
    if !rev(hash) {
        let _ = writeln!(
            io.err,
            "task-done: {hash} is not a commit in {}",
            dir.display()
        );
        return Ok(3);
    }
    let prov_branch = s.task_branch(id);
    let r#ref = if !prov_branch.is_empty() && rev(&prov_branch) {
        prov_branch.as_str()
    } else {
        "HEAD"
    };
    let base = s.resolve_base();
    let in_base = !base.is_empty() && ok(&dir, &["merge-base", "--is-ancestor", hash, &base]);
    if !in_base && !ok(&dir, &["merge-base", "--is-ancestor", hash, r#ref]) {
        let _ = writeln!(
            io.err,
            "task-done: {hash} is not reachable from {} in {}",
            r#ref,
            dir.display()
        );
        return Ok(3);
    }
    let changed = g(
        &dir,
        &[
            "diff-tree",
            "--no-commit-id",
            "--name-only",
            "-r",
            "--root",
            hash,
        ],
    )
    .unwrap_or_default();
    if changed.lines().any(|l| l.starts_with(".radin/")) {
        let _ = writeln!(io.err, "task-done: {hash} changes a file under .radin/");
        return Ok(3);
    }
    record_done(s, id, hash, io)
}

/// Writes the completed line and drops the backlog and steps entries; an empty `hash` means the work is gitignored.
pub fn record_done(s: &S, id: &str, hash: &str, io: &mut Io) -> R {
    let dir = s.task_dir(id);
    let prov_branch = s.task_branch(id);
    let prov_worktree = s.task_worktree(id);
    let title = s.task_title(id);
    let plans = s.task_plans(id);
    let created = s
        .bl_ok(&["stamps"])
        .and_then(|o| {
            o.lines().find_map(|l| {
                l.strip_prefix(&format!("{id}\t"))
                    .map(|r| r.split('\t').next().unwrap_or("").to_string())
            })
        })
        .unwrap_or_default();
    let out_of_plan = plan_extras(&dir, hash, &s.plan_files(id));
    if s.completed_get(id).is_none() {
        let row = s.find_row(id).unwrap_or_default();
        let col = |i: usize| row.get(i).cloned().unwrap_or_default();
        let meta = s.bl_ok(&["meta", id]).unwrap_or_default();
        let meta_of = |k: &str| {
            meta.lines()
                .filter_map(|l| l.strip_prefix(&format!("{k}\t")))
                .collect::<Vec<_>>()
                .join(" | ")
        };
        let entry = s.entry(id).unwrap_or_default();
        let claimed = s
            .dispatches(id)
            .first()
            .map(|d| d.2.clone())
            .unwrap_or_default();
        store::append(
            &s.completed,
            &format!(
                "{{\"id\":\"{}\",\"commit\":\"{}\",\"title\":\"{}\",\"branch\":\"{}\",\"worktree\":\"{}\",\"plan\":\"{}\",\"ts\":\"{}\",\"created\":\"{}\",\"run\":\"{}\",\"attempts\":{},\"debugged\":{},\"claimed\":\"{}\",\"category\":\"{}\",\"priority\":\"{}\",\"epic\":\"{}\",\"complexity\":\"{}\",\"acceptance\":\"{}\"}}\n",
                json_escape(id), json_escape(hash), json_escape(&title), json_escape(&prov_branch),
                json_escape(&prov_worktree), json_escape(&plans), store::now_utc(), json_escape(&created),
                json_escape(&s.run_id()), num(&entry, "attempts"), num(&entry, "debugged"), json_escape(&claimed),
                json_escape(&col(1)), json_escape(&col(4)), json_escape(&crate::backlog::epic_of(&col(3))),
                json_escape(&meta_of("complexity")), json_escape(&meta_of("acceptance"))
            ),
        );
    }
    if s.find_row(id).is_some() {
        if let Ok(f) = s.field(id, "TASK_FILE") {
            let facts: String = std::fs::read_to_string(&f)
                .unwrap_or_default()
                .lines()
                .filter(|l| l.starts_with("**Fact:**"))
                .map(|l| format!("{l}\n"))
                .collect();
            if !facts.is_empty() {
                let _ = std::fs::create_dir_all(s.state.join("facts"));
                store::append(&s.state.join(format!("facts/{id}.md")), &facts);
            }
        }
        if let Err(e) = s.bl_must(&["remove", id], "") {
            io.err.push_str(&e.msg);
            return Ok(e.code);
        }
    }
    s.rm(&format!("base-failing/{id}.txt"));
    s.rm(&format!("lane-base/{id}"));
    if s.steps.is_file() {
        let key = format!("\"id\":\"{id}\"");
        let kept: String = store::read_lines(&s.steps)
            .iter()
            .filter(|l| !l.contains(&key))
            .map(|l| format!("{l}\n"))
            .collect();
        store::write_atomic(&s.steps, &kept).map_err(|e| die(e.to_string()))?;
    }
    s.journal("done", id, hash);
    if !out_of_plan.is_empty() {
        s.journal("out-of-plan", id, &out_of_plan);
    }
    let _ = writeln!(
        io.out,
        "task-done: {id} recorded at {hash}; backlog and steps entries removed"
    );
    Ok(0)
}

pub fn recover(s: &S, a: &[String], io: &mut Io) -> R {
    let id = arg(a, 0);
    if id.is_empty() {
        return Err(die("usage: recover <id>"));
    }
    if let Some(hash) = s.completed_get(id) {
        let mut d = Io::default();
        let rc = task_done(s, id, &hash, &mut d)?;
        if rc != 0 {
            io.err.push_str(&d.err);
            return Ok(rc);
        }
        let _ = writeln!(io.out, "recovered\t{id}\tbookkeeping completed at {hash}");
        return Ok(0);
    }
    let dir = s.task_dir(id);
    let branch = s.task_branch(id);
    let lane_task = !s.task_lane(id).is_empty();
    if !branch.is_empty() && s.git_ok(&["rev-parse", "--verify", "--quiet", &branch]) {
        let from = s.read(&format!("lane-base/{id}")).trim().to_string();
        let range = if lane_task && !from.is_empty() {
            vec![format!("{from}..{branch}")]
        } else {
            vec![branch.clone(), "--not".into(), "HEAD".into()]
        };
        let mut args = vec!["log", "--oneline", "--no-decorate"];
        args.extend(range.iter().map(String::as_str));
        let log = s.gt(&args);
        let commits: Vec<&str> = log.lines().take(20).collect();
        if !commits.is_empty() {
            if dir == s.root {
                io.out.push_str("worktree\tnone\n");
            } else {
                let _ = writeln!(io.out, "worktree\t{}", dir.display());
            }
            let _ = writeln!(io.out, "branch\t{branch}");
            for c in commits {
                let _ = writeln!(io.out, "branch_commit\t{c}");
            }
            return Ok(3);
        }
    }
    if lane_task {
        if let Some(line) = super::park::park(s, id, "session died")? {
            s.set_status(id, "pending", "")?;
            io.out.push_str(&line);
            let _ = writeln!(
                io.out,
                "recovered\t{id}\tparked on radin/wip/{id}, back to pending"
            );
            return Ok(0);
        }
    }
    if dirty_files(&dir).is_empty() {
        s.set_status(id, "pending", "")?;
        let _ = writeln!(
            io.out,
            "recovered\t{id}\tnothing left behind, back to pending"
        );
        return Ok(0);
    }
    let hash = wip_commit(
        &dir,
        id,
        "Left behind by a crashed session. The task is not complete.",
    );
    let d = dir.display();
    s.set_status(
        id,
        "pending",
        &format!("wip commit {hash} in {d} before retry"),
    )?;
    s.entry_note(id, &format!("a crashed session left unfinished work, saved as wip commit {hash}. Build on it, verify it, and commit the rest."));
    s.journal(
        "wip",
        id,
        &format!("{hash} in {d} -- crash recovery for task {id}"),
    );
    let _ = writeln!(
        io.out,
        "recovered\t{id}\tcommitted wip {hash}, back to pending"
    );
    Ok(0)
}

pub fn recover_reject(s: &S, a: &[String], io: &mut Io) -> R {
    let id = arg(a, 0);
    if id.is_empty() {
        return Err(die("usage: recover-reject <id>"));
    }
    let dir = s.task_dir(id);
    let parked = super::park::park(s, id, "rejected after a crash")?;
    let note = if parked.is_some() {
        format!("a dead session left commits that do not satisfy the task; they sit on radin/wip/{id} -- inspect them before retrying")
    } else if dir == s.root {
        format!("a dead session left commits on radin/{id} that do not satisfy the task -- inspect them before retrying")
    } else {
        format!("a dead session left commits on radin/{id} (worktree {}) that do not satisfy the task -- inspect them before retrying", dir.display())
    };
    s.set_blocked(id, "rejected", &note)?;
    io.out.push_str(&parked.unwrap_or_default());
    let _ = writeln!(io.out, "blocked\t{id}\t{note}");
    Ok(0)
}

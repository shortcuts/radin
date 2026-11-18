use super::git::gt;
use super::mergeq::{base_of, status};
use super::store::{self, deps_json, entry_json, get, read_lines};
use super::{arg, die, mkdir, write, S};
use crate::backlog::{Io, R};
use std::fmt::Write;

const ATTEMPTS: usize = 2;

#[derive(Debug, PartialEq)]
enum Gate {
    Run(usize),
    Green,
    Red(String),
    Ask,
}

fn derive(text: &str) -> Gate {
    let mut failed = 0;
    for l in text.lines() {
        match l.split_once('\t').unwrap_or((l, "")) {
            ("green", _) => return Gate::Green,
            ("fix", id) => return Gate::Red(id.into()),
            ("ask", _) => return Gate::Ask,
            ("failed", _) => failed += 1,
            _ => {}
        }
    }
    Gate::Run(failed)
}

fn rel(epic: &str) -> String {
    format!("gate/{epic}")
}

fn records(s: &S, epic: &str, kind: &str) -> Vec<String> {
    s.read(&rel(epic))
        .lines()
        .filter_map(|l| l.split_once('\t'))
        .filter(|(k, _)| *k == kind)
        .map(|(_, v)| v.to_string())
        .collect()
}

fn add(s: &S, epic: &str, record: &str) {
    mkdir(s, "gate");
    store::append(&s.state.join(rel(epic)), &format!("{record}\n"));
}

/// `run`, `green`, `red` or `ask`: the router's view of a merged lane's gate.
pub(super) fn state_of(s: &S, epic: &str) -> &'static str {
    match derive(&s.read(&rel(epic))) {
        Gate::Run(_) => "run",
        Gate::Green => "green",
        Gate::Red(_) => "red",
        Gate::Ask => "ask",
    }
}

pub(super) fn record_merge(s: &S, epic: &str, hash: &str) {
    mkdir(s, "gate");
    write(s, &rel(epic), &format!("merge\t{hash}\n"));
}

pub(super) fn record_green(s: &S, epic: &str) {
    mkdir(s, "gate");
    write(s, &rel(epic), "green\n");
}

/// The hotfix entry of a red main that no hotfix lane has closed yet.
pub(super) fn open_hotfix(s: &S) -> Option<String> {
    s.files_in("hotfix")
        .into_iter()
        .find(|(id, _)| s.read(&format!("hotfix/{id}")).trim() == "open")
        .map(|(id, _)| id)
}

pub(super) fn close_hotfix(s: &S, id: &str) {
    write(s, &format!("hotfix/{id}"), "closed\n");
}

fn flat(text: &str) -> String {
    text.replace(['\t', '\n', '\r'], " ").trim().to_string()
}

/// Task ids of the lane's merged commits, oldest first.
fn lane_tasks(s: &S, merge: &str) -> Vec<String> {
    let hashes = s.gt(&["rev-list", "--reverse", &format!("{merge}^1..{merge}^2")]);
    let rows = read_lines(&s.completed);
    let mut ids: Vec<String> = Vec::new();
    for h in hashes.lines() {
        for l in &rows {
            let (c, id) = (get(l, "commit"), get(l, "id"));
            if !c.is_empty() && h.starts_with(&c) && !ids.contains(&id) {
                ids.push(id);
            }
        }
    }
    ids
}

/// True when a task of the merged lane reported `risk=high` in its commit trailer or edited a verification file.
fn lane_high(s: &S, merge: &str) -> bool {
    let ids = lane_tasks(s, merge);
    s.journal_lines().iter().any(|l| {
        ids.contains(&get(l, "id"))
            && (get(l, "event") == "verify-edit"
                || (get(l, "event") == "risk" && get(l, "detail") == "high"))
    })
}

fn file_fix(
    s: &S,
    epic: &str,
    merge: &str,
    failed: &[String],
) -> Result<String, crate::backlog::Fail> {
    let base = base_of(s)?;
    let ids = lane_tasks(s, merge);
    let mut body = format!(
        "After lane {epic} merged into {base} at {merge}, the gate on {base} stayed red through {ATTEMPTS} attempts. Fix forward. Never revert.\n\n**Introduced by:** {}\n\n**Failure:**\n",
        if ids.is_empty() { "no lane task matched".into() } else { ids.join(", ") }
    );
    for (i, f) in failed.iter().enumerate() {
        let _ = writeln!(body, "- attempt {}: {f}", i + 1);
    }
    let title = format!("Fix red {base} after lane {epic}");
    let accept = format!("full test suite, lint and format pass on {base}");
    let mut args = vec![
        "add",
        "fix",
        &title,
        "--complexity",
        "high",
        "--acceptance",
        &accept,
    ];
    if let Some(first) = ids.first() {
        args.extend(["--origin", first]);
    }
    let id = s.bl_must(&args, &body)?.trim().to_string();
    s.bl_must(&["set-priority", &id, "21"], "")?;
    let deps = deps_json("");
    store::append(
        &s.steps,
        &format!("{}\n", entry_json(&id, 0, "pending", "", &deps, 0, 0, "")),
    );
    mkdir(s, "hotfix");
    write(s, &format!("hotfix/{id}"), "open\n");
    add(s, epic, &format!("fix\t{id}"));
    s.journal("gate-red", "", &format!("{epic} {id}"));
    Ok(id)
}

pub fn lane_gate(s: &S, a: &[String], io: &mut Io) -> R {
    let epic = arg(a, 0);
    let (flag, line) = (arg(a, 1), arg(a, 2));
    let shape = match flag {
        "" => a.len() == 1,
        "--map" | "--reset" => a.len() == 2,
        "--report" => a.len() == 3,
        _ => false,
    };
    if epic.is_empty() || !shape {
        return Err(die(
            "usage: lane-gate <epic> [--map|--report \"<STATUS line>\"|--reset]",
        ));
    }
    if s.lane_mode() != "lanes" {
        return Ok(0);
    }
    if status(s, epic) != "merged" {
        return Err(die(format!("lane {epic} has not merged")));
    }
    let state = derive(&s.read(&rel(epic)));
    let merge = records(s, epic, "merge").pop().unwrap_or_default();
    if matches!(flag, "--map" | "--report") && merge.is_empty() {
        return Err(die(format!("lane {epic} has no merge record")));
    }
    let need_run = || match &state {
        Gate::Run(n) => Ok(*n),
        _ => Err(die(format!("lane {epic} gate is {}", state_of(s, epic)))),
    };
    match flag {
        "" => {
            let _ = match &state {
                Gate::Green => writeln!(io.out, "green\t{epic}"),
                Gate::Red(id) => writeln!(io.out, "red\t{epic}\t{id}"),
                Gate::Ask => writeln!(io.out, "ask\t{epic}"),
                Gate::Run(n) => writeln!(io.out, "run\t{epic}\t{}", n + 1),
            };
            Ok(0)
        }
        "--map" => {
            let base = base_of(s)?;
            let tip = gt(&s.root, &["rev-parse", "--short=12", "HEAD"]);
            let _ = writeln!(io.out, "{base}\t{tip}\t{}\t{merge}", s.root.display());
            for f in records(s, epic, "failed") {
                let _ = writeln!(io.out, "previous\t{f}");
            }
            if lane_high(s, &merge) {
                let _ = writeln!(io.out, "risk\thigh");
            }
            Ok(0)
        }
        "--reset" => {
            if state != Gate::Ask {
                return Err(die(format!("lane {epic} gate is {}", state_of(s, epic))));
            }
            record_merge(s, epic, &merge);
            let _ = writeln!(io.out, "run\t{epic}\t1");
            Ok(0)
        }
        _ => {
            let failures = need_run()?;
            if line
                .trim_matches('`')
                .trim_start()
                .starts_with("STATUS: SUCCESS")
            {
                add(s, epic, "green");
                s.journal("gate-green", "", epic);
                let _ = writeln!(io.out, "green\t{epic}");
                return Ok(0);
            }
            add(s, epic, &format!("failed\t{}", flat(line)));
            s.journal(
                "gate-failed",
                "",
                &format!("{epic} attempt {}", failures + 1),
            );
            if failures + 1 < ATTEMPTS {
                let _ = writeln!(io.out, "retry\t{epic}\t{}", failures + 2);
            } else if epic.starts_with("hotfix-") {
                add(s, epic, "ask");
                let _ = writeln!(io.out, "ask\t{epic}");
            } else {
                let failed = records(s, epic, "failed");
                let id = file_fix(s, epic, &merge, &failed)?;
                let _ = writeln!(io.out, "red\t{epic}\t{id}");
            }
            Ok(0)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_gate_state_derives_from_its_records() {
        assert_eq!(derive("merge\tabc\n"), Gate::Run(0));
        assert_eq!(derive("merge\tabc\nfailed\tx\n"), Gate::Run(1));
        assert_eq!(derive("merge\tabc\nfailed\tx\ngreen\n"), Gate::Green);
        assert_eq!(
            derive("merge\tabc\nfailed\ta\nfailed\tb\nfix\tid-1\n"),
            Gate::Red("id-1".into())
        );
        assert_eq!(derive("merge\tabc\nfailed\ta\nfailed\tb\nask\n"), Gate::Ask);
        assert_eq!(flat("a\tb\nc"), "a b c");
    }
}

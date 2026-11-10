use super::plan_cover::{norm_path, shared_paths};
use super::store::{self, deps_json, entry_json, get, num, read_lines};
use super::{arg, die, positive, S};
use crate::backlog::{Io, R};
use std::collections::HashSet;
use std::fmt::Write;

pub fn steps_init(s: &S, io: &mut Io) -> R {
    let mut out = String::new();
    let mut n = 0;
    for raw in s.c.stdin.lines().filter(|l| !l.is_empty()) {
        let mut f = raw.splitn(4, '\t');
        let (id, order, deps) = (
            f.next().unwrap_or(""),
            f.next().unwrap_or(""),
            f.next().unwrap_or(""),
        );
        let status = match f.next().unwrap_or("") {
            "" => "pending",
            v => v,
        };
        if order.is_empty() || !order.bytes().all(|b| b.is_ascii_digit()) {
            let o = if order.is_empty() { "<empty>" } else { order };
            return Err(die(format!("bad order for '{id}': {o}")));
        }
        if !matches!(status, "pending" | "excluded") {
            return Err(die(format!(
                "bad status for '{id}': {status} (pending|excluded)"
            )));
        }
        let from_index = s.find_deps(id);
        let deps = if from_index.is_empty() {
            deps.replace(' ', "")
        } else {
            from_index.replace(' ', "")
        };
        let order: u64 = order.parse().unwrap_or(0);
        out += &entry_json(id, order, status, "", &deps_json(&deps), 0, 0, "");
        out.push('\n');
        n += 1;
    }
    if n == 0 {
        return Err(die("no entries on stdin"));
    }
    store::write_atomic(&s.steps, &out).map_err(|e| die(e.to_string()))?;
    let count = s.bl_ok(&["count"]).unwrap_or_else(|| "0".into());
    let count = count.trim();
    let done = read_lines(&s.completed).len();
    let mut base = s.gt(&["rev-parse", "--abbrev-ref", "HEAD"]);
    if base.starts_with("radin/") || base == "HEAD" || base.is_empty() {
        base = get(&s.read("baseline.json"), "base_branch");
    }
    let count = if count.is_empty() { "0" } else { count };
    store::write_atomic(
        &s.state.join("baseline.json"),
        &format!(
            "{{\"backlog_count\":{count},\"completed_count\":{done},\"base_branch\":\"{}\",\"run_id\":\"{}\"}}\n",
            store::json_escape(&base),
            store::run_stamp()
        ),
    )
    .map_err(|e| die(e.to_string()))?;
    for f in ["gate-fixes", "gate-reviewed", "gate-done"] {
        s.clear_marker("", f);
    }
    s.rm("dispatch-seq");
    for d in ["dispatch", "wave-of"] {
        let _ = std::fs::remove_dir_all(s.state.join(d));
    }
    s.journal("steps-init", "", &format!("{n} entries"));
    let _ = writeln!(
        io.out,
        "steps-init: wrote {n} entries to {}",
        s.steps.display()
    );
    Ok(0)
}

pub fn steps_list(s: &S, io: &mut Io) -> R {
    let lines = read_lines(&s.steps);
    if lines.is_empty() {
        return Ok(1);
    }
    for l in lines {
        let _ = writeln!(
            io.out,
            "{}\t{}\t{}\t{}\t{}",
            get(&l, "id"),
            num(&l, "order"),
            get(&l, "status"),
            num(&l, "attempts"),
            get(&l, "note")
        );
    }
    Ok(0)
}

pub fn steps_open(s: &S, io: &mut Io) -> R {
    let mut found = false;
    for l in read_lines(&s.steps) {
        if get(&l, "status") != "pending" {
            continue;
        }
        let id = get(&l, "id");
        let Some(qs) = s.bl_ok(&["open-decisions", &id]) else {
            continue;
        };
        let qs = qs.trim_end_matches('\n');
        let rows: Vec<&str> = if qs.is_empty() {
            vec![""]
        } else {
            qs.lines().collect()
        };
        for q in rows {
            let _ = writeln!(io.out, "{id}\t{q}");
            found = true;
        }
    }
    Ok(i32::from(!found))
}

fn waiting_reason(reason: &str) -> bool {
    matches!(reason, "deferred" | "inconclusive" | "fact" | "decision")
}

pub fn steps_waiting(s: &S, io: &mut Io) -> R {
    let mut found = false;
    for l in read_lines(&s.steps) {
        let reason = get(&l, "reason");
        if get(&l, "status") == "blocked" && waiting_reason(&reason) {
            let _ = writeln!(io.out, "{}\t{reason}\t{}", get(&l, "id"), get(&l, "note"));
            found = true;
        }
    }
    Ok(i32::from(!found))
}

pub fn stuck_lines(s: &S) -> Vec<String> {
    read_lines(&s.steps)
        .iter()
        .filter(|l| get(l, "status") == "in_progress")
        .map(|l| {
            format!(
                "{}\t{}\t{}",
                get(l, "id"),
                num(l, "attempts"),
                get(l, "note")
            )
        })
        .collect()
}

pub fn stuck(s: &S, io: &mut Io) -> R {
    if !s.steps.is_file() {
        return Ok(1);
    }
    let rows = stuck_lines(s);
    for r in &rows {
        let _ = writeln!(io.out, "{r}");
    }
    Ok(i32::from(rows.is_empty()))
}

pub fn preflight(s: &S, io: &mut Io) -> R {
    s.clear_marker("", "teardown");
    s.bl(&["reconcile"], "");
    if s.bl_ok(&["count"]).is_some_and(|c| c.trim() == "0") {
        io.out.push_str("empty\n");
        return Ok(0);
    }
    if s.session_get().is_none() {
        io.out.push_str("session\tmissing\n");
    }
    if s.steps.is_file() {
        for r in stuck_lines(s) {
            let _ = writeln!(io.out, "stuck\t{r}");
        }
    }
    let mut w = Io::default();
    let _ = steps_waiting(s, &mut w);
    for l in w.out.lines() {
        let _ = writeln!(io.out, "waiting\t{l}");
    }
    if let Some(ids) = s.bl_ok(&["order", "--rank-needed"]) {
        let _ = writeln!(
            io.out,
            "rank\t{}",
            ids.lines().collect::<Vec<_>>().join(",")
        );
    }
    let leftovers = !s.radin_branches().is_empty()
        || ["unmerged", "landing", "conflict"]
            .iter()
            .any(|d| !s.files_in(d).is_empty());
    if leftovers {
        io.out.push_str("leftovers\n");
    }
    Ok(0)
}

pub fn resume(s: &S, io: &mut Io) -> R {
    if !s.steps.is_file() {
        return Ok(1);
    }
    let mut moved: Vec<(String, String)> = Vec::new();
    for l in read_lines(&s.steps) {
        let status = get(&l, "status");
        let reason = get(&l, "reason");
        let retryable = match status.as_str() {
            "failed" => true,
            "blocked" => {
                !(waiting_reason(&reason)
                    || matches!(reason.as_str(), "max-attempts" | "dependency" | "unmerged"))
            }
            _ => false,
        };
        if retryable {
            moved.push((get(&l, "id"), status));
        }
    }
    for (id, old) in moved {
        let attempts = s.entry(&id).map_or(0, |e| num(&e, "attempts"));
        s.write_entry(&id, "pending", attempts, "", None)?;
        let _ = writeln!(io.out, "{id}\t{old}");
    }
    Ok(0)
}

/// Moves a dependency- or unmerged-blocked entry back to pending once its block lifts.
pub fn release_ready(s: &S) -> Result<(), crate::backlog::Fail> {
    if !s.steps.is_file() {
        return Ok(());
    }
    for l in read_lines(&s.steps) {
        if get(&l, "status") != "blocked" {
            continue;
        }
        let id = get(&l, "id");
        let free = match get(&l, "reason").as_str() {
            "dependency" => match deps_check(s, &id)?.1 {
                Some(m) => {
                    s.set_blocked(&id, "dependency", &m)?;
                    false
                }
                None => true,
            },
            "unmerged" => !s.exists(&format!("unmerged/{id}")),
            _ => false,
        };
        if free {
            s.write_entry(&id, "pending", num(&l, "attempts"), "", None)?;
        }
    }
    Ok(())
}

pub fn answered(s: &S, a: &[String]) -> R {
    let id = arg(a, 0);
    if id.is_empty() {
        return Err(die("usage: answered <id>"));
    }
    if !s.steps.is_file() {
        return Err(die(format!("no state file: {}", s.steps.display())));
    }
    s.need_entry(id)?;
    s.write_entry(id, "pending", 0, "", None)?;
    s.journal("answered", id, "");
    Ok(0)
}

pub fn retry(s: &S, a: &[String]) -> R {
    let id = arg(a, 0);
    if id.is_empty() {
        return Err(die("usage: retry <id>"));
    }
    if !s.steps.is_file() {
        return Err(die(format!("no state file: {}", s.steps.display())));
    }
    s.need_entry(id)?;
    s.write_entry(id, "pending", 0, "", Some(0))?;
    s.journal("retry", id, "");
    Ok(0)
}

pub fn set_status(s: &S, a: &[String]) -> R {
    let (id, status) = (arg(a, 0), arg(a, 1));
    let (reason, note) = if arg(a, 2) == "--reason" {
        (arg(a, 3), arg(a, 4))
    } else {
        ("", arg(a, 2))
    };
    if id.is_empty() || status.is_empty() {
        return Err(die(
            "usage: set-status <id> <pending|in_progress|failed|blocked> [--reason deferred] [note]",
        ));
    }
    if !s.steps.is_file() {
        return Err(die(format!("no state file: {}", s.steps.display())));
    }
    if !matches!(status, "pending" | "in_progress" | "failed" | "blocked") {
        return Err(die(format!(
            "status must be pending|in_progress|failed|blocked, got: {status}"
        )));
    }
    if arg(a, 2) == "--reason" && !(reason == "deferred" && status == "blocked") {
        return Err(die(
            "--reason takes only 'deferred', and only with status blocked",
        ));
    }
    if reason.is_empty() {
        s.set_status(id, status, note)?;
    } else {
        s.set_blocked(id, reason, note)?;
    }
    Ok(0)
}

pub fn wave_cap(s: &S, io: &mut Io) -> R {
    let _ = writeln!(io.out, "{}", s.wave_cap()?);
    Ok(0)
}

pub fn teardown(s: &S) -> R {
    if !s.state.is_dir() {
        return Err(die(format!("no state dir: {}", s.state.display())));
    }
    if !s.exists("teardown") {
        s.journal("teardown", "", "requested");
    }
    s.touch("teardown");
    Ok(0)
}

/// Dependency gate: the "dep<TAB>hash" rows, and the message naming the first unresolved dependency.
pub fn deps_check(s: &S, id: &str) -> Result<(Vec<String>, Option<String>), crate::backlog::Fail> {
    let entry = s.need_entry(id)?;
    let mut rows = Vec::new();
    let mut parent: Option<String> = None;
    for dep in s.live_deps(id, &entry).split(',').filter(|d| !d.is_empty()) {
        if let Some(h) = s.completed_get(dep) {
            rows.push(format!("{dep}\t{h}"));
            continue;
        }
        let p = parent.get_or_insert_with(|| s.stack_parent(id));
        let tip = s.gt(&[
            "rev-parse",
            "--short=12",
            &format!("refs/heads/radin/{dep}"),
        ]);
        if !p.is_empty() && s.exists(&format!("unmerged/{dep}")) && !tip.is_empty() {
            rows.push(format!("{dep}\t{tip}"));
            continue;
        }
        let status = s.entry(dep).map_or_else(
            || format!("missing from {}", s.steps.display()),
            |l| get(&l, "status"),
        );
        return Ok((
            rows,
            Some(format!(
                "task '{id}' waiting on dependency '{dep}', which is {status}"
            )),
        ));
    }
    Ok((rows, None))
}

pub fn deps_check_verb(s: &S, a: &[String], io: &mut Io) -> R {
    let id = arg(a, 0);
    if id.is_empty() {
        return Err(die("usage: deps-check <id>"));
    }
    if !s.steps.is_file() {
        return Err(die(format!("no state file: {}", s.steps.display())));
    }
    let (rows, err) = deps_check(s, id)?;
    for r in rows {
        let _ = writeln!(io.out, "{r}");
    }
    err.map_or(Ok(0), |m| Err(die(m)))
}

pub fn wave(s: &S, io: &mut Io) -> R {
    if read_lines(&s.steps).is_empty() {
        return Ok(1);
    }
    release_ready(s)?;
    let cap = s.wave_cap()?;
    let mut shown = 0;
    for l in read_lines(&s.steps) {
        if get(&l, "status") != "pending" {
            continue;
        }
        let id = get(&l, "id");
        if s.exists(&format!("unmerged/{id}")) || deps_check(s, &id)?.1.is_some() {
            continue;
        }
        let _ = writeln!(io.out, "{id}\t{}", num(&l, "order"));
        shown += 1;
        if shown >= cap {
            break;
        }
    }
    Ok(i32::from(shown == 0))
}

pub fn wave_partition(s: &S, a: &[String], io: &mut Io) -> R {
    let mut cap = s.wave_cap()?;
    let mut wave = String::new();
    let mut i = 0;
    while i < a.len() {
        let v = arg(a, i + 1);
        match a[i].as_str() {
            "--cap" if positive(v) => cap = v.parse().unwrap_or(cap),
            "--cap" => {
                return Err(die(format!(
                    "wave-partition: --cap needs a positive integer, got: {v}"
                )))
            }
            "--wave" if positive(v) => wave = v.to_string(),
            "--wave" => {
                return Err(die(format!(
                    "wave-partition: --wave needs a positive integer, got: {v}"
                )))
            }
            _ => return Err(die("usage: wave-partition [--wave N] [--cap N]")),
        }
        i += 2;
    }
    let serialized = |kv: Vec<String>| {
        if !wave.is_empty() {
            s.telemetry("serialized", &kv);
        }
    };
    let mut ids: Vec<String> = Vec::new();
    for line in s.c.stdin.lines() {
        let id = line.split('\t').next().unwrap_or("");
        if !id.is_empty() && !ids.iter().any(|x| x == id) {
            ids.push(id.to_string());
        }
    }
    if ids.is_empty() {
        return Ok(1);
    }
    let paths: Vec<Vec<String>> = ids
        .iter()
        .map(|id| {
            s.plan_files(id)
                .iter()
                .map(|p| norm_path(&s.root, p))
                .collect()
        })
        .collect();
    let exclusive: Vec<bool> = ids
        .iter()
        .map(|id| {
            s.bl_ok(&["meta", id])
                .is_some_and(|m| m.lines().any(|l| l == "exclusive\tyes"))
        })
        .collect();
    let n = ids.len();
    let mut conflict: HashSet<(usize, usize)> = HashSet::new();
    let mut apart: Vec<String> = Vec::new();
    let mut groups: Vec<Vec<usize>> = Vec::new();
    let mut closed: Vec<bool> = Vec::new();
    for i in 0..n {
        for j in i + 1..n {
            if paths[i].is_empty() || paths[j].is_empty() {
                continue;
            }
            let shared = shared_paths(&paths[i], &paths[j]);
            if shared.is_empty() {
                continue;
            }
            apart.push(format!("apart\t{}\t{}\t{shared}", ids[i], ids[j]));
            serialized(vec![
                format!("task={}", ids[j]),
                format!("with={}", ids[i]),
                format!("wave={wave}"),
                "reason=shared-paths".into(),
                format!("paths={shared}"),
            ]);
            conflict.insert((i, j));
        }
        let planned = !paths[i].is_empty();
        let mut placed = None;
        let mut capfull = false;
        if planned && !exclusive[i] {
            for g in 0..groups.len() {
                if closed[g] || groups[g].iter().any(|m| conflict.contains(&(*m, i))) {
                    continue;
                }
                if groups[g].len() as u64 >= cap {
                    capfull = true;
                    continue;
                }
                placed = Some(g);
                break;
            }
        }
        let g = placed.unwrap_or_else(|| {
            groups.push(Vec::new());
            closed.push(!planned || exclusive[i]);
            groups.len() - 1
        });
        if capfull {
            serialized(vec![
                format!("task={}", ids[i]),
                format!("wave={wave}"),
                "reason=cap".into(),
                format!("cap={cap}"),
            ]);
        }
        groups[g].push(i);
    }
    let mut recorded = String::new();
    for g in &groups {
        let csv: Vec<&str> = g.iter().map(|m| ids[*m].as_str()).collect();
        let _ = writeln!(io.out, "group\t{}\t{}", g.len(), csv.join(","));
        let _ = writeln!(recorded, "{}", csv.join(","));
    }
    if s.state.is_dir() {
        super::write(s, "partition", &recorded);
    }
    for l in apart {
        let _ = writeln!(io.out, "{l}");
    }
    for i in (0..n).filter(|i| exclusive[*i]) {
        serialized(vec![
            format!("task={}", ids[i]),
            format!("wave={wave}"),
            "reason=exclusive".into(),
        ]);
    }
    for i in (0..n).filter(|i| paths[*i].is_empty()) {
        let _ = writeln!(io.out, "unplanned\t{}", ids[i]);
        serialized(vec![
            format!("task={}", ids[i]),
            format!("wave={wave}"),
            "reason=no-plan".into(),
        ]);
    }
    Ok(0)
}

use super::store::{get, num, read_lines, FINDING_SECTIONS};
use super::{arg, die, S};
use crate::backlog::{Io, R};
use std::fmt::Write;

pub fn journal_tail(s: &S, a: &[String], io: &mut Io) -> R {
    let lines = read_lines(&s.state.join("journal.jsonl"));
    if lines.is_empty() {
        return Ok(1);
    }
    let n: usize = match arg(a, 0) {
        "" => 20,
        v => v.parse().unwrap_or(0),
    };
    for l in &lines[lines.len().saturating_sub(n)..] {
        let _ = writeln!(io.out, "{l}");
    }
    Ok(0)
}

pub fn plan_covers(s: &S, a: &[String], io: &mut Io) -> R {
    let (csv, path) = (arg(a, 0), arg(a, 1));
    if csv.is_empty() || path.is_empty() {
        return Err(die("usage: plan-covers <plan-csv> <path>"));
    }
    let word = if super::plan_cover::is_test_path(path) {
        "test"
    } else if csv
        .split(',')
        .filter(|p| !p.is_empty())
        .any(|p| s.plan_files(p).iter().any(|f| f == path))
    {
        "in"
    } else {
        "out"
    };
    let _ = writeln!(io.out, "{word}");
    Ok(0)
}

/// `(id, detail)` of a journal line of `event`; the id must be non-empty when `need_id`.
fn event(line: &str, ev: &str, need_id: bool) -> Option<(String, String)> {
    let head = format!("\"event\":\"{ev}\",\"id\":\"");
    let i = line.rfind(&head)? + head.len();
    let rest = &line[i..];
    let j = rest.find('"')?;
    let id = &rest[..j];
    let detail = rest[j..]
        .strip_prefix("\",\"detail\":\"")?
        .strip_suffix("\"}")?;
    (!(need_id && id.is_empty())).then(|| (id.to_string(), detail.to_string()))
}

fn dedupe(v: Vec<String>) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for x in v {
        if !out.contains(&x) {
            out.push(x);
        }
    }
    out
}

fn section(title: &str, lines: &[String]) -> String {
    if lines.is_empty() {
        String::new()
    } else {
        format!("\n{title}\n{}\n", lines.join("\n"))
    }
}

fn unescape(s: &str) -> String {
    s.replace("\\\"", "\"").replace("\\\\", "\\")
}

pub fn report(s: &S, io: &mut Io) -> R {
    let (wt_mode, br_mode) = s.session_get().unwrap_or(("no".into(), "no".into()));
    let baseline = s.read("baseline.json");
    let base_completed = num(&baseline, "completed_count") as usize;
    let base_backlog = (!baseline.is_empty()).then(|| num(&baseline, "backlog_count") as i64);
    let journal = s.journal_lines();
    let from = journal
        .iter()
        .rposition(|l| l.contains("\"event\":\"steps-init\""))
        .unwrap_or(0);
    let recent = &journal[from..];
    let pick = |ev: &str, need: bool| -> Vec<(String, String)> {
        recent.iter().filter_map(|l| event(l, ev, need)).collect()
    };
    let wip_block: Vec<String> = pick("wip-commit", true)
        .iter()
        .map(|(_, d)| format!("- {d}"))
        .collect();
    let dropped_block = dedupe(
        pick("skill-dropped", true)
            .iter()
            .map(|(_, d)| format!("- {d}"))
            .collect(),
    );
    let summaries = pick("summary", true);
    let followups = pick("follow-up", true);
    let outplan_block = dedupe(
        pick("out-of-plan", true)
            .iter()
            .map(|(i, d)| format!("- {i} — out-of-plan: {d}"))
            .collect(),
    );
    let unproven_block = dedupe(
        pick("unproven", true)
            .iter()
            .map(|(i, d)| format!("- {i} — {d}"))
            .collect(),
    );
    let mut usage: Vec<(&str, u64, u64, u64, u64)> = ["planning", "execution", "debug", "factfind"]
        .iter()
        .map(|k| (*k, 0, 0, 0, 0))
        .collect();
    for (_, d) in pick("usage", false) {
        let f: Vec<&str> = d.split(' ').collect();
        if let [k, t, u, m] = f[..] {
            if let (Some(e), Ok(t), Ok(u), Ok(m)) = (
                usage.iter_mut().find(|e| e.0 == k),
                t.parse::<u64>(),
                u.parse::<u64>(),
                m.parse::<u64>(),
            ) {
                *e = (e.0, e.1 + 1, e.2 + t, e.3 + u, e.4 + m);
            }
        }
    }
    let usage_block: Vec<String> = usage
        .iter()
        .filter(|e| e.1 > 0)
        .map(|(k, n, t, u, m)| {
            format!(
                "- {k}: {n} dispatches, {t} tokens, {u} tool uses, {}s",
                m / 1000
            )
        })
        .collect();

    let routed = super::leftover::route(
        s,
        "radin committed these at session end; no task owns them. Amend or split as needed.",
    )?;
    let moved: usize = routed.to_tasks.iter().map(|t| t.1).sum();
    let residual = match (routed.main_hash, moved) {
        (None, 0) => "no residual changes".to_string(),
        (None, n) => format!("residual changes moved to their tasks ({n} files)"),
        (Some(r), 0) => format!("residual changes committed as {r}"),
        (Some(r), n) => {
            format!("residual changes committed as {r} and {n} files moved to their tasks")
        }
    };

    let completed = read_lines(&s.completed);
    let mut succeeded = String::new();
    let mut landed_fu = String::new();
    let (mut n_ok, mut n_fu) = (0, 0);
    for l in completed.iter().skip(base_completed) {
        let (cid, chash) = (get(l, "id"), get(l, "commit"));
        let ctitle = match get(l, "title") {
            t if t.is_empty() => cid.clone(),
            t => t,
        };
        let csum = summaries
            .iter()
            .rev()
            .find(|(i, _)| *i == cid)
            .map(|(_, d)| unescape(d))
            .unwrap_or_default();
        if let Some((_, fid)) = followups.iter().rev().find(|(i, _)| *i == cid) {
            let ftitle = s.task_title(fid);
            let ftitle = if ftitle.is_empty() {
                fid.clone()
            } else {
                ftitle
            };
            landed_fu +=
                &format!("\n- {ctitle} — {chash} on the base. Follow-up: {fid} ({ftitle})");
            if !csum.is_empty() {
                landed_fu += &format!("\n  {csum}");
            }
            n_fu += 1;
            continue;
        }
        n_ok += 1;
        if (wt_mode == "yes" || br_mode == "yes") && s.branch_exists(&format!("radin/{cid}")) {
            let wtd = s.root.as_os_str().to_string_lossy().into_owned() + "-" + &cid;
            let wh = if std::path::Path::new(&wtd).is_dir() {
                format!(" in {wtd}")
            } else {
                String::new()
            };
            succeeded +=
                &format!("\n- {ctitle} — {chash} on radin/{cid}{wh}. Merge: git merge radin/{cid}");
        } else {
            succeeded += &format!("\n- {ctitle} — {chash}");
        }
        if !csum.is_empty() {
            succeeded += &format!("\n  {csum}");
        }
    }

    let (mut failed, mut blocked, mut excluded) = (Vec::new(), Vec::new(), Vec::new());
    for l in read_lines(&s.steps) {
        let eid = get(&l, "id");
        let t = s.task_title(&eid);
        let t = if t.is_empty() { eid } else { t };
        match get(&l, "status").as_str() {
            "failed" => failed.push(format!("- {t} — {}", get(&l, "note"))),
            "blocked" => blocked.push(format!("- {t} — {}", get(&l, "note"))),
            "excluded" => excluded.push(format!("- {t}")),
            _ => {}
        }
    }
    let _ = writeln!(
        io.out,
        "✅ Session complete: {n_ok} succeeded, {n_fu} landed with a follow-up, {} failed, {} awaiting your decision.",
        failed.len(),
        blocked.len()
    );
    if let Some(bb) = base_backlog {
        let now: i64 = s
            .bl_ok(&["count"])
            .and_then(|c| c.trim().parse().ok())
            .unwrap_or(0);
        let added = (now - bb + (n_ok + n_fu) as i64).max(0);
        if s.exists("gate-done") {
            let _ = writeln!(
                io.out,
                "Net-new backlog entries this session: {added}. Reviewed by the session gate."
            );
        } else {
            let _ = writeln!(io.out, "Net-new backlog entries this session: {added}. Nothing verified these commits yet -- /radin-review is that pass.");
        }
    }
    let _ = writeln!(io.out, "{residual}.");
    if !succeeded.is_empty() {
        let _ = writeln!(io.out, "\nSucceeded:{succeeded}");
    }
    if !landed_fu.is_empty() {
        let _ = writeln!(io.out, "\nLanded, follow-up filed:{landed_fu}");
    }
    for (title, lines) in [
        ("Failed (left in the backlog for retry):", &failed),
        (
            "Needs your decision (left in the backlog, nothing implemented):",
            &blocked,
        ),
        ("Excluded from this run (left in the backlog):", &excluded),
        ("Uncommitted changes committed this session:", &wip_block),
        (
            "Out-of-plan files (commit touched paths its plan's Changes does not list):",
            &outplan_block,
        ),
        (
            "Acceptance criteria with no measured Fact line (SUCCESS recorded anyway):",
            &unproven_block,
        ),
        (
            "Skills dropped as unrunnable by a sub-agent (run them yourself):",
            &dropped_block,
        ),
        ("Sub-agent usage this session:", &usage_block),
    ] {
        io.out.push_str(&section(title, lines));
    }
    Ok(0)
}

pub fn review_findings(s: &S, io: &mut Io) -> R {
    let input = s.c.stdin.trim_end_matches('\n');
    if input.is_empty() {
        return Err(die("usage: review-findings (stdin: <task><TAB><class><TAB><plan path>[<TAB><section>] per finding)"));
    }
    let lines: Vec<Vec<&str>> = input.lines().map(|l| l.split('\t').collect()).collect();
    for (l, f) in input.lines().zip(&lines) {
        let n = f.len();
        let class = f.get(1).copied().unwrap_or("");
        let sec = f.get(3).copied().unwrap_or("");
        let bad = !(3..=4).contains(&n)
            || f[2].is_empty()
            || !matches!(class, "plan" | "executor" | "none")
            || (class == "plan"
                && !sec.is_empty()
                && !format!(" {FINDING_SECTIONS} ").contains(&format!(" {sec} ")))
            || (class != "plan" && n == 4 && !sec.is_empty());
        if bad {
            return Err(die(format!("review-findings: bad line (want task<TAB>plan|executor|none<TAB>plan path[<TAB>section, plan only]): {l}")));
        }
    }
    let _ = std::fs::create_dir_all(&s.state);
    for f in &lines {
        let mut detail = format!("{} {}", f[1], f[2]);
        if let Some(sec) = f.get(3).filter(|x| !x.is_empty()) {
            detail += &format!(" {sec}");
        }
        s.journal("review-finding", f[0], &detail);
    }
    let count = |c: &str| lines.iter().filter(|f| f[1] == c).count();
    let tasks = |c: &str| {
        dedupe(
            lines
                .iter()
                .filter(|f| f[1] == c)
                .map(|f| f[0].to_string())
                .collect(),
        )
        .len()
    };
    let mut head = format!("{} findings:", lines.len());
    let mut sep = " ";
    for (c, with_tasks) in [("plan", true), ("executor", true), ("none", false)] {
        if count(c) > 0 {
            head += &if with_tasks {
                format!("{sep}{} {c} ({} tasks)", count(c), tasks(c))
            } else {
                format!("{sep}{} {c}", count(c))
            };
            sep = ", ";
        }
    }
    let _ = writeln!(io.out, "{head}");
    for id in dedupe(
        lines
            .iter()
            .filter(|f| f[1] != "none")
            .map(|f| f[0].to_string())
            .collect(),
    ) {
        let n = |c: &str| lines.iter().filter(|f| f[0] == id && f[1] == c).count();
        let mut l = format!("- {id}:");
        let mut sep = " ";
        if n("plan") > 0 {
            l += &format!("{sep}{} plan", n("plan"));
            sep = ", ";
        }
        if n("executor") > 0 {
            l += &format!("{sep}{} executor", n("executor"));
        }
        let _ = writeln!(io.out, "{l}");
    }
    Ok(0)
}

pub fn finding_classes(s: &S, a: &[String], io: &mut Io) -> R {
    let usage = || die("usage: finding-classes [--since <ts>] [--min <n>]");
    let (mut since, mut min) = (String::new(), "3".to_string());
    let mut i = 0;
    while i < a.len() {
        let Some(v) = a.get(i + 1) else {
            return Err(usage());
        };
        match a[i].as_str() {
            "--since" => since = v.clone(),
            "--min" => min = v.clone(),
            _ => return Err(usage()),
        }
        i += 2;
    }
    if min.is_empty() || !min.bytes().all(|b| b.is_ascii_digit()) {
        return Err(die("finding-classes: --min takes a whole number"));
    }
    let min: u64 = min.parse().unwrap_or(0);
    let journal = s.journal_lines();
    if journal.is_empty() {
        return Ok(1);
    }
    let keep = |ts: &str| since.is_empty() || ts >= since.as_str();
    let mut rows: Vec<(String, String, String)> = Vec::new();
    for l in journal
        .iter()
        .filter(|l| get(l, "event") == "review-finding" && keep(&get(l, "ts")))
    {
        let d = get(l, "detail");
        let sec = d.rsplit(' ').next().unwrap_or("");
        let sec = if FINDING_SECTIONS.split(' ').any(|x| x == sec) {
            sec
        } else {
            "unlabelled"
        };
        rows.push((
            d.split(' ').next().unwrap_or("").to_string(),
            sec.to_string(),
            get(l, "id"),
        ));
    }
    if rows.is_empty() {
        return Ok(1);
    }
    let done_n = read_lines(&s.completed)
        .iter()
        .filter(|l| keep(&get(l, "ts")))
        .count();
    let plan: Vec<&(String, String, String)> = rows.iter().filter(|r| r.0 == "plan").collect();
    let mut table: Vec<(String, usize, usize)> = Vec::new();
    for sec in dedupe(plan.iter().map(|r| r.1.clone()).collect()) {
        let f = plan.iter().filter(|r| r.1 == sec).count();
        let t = dedupe(
            plan.iter()
                .filter(|r| r.1 == sec)
                .map(|r| r.2.clone())
                .collect(),
        )
        .len();
        table.push((sec, f, t));
    }
    table.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(&b.0)));
    let _ = writeln!(
        io.out,
        "since {}: {done_n} tasks completed, {} plan findings",
        if since.is_empty() { "start" } else { &since },
        plan.len()
    );
    for (sec, f, t) in &table {
        let _ = writeln!(io.out, "{sec}\t{f}\t{t}");
    }
    let rec: Vec<&str> = table
        .iter()
        .filter(|(sec, _, t)| sec != "unlabelled" && *t as u64 >= min)
        .map(|r| r.0.as_str())
        .collect();
    if rec.is_empty() {
        let _ = writeln!(io.out, "recurring: none");
    } else {
        let _ = writeln!(io.out, "recurring (>= {min} tasks): {}", rec.join(", "));
    }
    Ok(0)
}

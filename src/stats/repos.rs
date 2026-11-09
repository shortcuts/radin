use super::transcripts::grab;
use super::{f0, f1, row, run_in, Rows};
use crate::Ctx;
use std::collections::{BTreeSet, HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};

pub(super) fn repo_dirs(root: &Path) -> Vec<(String, PathBuf)> {
    let mut v: Vec<(String, PathBuf)> = fs::read_dir(root)
        .into_iter()
        .flatten()
        .flatten()
        .filter(|e| e.path().join(".radin").is_dir())
        .map(|e| (e.file_name().to_string_lossy().into_owned(), e.path()))
        .collect();
    v.sort();
    v
}

pub(super) fn journal_rows(c: &Ctx, root: &Path, since: &str) -> Rows {
    let mut rows = vec![row([
        "repo",
        "open",
        "started",
        "done",
        "failed",
        "blocked",
        "debug",
        "sub-agent-tokens",
        "sub-agent-tools",
        "sub-agent-min",
    ])];
    for (name, dir) in repo_dirs(root) {
        let open = c.nested(&dir, &["backlog", "count"]);
        let open = if open.0 == 0 {
            open.1.trim_end().to_string()
        } else {
            "?".into()
        };
        let j = c.nested(&dir, &["state", "journal-tail", "1000000"]);
        let mut counts: HashMap<String, u64> = HashMap::new();
        let (mut tk, mut tl, mut ms) = (0u64, 0u64, 0u64);
        for l in if j.0 == 0 {
            j.1.lines().collect()
        } else {
            vec![]
        } {
            let ts = grab(
                l,
                "\"ts\":\"",
                |c| c.is_ascii_digit() || c == '-',
                1,
                usize::MAX,
                None,
            );
            if !since.is_empty() && ts.is_some_and(|t| t.1 < since) {
                continue;
            }
            let Some((_, e)) = grab(
                l,
                "\"event\":\"",
                |c| c.is_ascii_lowercase() || c == '_' || c == '-',
                1,
                usize::MAX,
                Some('"'),
            ) else {
                continue;
            };
            *counts.entry(e.into()).or_default() += 1;
            if e == "usage" {
                if let Some((_, d)) =
                    grab(l, "\"detail\":\"", |c| c != '"', 1, usize::MAX, Some('"'))
                {
                    let p: Vec<&str> = d.split(' ').collect();
                    if p.len() == 4 && p[0].bytes().all(|b| b.is_ascii_lowercase()) {
                        let n = |i: usize| p[i].parse::<u64>().ok();
                        if let (Some(a), Some(b), Some(m)) = (n(1), n(2), n(3)) {
                            (tk, tl, ms) = (tk + a, tl + b, ms + m);
                        }
                    }
                }
            }
        }
        let g = |k: &str| counts.get(k).copied().unwrap_or(0).to_string();
        rows.push(vec![
            name,
            open,
            g("in_progress"),
            g("done"),
            g("failed"),
            g("blocked"),
            g("debug"),
            tk.to_string(),
            tl.to_string(),
            f1(ms as f64 / 60000.0),
        ]);
    }
    rows
}

pub(super) fn fixes(subject: &str) -> bool {
    ["fix", "revert"].iter().any(|p| {
        subject
            .strip_prefix(p)
            .and_then(|r| r.chars().next())
            .is_some_and(|ch| "(:! ".contains(ch))
    })
}

pub(super) fn outcome_rows(c: &Ctx, root: &Path) -> Rows {
    let mut rows = vec![row([
        "repo", "tasks", "missing", "refixed", "reverted", "clean%",
    ])];
    for (name, dir) in repo_dirs(root) {
        let list = c.nested(&dir, &["state", "completed-list"]);
        let list = if list.0 == 0 { list.1 } else { String::new() };
        if list.trim().is_empty() {
            continue;
        }
        let want: BTreeSet<&str> = list
            .lines()
            .map(|l| l.split('\t').nth(1).unwrap_or(""))
            .collect();
        let log = run_in(
            c,
            &dir,
            "git",
            &["log", "--format=%x01%H %ct %s", "--name-only"],
        )
        .filter(|o| o.0)
        .map(|o| o.1)
        .unwrap_or_default();
        struct Commit {
            hash: String,
            ts: i64,
            subject: String,
            files: Vec<String>,
        }
        let mut commits: Vec<Commit> = Vec::new();
        for l in log.lines() {
            if let Some(rest) = l.strip_prefix('\u{1}') {
                let mut p = rest.splitn(3, ' ');
                commits.push(Commit {
                    hash: p.next().unwrap_or("").into(),
                    ts: p.next().and_then(|t| t.parse().ok()).unwrap_or(0),
                    subject: p.next().unwrap_or("").into(),
                    files: vec![],
                });
            } else if !l.trim().is_empty() && !l.ends_with(".md") {
                if let Some(c) = commits.last_mut() {
                    c.files.push(l.into());
                }
            }
        }
        let mut by_file: HashMap<&str, Vec<usize>> = HashMap::new();
        for (k, cm) in commits.iter().enumerate() {
            for f in &cm.files {
                by_file.entry(f).or_default().push(k);
            }
        }
        let mut idx: HashMap<&str, usize> = HashMap::new();
        let mut done: HashSet<usize> = HashSet::new();
        for (k, cm) in commits.iter().enumerate() {
            for w in &want {
                if cm.hash.starts_with(w) {
                    idx.insert(w, k);
                    done.insert(k);
                }
            }
        }
        let (mut miss, mut fx, mut rv) = (0u64, 0u64, 0u64);
        for w in &want {
            let Some(&k) = idx.get(w) else {
                miss += 1;
                continue;
            };
            let (mut bad, mut rev) = (false, false);
            for f in &commits[k].files {
                for &j in &by_file[f.as_str()] {
                    let (cj, ck) = (&commits[j], &commits[k]);
                    if !done.contains(&j)
                        && j < k
                        && cj.ts > ck.ts
                        && cj.ts <= ck.ts + 1_209_600
                        && fixes(&cj.subject)
                    {
                        bad = true;
                        rev |= cj.subject.starts_with("revert");
                    }
                }
            }
            fx += u64::from(bad);
            rv += u64::from(rev);
        }
        let tot = want.len() as u64;
        let ok = tot - miss;
        let clean = if ok > 0 {
            100.0 * (ok - fx) as f64 / ok as f64
        } else {
            0.0
        };
        rows.push(vec![
            name,
            tot.to_string(),
            miss.to_string(),
            fx.to_string(),
            rv.to_string(),
            f0(clean),
        ]);
    }
    rows
}

pub(super) fn cost_vs_quality(roles: &Rows, repos: &Rows, outcomes: &Rows) -> Rows {
    let n = |r: &Vec<String>, i: usize| r[i].parse::<f64>().unwrap_or(0.0);
    let mut rows = vec![row([
        "kind",
        "tokens/task",
        "tokens/tool",
        "failed%",
        "debug%",
        "clean%",
    ])];
    let (mut tk, mut tl, mut tt) = (0.0, 0.0, 0.0);
    for r in roles.iter().skip(1) {
        let (t, tools, tasks) = (n(r, 2), n(r, 6), n(r, 7));
        rows.push(vec![
            r[0].clone(),
            f0(if tasks > 0.0 { t / tasks } else { 0.0 }),
            f0(if tools > 0.0 { t / tools } else { 0.0 }),
            "-".into(),
            "-".into(),
            "-".into(),
        ]);
        (tk, tl, tt) = (tk + t, tl + tools, tt + tasks);
    }
    let (mut s, mut f, mut d) = (0.0, 0.0, 0.0);
    for r in repos.iter().skip(1) {
        (s, f, d) = (s + n(r, 2), f + n(r, 4), d + n(r, 6));
    }
    let (mut ok, mut fx) = (0.0, 0.0);
    for r in outcomes.iter().skip(1) {
        (ok, fx) = (ok + n(r, 1) - n(r, 2), fx + n(r, 3));
    }
    let pct = |a: f64, b: f64| f0(if b > 0.0 { 100.0 * a / b } else { 0.0 });
    rows.push(vec![
        "all".into(),
        f0(if tt > 0.0 { tk / tt } else { 0.0 }),
        f0(if tl > 0.0 { tk / tl } else { 0.0 }),
        pct(f, s),
        pct(d, s),
        pct(ok - fx, ok),
    ]);
    rows
}

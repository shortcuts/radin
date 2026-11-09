use super::{commits, digits, exec, ok};
use crate::paths::{git, Namespace};
use crate::{Ctx, Out};
use std::collections::HashSet;
use std::fs;

fn hashes_of(commits_out: &str) -> Vec<String> {
    commits_out
        .lines()
        .filter_map(|l| l.split(' ').next())
        .filter(|h| !h.is_empty())
        .map(str::to_string)
        .collect()
}

fn patch_id(c: &Ctx, hash: &str) -> String {
    let diff = exec(c, "git", &["diff-tree", "-p", hash], None)
        .map(|o| o.1)
        .unwrap_or_default();
    exec(c, "git", &["patch-id", "--stable"], Some(&diff))
        .and_then(|o| o.1.split(' ').next().map(str::to_string))
        .unwrap_or_default()
}

fn author_key(c: &Ctx, hash: &str) -> String {
    git(&c.cwd, &["log", "-1", "--format=%at %s", hash])
        .map(|s| s.trim_end().to_string())
        .unwrap_or_default()
}

fn role_of(files: &[String], c: &Ctx) -> &'static str {
    let hit = files.iter().any(|f| {
        fs::read_to_string(c.cwd.join(f))
            .is_ok_and(|t| t.contains("**Finding:**") || t.contains("**Severity:**"))
    });
    if hit {
        "follow-up"
    } else {
        "feature"
    }
}

fn cols_of(ns: &std::path::Path, id: &str, plans: &[String]) -> String {
    let facts = ns.join(format!("state/facts/{id}.md"));
    let plan_col = plans.join(",");
    format!(
        "{}\t{}",
        if plan_col.is_empty() {
            "none"
        } else {
            &plan_col
        },
        if facts.is_file() {
            facts.to_string_lossy().into_owned()
        } else {
            "none".into()
        }
    )
}

fn field_of(text: &str, key: &str) -> String {
    text.lines()
        .find_map(|l| l.strip_prefix(&format!("{key}\t")))
        .unwrap_or("")
        .to_string()
}

pub(super) fn specs(c: &Ctx, arg: &str) -> Out {
    let listed = commits(c, arg);
    if listed.0 != 0 {
        return listed;
    }
    let hashes = hashes_of(&listed.1);
    let ns = Namespace::locate(&c.cwd).namespace_dir;
    let branch = git(&c.cwd, &["symbolic-ref", "--short", "-q", "HEAD"])
        .map(|s| s.trim_end().to_string())
        .unwrap_or_default();
    let reflog = if branch.is_empty() {
        String::new()
    } else {
        git(&c.cwd, &["reflog", "show", "--format=%H", &branch]).unwrap_or_default()
    };
    let scope_keys: Vec<String> = hashes.iter().map(|h| author_key(c, h)).collect();
    let scope_pids: Vec<String> = hashes.iter().map(|h| patch_id(c, h)).collect();
    let subject = |k: &str| k.split_once(' ').map_or(String::new(), |x| x.1.to_string());
    let mut rows: Vec<(String, String)> = Vec::new();
    let mut done: HashSet<String> = HashSet::new();
    let exists = |h: &str| git(&c.cwd, &["cat-file", "-e", &format!("{h}^{{commit}}")]).is_some();
    let listing = c.nested(&c.cwd, &["state", "completed-list"]);
    let list = if listing.0 == 0 {
        listing.1
    } else {
        String::new()
    };
    for line in list.lines() {
        let (id, commit) = line.split_once('\t').unwrap_or((line, ""));
        if id.is_empty() {
            continue;
        }
        done.insert(id.to_string());
        if commit.len() < 7 {
            continue;
        }
        let mut source = "";
        if hashes
            .iter()
            .any(|h| commit.starts_with(h.as_str()) || h.starts_with(commit))
        {
            source = "commit";
        }
        if source.is_empty() {
            if branch.is_empty() && !exists(commit) {
                return (
                    4,
                    String::new(),
                    format!("radin-scope: commit {commit} of task {id} no longer exists and HEAD has no branch to search the reflog of\n"),
                );
            }
            if reflog.lines().any(|l| l.starts_with(commit)) {
                source = "reflog";
            }
        }
        if source.is_empty() && exists(commit) {
            let pid = patch_id(c, commit);
            let key = author_key(c, commit);
            if (!pid.is_empty() && scope_pids.contains(&pid))
                || scope_keys.contains(&key)
                || scope_keys.iter().any(|k| subject(k) == subject(&key))
            {
                source = "patch";
            }
        }
        if source.is_empty() {
            continue;
        }
        let shown = c.nested(&c.cwd, &["state", "completed-show", id]);
        let shown = if shown.0 == 0 { shown.1 } else { String::new() };
        let plans: Vec<String> = field_of(&shown, "plan")
            .split(',')
            .map(|p| p.trim_matches(' ').to_string())
            .collect();
        let role = role_of(&plans, c);
        let created = field_of(&shown, "created");
        rows.push((
            created.clone(),
            format!(
                "{id}\t{created}\t{}\t{commit}\t{source}\t{role}\t{}\n",
                field_of(&shown, "branch"),
                cols_of(&ns, id, &plans)
            ),
        ));
    }
    if !branch.is_empty() {
        let stamps = c.nested(&c.cwd, &["backlog", "stamps", &branch]);
        let stamps = if stamps.0 == 0 {
            stamps.1
        } else {
            String::new()
        };
        for line in stamps.lines() {
            let mut f = line.splitn(3, '\t');
            let (id, created, b) = (
                f.next().unwrap_or(""),
                f.next().unwrap_or(""),
                f.next().unwrap_or(""),
            );
            if id.is_empty() || done.contains(id) {
                continue;
            }
            let meta = c.nested(&c.cwd, &["backlog", "meta", id]);
            let plans: Vec<String> = meta
                .1
                .lines()
                .filter_map(|l| l.strip_prefix("plan\t"))
                .map(str::to_string)
                .collect();
            let tf = c.nested(&c.cwd, &["backlog", "field", id, "TASK_FILE"]);
            let mut files = plans.clone();
            files.extend(tf.1.lines().next().map(str::to_string));
            let role = role_of(&files, c);
            rows.push((
                created.to_string(),
                format!(
                    "{id}\t{created}\t{b}\t\tpending\t{role}\t{}\n",
                    cols_of(&ns, id, &plans)
                ),
            ));
        }
    }
    rows.sort_by(|a, b| a.0.cmp(&b.0));
    ok(rows.into_iter().map(|r| r.1).collect())
}

fn rung_of(line: &str) -> Option<(String, String)> {
    if !line.ends_with(']') {
        return None;
    }
    let b = line.as_bytes();
    for (i, _) in line.match_indices('[') {
        let k = i
            + 1
            + b[i + 1..]
                .iter()
                .take_while(|c| c.is_ascii_lowercase())
                .count();
        if k > i + 1 && line[k..].starts_with(": ") && k + 2 < b.len() {
            let t = &line[i + 1..b.len() - 1];
            let (rung, ev) = t.split_once(": ").unwrap_or((t, ""));
            return Some((rung.to_string(), ev.to_string()));
        }
    }
    None
}

pub(super) fn bucket(text: &str) -> String {
    let mut out = String::new();
    for l in text.lines().filter(|l| !l.is_empty()) {
        let sev = l.split_whitespace().next().unwrap_or("");
        let (rung, ev) = rung_of(l).unwrap_or_default();
        let b = if !matches!(sev, "critical" | "warning" | "nit") || rung.is_empty() {
            "unparsed"
        } else if sev == "nit" {
            "noted"
        } else if rung == "traced"
            || rung == "ran"
            || ev.contains('"')
            || ["AGENTS", "CLAUDE", "CONTRIBUTING"]
                .iter()
                .any(|n| ev.contains(&format!("{n}.md")))
        {
            "act-on"
        } else {
            "consider"
        };
        out += &format!("{b}\t{l}\n");
    }
    out
}

pub(super) fn attribute(c: &Ctx, arg: &str) -> Out {
    let listed = commits(c, arg);
    if listed.0 != 0 {
        return listed;
    }
    let hashes = hashes_of(&listed.1);
    let mut out = String::new();
    for cite in c.stdin.lines().filter(|l| !l.is_empty()) {
        let (p, l) = cite.rsplit_once(':').unwrap_or((cite, cite));
        let p = p.strip_prefix("./").unwrap_or(p);
        let l = l.split('-').next().unwrap_or("");
        let (mut task, mut plan, mut covers) = (String::new(), String::new(), String::new());
        if digits(l) {
            let range = format!("{l},{l}");
            let h = git(&c.cwd, &["blame", "--porcelain", "-L", &range, "--", p])
                .and_then(|t| {
                    t.lines()
                        .next()
                        .and_then(|f| f.split(' ').next())
                        .map(str::to_string)
                })
                .unwrap_or_default();
            let valid = !h.is_empty()
                && h.bytes()
                    .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b));
            if valid && hashes.contains(&h) {
                let t = c.nested(&c.cwd, &["state", "trace", &h]);
                task = field_of(&t.1, "task");
                plan = field_of(&t.1, "plan");
                if !plan.is_empty() {
                    let r = c.nested(&c.cwd, &["state", "plan-covers", &plan, p]);
                    if r.0 != 0 {
                        return (r.0, out, r.2);
                    }
                    covers = r.1.trim_end_matches('\n').to_string();
                }
            }
        }
        let none = |s: String| if s.is_empty() { "none".to_string() } else { s };
        out += &format!("{cite}\t{}\t{}\t{}\n", none(task), none(plan), none(covers));
    }
    ok(out)
}

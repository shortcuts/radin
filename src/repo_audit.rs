//! Deterministic checks over the files a session loads, so an audit quotes facts instead of guessing.
use crate::repo_context::{load, Loaded};
use crate::stats::{row, table, Rows};
use crate::Ctx;
use std::collections::BTreeMap;
use std::fs;
use std::path::Path;
use std::process::Command;

/// Prose lines with their 1-based number: fenced code is not an instruction.
fn prose(text: &str) -> Vec<(usize, &str)> {
    let mut fenced = false;
    let mut v = Vec::new();
    for (i, l) in text.lines().enumerate() {
        if l.trim_start().starts_with("```") {
            fenced = !fenced;
        } else if !fenced {
            v.push((i + 1, l));
        }
    }
    v
}

fn none_row(title: &str, rows: Rows) -> String {
    if rows.len() == 1 {
        return format!("== {title}\nnone\n\n");
    }
    table(title, &rows)
}

/// GitHub's heading slug: lowercase, punctuation dropped, spaces to dashes.
fn slugs(md: &str) -> Vec<String> {
    prose(md)
        .iter()
        .filter(|(_, l)| l.starts_with('#'))
        .map(|(_, l)| {
            l.trim_start_matches('#')
                .trim()
                .to_lowercase()
                .chars()
                .filter(|c| c.is_alphanumeric() || matches!(c, ' ' | '-' | '_'))
                .collect::<String>()
                .replace(' ', "-")
        })
        .collect()
}

/// A repo path a code span names: it has a slash, no glob or placeholder, and its first
/// component exists, so a miss is a contradiction and not a concept.
fn span_path(span: &str) -> Option<&str> {
    let p = span
        .rsplit_once(':')
        .filter(|(_, n)| n.chars().all(|c| c.is_ascii_digit()) && !n.is_empty())
        .map_or(span, |(a, _)| a);
    let ok = p
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '.' | '-' | '/'));
    (ok && p.contains('/') && !p.starts_with('/') && !p.contains("//"))
        .then_some(p.trim_end_matches('/'))
}

fn resolve(dir: &Path, cwd: &Path, p: &str) -> Option<std::path::PathBuf> {
    [dir.join(p), cwd.join(p)].into_iter().find(|q| q.exists())
}

fn broken(c: &Ctx, f: &Loaded, make: &str) -> Vec<(usize, String, &'static str)> {
    let dir = f.path.parent().unwrap_or(Path::new("."));
    let mut v = Vec::new();
    for (n, line) in prose(&f.text) {
        for span in line.split('`').skip(1).step_by(2) {
            if let Some(t) = span
                .strip_prefix("make ")
                .and_then(|r| r.split_whitespace().next())
            {
                let defined = make.lines().any(|l| l.starts_with(&format!("{t}:")));
                if !make.is_empty() && !t.starts_with('-') && !defined {
                    v.push((n, span.to_string(), "missing make target"));
                }
            } else if let Some(p) = span_path(span) {
                let first = p.split('/').next().unwrap_or("");
                let rooted = resolve(dir, &c.cwd, first).is_some();
                if rooted && resolve(dir, &c.cwd, p).is_none() {
                    v.push((n, span.to_string(), "missing file"));
                }
            }
        }
        for part in line.split("](").skip(1) {
            let Some(t) = part.split(')').next() else {
                continue;
            };
            if t.contains("://") || t.starts_with("mailto:") || t.contains(' ') {
                continue;
            }
            let (path, anchor) = t.split_once('#').unwrap_or((t, ""));
            let target = if path.is_empty() {
                Some(f.path.clone())
            } else {
                resolve(dir, &c.cwd, path)
            };
            match target {
                None => v.push((n, t.to_string(), "missing file")),
                Some(q) if !anchor.is_empty() && q.extension().is_some_and(|e| e == "md") => {
                    let md = fs::read_to_string(&q).unwrap_or_default();
                    if !slugs(&md).iter().any(|s| s == anchor) {
                        v.push((n, t.to_string(), "missing anchor"));
                    }
                }
                _ => {}
            }
        }
    }
    v
}

/// Every reference in a loaded file that the repo contradicts.
pub fn refs(c: &Ctx) -> String {
    let make = fs::read_to_string(c.cwd.join("Makefile")).unwrap_or_default();
    let mut rows = Rows::from([row(["where", "reference", "why"])]);
    for f in load(c).1 {
        for (n, r, why) in broken(c, &f, &make) {
            rows.push(row([&format!("{}:{n}", f.label), &r, why]));
        }
    }
    none_row(
        "repo: references the repo does not hold (candidates: read each sentence, an installed or retired path is not a miss)",
        rows,
    )
}

fn words(l: &str) -> Vec<&str> {
    l.split(|c: char| !c.is_alphanumeric())
        .filter(|w| !w.is_empty())
        .collect()
}

/// Pattern ids (see `lib/radin-audit-patterns.md`) a prose line matches.
fn patterns(line: &str) -> Vec<&'static str> {
    // an identifier such as `ALWAYS_CEILING` is not emphasis
    let plain: String = line.split('`').step_by(2).collect::<Vec<_>>().join(" ");
    let line = plain.as_str();
    let low = line.to_lowercase();
    let has = |ps: &[&str]| ps.iter().any(|p| low.contains(p));
    let w = words(line);
    let mut v = Vec::new();
    let loud = ["MUST", "NEVER", "ALWAYS", "CRITICAL", "IMPORTANT"];
    if w.iter().any(|x| loud.contains(x)) || line.contains("!!") {
        v.push("P1");
    }
    if has(&["try to ", "if possible", "ideally"]) {
        v.push("P2");
    }
    if has(&[
        "think step by step",
        "think harder",
        "plan before acting",
        "scratchpad",
    ]) {
        v.push("P3");
    }
    let lw: Vec<String> = w.iter().map(|x| x.to_lowercase()).collect();
    let ceiling = lw.windows(3).any(|t| {
        matches!(t[0].as_str(), "under" | "most" | "than" | "within")
            && t[1].chars().all(|c| c.is_ascii_digit())
            && matches!(
                t[2].as_str(),
                "words" | "lines" | "sentences" | "bullets" | "paragraphs"
            )
    });
    if ceiling || has(&["no interim", "don't narrate", "summarize every"]) {
        v.push("P4");
    }
    let t = low.trim_start();
    if t.starts_with("remember,") || t.starts_with("again,") {
        v.push("P7");
    }
    if has(&["graded on", "hidden test", "rubric"]) {
        v.push("P8");
    }
    if has(&["usually best", "it's best to"]) {
        v.push("P9");
    }
    if has(&[
        "claude-2",
        "claude-3",
        "claude 3",
        "3.5 sonnet",
        "3.7 sonnet",
        "claude-instant",
    ]) {
        v.push("P10");
    }
    if has(&["only use tools when", "minimize tool calls"]) {
        v.push("P11");
    }
    if has(&["never use bullets", "do not start with", "don't start with"]) {
        v.push("P12");
    }
    v
}

/// The commit that last touched a line, or `-` outside a repo.
fn blame(path: &Path, n: usize) -> String {
    let (Some(dir), Some(name)) = (path.parent(), path.file_name()) else {
        return "-".into();
    };
    let o = Command::new("git")
        .args(["blame", "-L", &format!("{n},{n}"), "--porcelain", "--"])
        .arg(name)
        .current_dir(dir)
        .output();
    let Some(o) = o.ok().filter(|o| o.status.success()) else {
        return "-".into();
    };
    let out = String::from_utf8_lossy(&o.stdout);
    let h = out.split_whitespace().next().unwrap_or("-");
    if h.chars().all(|c| c == '0') {
        "uncommitted".into()
    } else {
        h.chars().take(7).collect()
    }
}

/// A line reduced to its words, so a bullet and a bold copy of one sentence compare equal.
fn key(line: &str) -> String {
    let t = line.trim().trim_start_matches(['-', '*', ' ']);
    t.replace(['*', '`'], "")
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .to_lowercase()
}

fn clip(s: &str) -> String {
    let s = s.trim();
    s.chars().take(90).collect::<String>() + if s.chars().count() > 90 { "…" } else { "" }
}

/// Dated-text pattern hits with their last commit, then every sentence two places repeat.
pub fn signals(c: &Ctx) -> String {
    const BLAME_CAP: usize = 60;
    let files = load(c).1;
    let mut rows = Rows::from([row(["where", "pattern", "commit", "text"])]);
    let mut seen: BTreeMap<String, Vec<String>> = BTreeMap::new();
    let mut blamed = 0;
    for f in &files {
        for (n, line) in prose(&f.text) {
            for id in patterns(line) {
                let commit = if f.scope == "project" && blamed < BLAME_CAP {
                    blamed += 1;
                    blame(&f.path, n)
                } else {
                    "-".into()
                };
                rows.push(row([&format!("{}:{n}", f.label), id, &commit, &clip(line)]));
            }
            let k = key(line);
            if k.len() >= 60 && !k.starts_with(['|', '#']) {
                seen.entry(k).or_default().push(format!("{}:{n}", f.label));
            }
        }
    }
    let mut dup = Rows::from([row(["where", "text"])]);
    for (k, at) in seen.iter().filter(|(_, a)| a.len() > 1) {
        dup.push(row([&at.join(" = "), &clip(k)]));
    }
    none_row(
        "repo: dated or loud text (patterns P1-P12; commit is the last to touch the line)",
        rows,
    ) + &none_row(
        "repo: sentences loaded twice (a file counts once however often it is imported)",
        dup,
    )
}

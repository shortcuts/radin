mod repos;
mod transcripts;

use crate::{Ctx, Out};
use repos::{cost_vs_quality, journal_rows, outcome_rows};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use transcripts::{scan_transcripts, tables_of};

const USAGE: &str = "usage: radin stats [--since YYYY-MM-DD] [--repos-root DIR] [--no-transcripts] [--no-repos] [--no-companions]\n";

pub(super) type Rows = Vec<Vec<String>>;

pub(super) fn row<const N: usize>(cells: [&str; N]) -> Vec<String> {
    cells.iter().map(|s| s.to_string()).collect()
}

/// Rows aligned like `column -t -s TAB`: each column padded to its widest cell plus two spaces.
fn table(title: &str, rows: &Rows) -> String {
    let cols = rows.iter().map(Vec::len).max().unwrap_or(0);
    let width: Vec<usize> = (0..cols)
        .map(|i| {
            rows.iter()
                .filter_map(|r| r.get(i))
                .map(|c| c.chars().count())
                .max()
                .unwrap_or(0)
        })
        .collect();
    let mut out = format!("\n== {title}\n");
    for r in rows {
        let last = r.len().saturating_sub(1);
        let cells: Vec<String> = r
            .iter()
            .enumerate()
            .map(|(i, c)| {
                if i == last {
                    c.clone()
                } else {
                    format!("{c:<w$}  ", w = width[i])
                }
            })
            .collect();
        out += &cells.concat();
        out.push('\n');
    }
    out
}

fn lead_num(s: &str) -> f64 {
    let t: String = s
        .trim_start()
        .chars()
        .take_while(|c| c.is_ascii_digit() || *c == '.')
        .collect();
    t.parse().unwrap_or(0.0)
}

/// Sorts like `sort -t TAB` with the given `(column, numeric-descending)` keys, ties by whole line.
pub(super) fn sorted(mut rows: Rows, keys: &[(usize, bool)]) -> Rows {
    rows.sort_by(|a, b| {
        for &(k, num) in keys {
            let (x, y) = (
                a.get(k).map_or("", String::as_str),
                b.get(k).map_or("", String::as_str),
            );
            let o = if num {
                lead_num(y)
                    .partial_cmp(&lead_num(x))
                    .unwrap_or(std::cmp::Ordering::Equal)
            } else {
                x.as_bytes().cmp(y.as_bytes())
            };
            if o != std::cmp::Ordering::Equal {
                return o;
            }
        }
        a.join("\t").cmp(&b.join("\t"))
    });
    rows
}

pub(super) fn with_header(header: Vec<String>, body: Rows) -> Rows {
    std::iter::once(header).chain(body).collect()
}

pub(super) fn f1(x: f64) -> String {
    format!("{x:.1}")
}

pub(super) fn f0(x: f64) -> String {
    format!("{x:.0}")
}

pub(super) fn run_in(c: &Ctx, dir: &Path, prog: &str, args: &[&str]) -> Option<(bool, String)> {
    let mut cmd = Command::new(prog);
    cmd.args(args).current_dir(dir);
    if let Some(p) = (c.env)("PATH") {
        cmd.env("PATH", p);
    }
    let o = cmd.output().ok()?;
    let text = format!(
        "{}{}",
        String::from_utf8_lossy(&o.stdout),
        String::from_utf8_lossy(&o.stderr)
    );
    Some((o.status.success(), text))
}

fn companions(c: &Ctx) -> String {
    let mut out = String::from("\n== rtk gain\n");
    match run_in(c, &c.cwd, "rtk", &["gain"]) {
        Some((true, t)) => out += &t,
        Some((false, t)) => out += &format!("{t}radin stats: rtk gain failed\n"),
        None => out += "radin stats: rtk gain failed\n",
    }
    let mut found = Vec::new();
    collect(
        &c.home.join(".claude/plugins/cache/caveman/caveman"),
        &mut found,
    );
    found.sort();
    out += "\n== caveman-stats --all (counts only sessions that ran /caveman-stats)\n";
    match found.last() {
        Some(js) => match run_in(c, &c.cwd, "node", &[&js.to_string_lossy(), "--all"]) {
            Some((true, t)) => out += &t,
            Some((false, t)) => out += &format!("{t}radin stats: caveman-stats failed\n"),
            None => out += "radin stats: caveman-stats failed\n",
        },
        None => {
            out += "radin stats: caveman-stats.js not found under ~/.claude/plugins/cache/caveman\n"
        }
    }
    out
}

fn collect(dir: &Path, out: &mut Vec<PathBuf>) {
    for e in fs::read_dir(dir).into_iter().flatten().flatten() {
        let p = e.path();
        if p.is_dir() {
            collect(&p, out);
        } else if p.ends_with("src/hooks/caveman-stats.js") {
            out.push(p);
        }
    }
}

fn arg_err(m: &str) -> Out {
    (1, String::new(), format!("radin stats: {m}\n"))
}

pub fn run(c: &Ctx, args: &[String]) -> Out {
    let mut since = String::new();
    let mut repos_root = c.home.join("Documents");
    let (mut do_tx, mut do_repos, mut do_comp) = (true, true, true);
    let mut it = args.iter();
    while let Some(a) = it.next() {
        match a.as_str() {
            "--since" => match it.next() {
                Some(v) => since = v.clone(),
                None => return arg_err("--since needs a date"),
            },
            "--repos-root" => match it.next() {
                Some(v) => repos_root = PathBuf::from(v),
                None => return arg_err("--repos-root needs a dir"),
            },
            "--no-transcripts" => do_tx = false,
            "--no-repos" => do_repos = false,
            "--no-companions" => do_comp = false,
            _ => return (1, String::new(), USAGE.into()),
        }
    }
    let (mut out, mut err) = (String::new(), String::new());
    let mut roles = None;
    if do_tx {
        let base = (c.env)("CLAUDE_CONFIG_DIR")
            .filter(|d| !d.is_empty())
            .map_or_else(|| c.home.join(".claude"), PathBuf::from);
        let root = base.join("projects");
        if root.is_dir() {
            let t = tables_of(&scan_transcripts(&root, &since));
            let sub = if since.is_empty() {
                String::new()
            } else {
                format!(" (since {since})")
            };
            out += &format!(
                "Transcripts: {}, {} (older sessions are pruned by Claude Code){sub}\n",
                root.display(),
                t.span
            );
            let hdr = with_header;
            out += &table(
                "Stack by vendor",
                &hdr(row(["vendor", "uses (skills + sub-agents)"]), t.vendors),
            );
            out += &table(
                "Skills (tool-calls = model invoked it, typed = user ran /name)",
                &hdr(
                    row([
                        "vendor",
                        "skill",
                        "tool-calls",
                        "typed",
                        "sessions",
                        "projects",
                        "last",
                    ]),
                    t.skills,
                ),
            );
            out += &table(
                "Sub-agents (outcomes from background completions only)",
                &hdr(
                    row([
                        "vendor",
                        "sub-agent",
                        "calls",
                        "finished",
                        "completed",
                        "failed",
                        "other",
                        "avg-tokens",
                        "avg-tools",
                        "avg-sec",
                        "models",
                    ]),
                    t.agents,
                ),
            );
            let role_rows = sorted(t.roles, &[(2, true)]);
            roles = Some(role_rows.clone());
            out += &table(
                "radin roles (sub-agent tokens by Agent name radin-<role>-<task>)",
                &hdr(
                    row([
                        "role",
                        "finished",
                        "tokens",
                        "avg-tokens",
                        "avg-tools",
                        "avg-sec",
                        "tools",
                        "tasks",
                    ]),
                    role_rows,
                ),
            );
            out += &table(
                "radin tasks, top 15 by sub-agent tokens",
                &hdr(row(["task", "tokens"]), t.tasks),
            );
            out += &table(
                "Hooks (one row per hook output; a hook that never fires has no row)",
                &hdr(
                    row([
                        "event",
                        "hook",
                        "ran",
                        "cancelled",
                        "errors",
                        "sessions",
                        "last",
                    ]),
                    t.hooks,
                ),
            );
        } else {
            err += &format!("radin stats: no transcripts at {}\n", root.display());
            out += "No transcript data found.\n";
        }
    }
    if do_repos {
        let repos = journal_rows(c, &repos_root, &since);
        let outcomes = outcome_rows(c, &repos_root);
        out += &table(
            &format!("radin repos under {}", repos_root.display()),
            &repos,
        );
        out += &table("Task outcomes (refixed = a fix:/revert: commit that is not itself a radin task touched the same non-markdown files within 14 days of the task commit)", &outcomes);
        if let Some(r) = roles {
            let mut with_header = vec![row([
                "role",
                "finished",
                "tokens",
                "avg-tokens",
                "avg-tools",
                "avg-sec",
                "tools",
                "tasks",
            ])];
            with_header.extend(r);
            out += &table("Cost vs quality (compare two runs with --since; tokens from transcripts, rates from journals and git)", &cost_vs_quality(&with_header, &repos, &outcomes));
        }
    }
    if do_comp {
        out += &companions(c);
    }
    (0, out, err)
}

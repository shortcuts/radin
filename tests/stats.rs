#[path = "common/cli.rs"]
mod cli;
mod common;

use radin::{Ctx, Host, Out};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

struct W {
    _t: tempfile::TempDir,
    home: PathBuf,
}

fn w() -> W {
    let t = tempfile::tempdir().unwrap();
    let home = t.path().canonicalize().unwrap().join("home");
    fs::create_dir_all(&home).unwrap();
    W { _t: t, home }
}

fn line(ts: &str, body: &str) -> String {
    format!("{{\"timestamp\":\"{ts}T10:00:00Z\",{body}}}\n")
}

fn transcripts(w: &W) -> PathBuf {
    let root = w.home.join(".claude/projects");
    let p = root.join("p1");
    fs::create_dir_all(p.join("s2/subagents")).unwrap();
    let skill = |id: &str| {
        format!("\"message\":{{\"content\":[{{\"id\":\"{id}\",\"name\":\"Skill\",\"input\":{{\"skill\":\"caveman:caveman\"}}}}]}}")
    };
    let agent = |id: &str, extra: &str| {
        format!("\"message\":{{\"content\":[{{\"id\":\"{id}\",\"name\":\"Agent\",\"input\":{{{extra}}}}}]}}")
    };
    let note = |tid: &str, tu: &str, st: &str, tk: u32| {
        format!("\"content\":\"<task-notification><task-id>{tid}</task-id><tool-use-id>{tu}</tool-use-id><status>{st}</status><subagent_tokens>{tk}</subagent_tokens><tool_uses>5</tool_uses><duration_ms>20000</duration_ms></task-notification>\"")
    };
    let mut s1 = String::new();
    s1 += &line("2025-01-02", &skill("toolu_S1"));
    s1 += &line("2025-01-02", &skill("toolu_S1"));
    s1 += &line(
        "2025-01-02",
        "\"message\":{\"content\":\"<command-name>/radin-batch</command-name>\"}",
    );
    s1 += &line(
        "2025-01-02",
        "\"message\":{\"content\":\"<command-name>/radin-batch</command-name>\"}",
    );
    s1 += &line("2025-01-02", &agent("toolu_A1", "\"subagent_type\":\"general-purpose\",\"model\":\"sonnet\",\"name\":\"radin-execution-my-task\""));
    s1 += &line(
        "2025-01-02",
        &agent("toolu_A2", "\"subagent_type\":\"caveman:cavecrew-builder\""),
    );
    s1 += &line("2025-01-02", &note("tk1", "toolu_A1", "completed", 1000));
    s1 += &line("2025-01-02", &note("tk1", "toolu_A1", "completed", 3000));
    s1 += &line("2025-01-02", &note("tk2", "toolu_A2", "failed", 500));
    s1 += &line("2025-01-02", "\"attachment\":{\"type\":\"hook_success\",\"hookName\":\"SubagentStart:x\",\"toolUseID\":\"toolu_h1\",\"content\":\"hello there\"}");
    s1 += &line("2025-01-02", "\"attachment\":{\"type\":\"hook_success\",\"hookName\":\"SubagentStart:x\",\"toolUseID\":\"toolu_h1\",\"content\":\"hello there\"}");
    s1 += &line("2025-01-02", "\"attachment\":{\"type\":\"skill_listing\",\"content\":\"<command-name>/skipped</command-name>\"}");
    s1 += &line(
        "2025-01-02",
        "\"message\":{\"content\":\"plain text, no match\"}",
    );
    fs::write(p.join("s1.jsonl"), s1).unwrap();
    fs::write(
        p.join("s2/subagents/agent-1.jsonl"),
        line(
            "2024-12-01",
            "\"message\":{\"content\":\"<command-name>/old-skill</command-name>\"}",
        ),
    )
    .unwrap();
    root
}

fn no_cli(_: &Path, _: &[&str], _: &str) -> Out {
    (1, String::new(), String::new())
}

fn go(w: &W, args: &[&str], cli: &dyn Fn(&Path, &[&str], &str) -> Out) -> Out {
    go_on(Host::Claude, w, args, cli)
}

fn go_on(host: Host, w: &W, args: &[&str], cli: &dyn Fn(&Path, &[&str], &str) -> Out) -> Out {
    let h = w.home.to_string_lossy().into_owned();
    let bin = w.home.join("bin");
    fs::create_dir_all(&bin).unwrap();
    let real =
        String::from_utf8(Command::new("which").arg("git").output().unwrap().stdout).unwrap();
    let _ = std::os::unix::fs::symlink(real.trim(), bin.join("git"));
    let path = bin.to_string_lossy().into_owned();
    let env = move |k: &str| match k {
        "HOME" => Some(h.clone()),
        "PATH" => Some(path.clone()),
        _ => None,
    };
    let c = Ctx {
        cwd: w.home.clone(),
        home: w.home.clone(),
        host,
        stdin: String::new(),
        env: &env,
        cli,
    };
    let a: Vec<String> = args.iter().map(|s| s.to_string()).collect();
    radin::stats::run(&c, &a)
}

/// Rows of the table after `== title`, each as its cells; padding widths are not an oracle.
fn table(out: &str, title: &str) -> Vec<Vec<String>> {
    let mut rows = Vec::new();
    let mut on = false;
    for l in out.lines() {
        if let Some(t) = l.strip_prefix("== ") {
            on = t.starts_with(title);
        } else if on && !l.is_empty() {
            rows.push(
                l.split("  ")
                    .filter(|c| !c.is_empty())
                    .map(|c| c.trim().to_string())
                    .collect(),
            );
        }
    }
    rows
}

fn row(cells: &[&str]) -> Vec<String> {
    cells.iter().map(|s| s.to_string()).collect()
}

const NO_REPOS: &[&str] = &["--no-repos", "--no-companions"];

fn args<'a>(extra: &[&'a str]) -> Vec<&'a str> {
    let mut v: Vec<&str> = NO_REPOS.to_vec();
    v.extend_from_slice(extra);
    v
}

#[test]
fn the_transcript_tables_count_skills_agents_roles_and_hooks() {
    let w = w();
    let root = transcripts(&w);
    let o = go(&w, &args(&[]), &no_cli);
    assert_eq!(o.0, 0, "{}", o.2);
    assert!(
        o.1.starts_with(&format!(
        "Transcripts: {}, 2024-12-01 to 2025-01-02 (older sessions are pruned by Claude Code)\n",
        root.display()
    )),
        "{}",
        o.1
    );
    assert_eq!(
        table(&o.1, "Skills"),
        vec![
            row(&[
                "vendor",
                "skill",
                "tool-calls",
                "typed",
                "sessions",
                "projects",
                "last"
            ]),
            row(&[
                "caveman",
                "caveman:caveman",
                "1",
                "0",
                "1",
                "1",
                "2025-01-02"
            ]),
            row(&["other", "old-skill", "0", "1", "1", "1", "2024-12-01"]),
            row(&["radin", "radin-batch", "0", "2", "1", "1", "2025-01-02"]),
        ]
    );
    assert_eq!(
        table(&o.1, "Stack by vendor"),
        vec![
            row(&["vendor", "uses (skills + sub-agents)"]),
            row(&["caveman", "2"]),
            row(&["radin", "2"]),
            row(&["built-in", "1"]),
            row(&["other", "1"]),
        ]
    );
    assert_eq!(
        table(&o.1, "Sub-agents"),
        vec![
            row(&[
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
                "models"
            ]),
            row(&[
                "built-in",
                "general-purpose",
                "1",
                "1",
                "1",
                "0",
                "0",
                "3000",
                "5.0",
                "20",
                "sonnet=1"
            ]),
            row(&[
                "caveman",
                "caveman:cavecrew-builder",
                "1",
                "1",
                "0",
                "1",
                "0",
                "500",
                "5.0",
                "20",
                "inherit=1"
            ]),
        ]
    );
    assert_eq!(
        table(&o.1, "radin roles"),
        vec![
            row(&[
                "role",
                "finished",
                "tokens",
                "avg-tokens",
                "avg-tools",
                "avg-sec",
                "tools",
                "tasks"
            ]),
            row(&["execution", "1", "3000", "3000", "5.0", "20", "5", "1"]),
        ]
    );
    assert_eq!(
        table(&o.1, "radin tasks"),
        vec![row(&["task", "tokens"]), row(&["my-task", "3000"])]
    );
    assert_eq!(
        table(&o.1, "Hooks"),
        vec![
            row(&[
                "event",
                "hook",
                "ran",
                "cancelled",
                "errors",
                "sessions",
                "last"
            ]),
            row(&[
                "SubagentStart",
                "hello there",
                "1",
                "0",
                "0",
                "1",
                "2025-01-02"
            ]),
        ]
    );
}

#[test]
fn since_drops_older_lines_and_narrows_the_span() {
    let w = w();
    transcripts(&w);
    let o = go(&w, &args(&["--since", "2025-01-01"]), &no_cli);
    assert!(o.1.contains(", 2025-01-02 to 2025-01-02 (older sessions are pruned by Claude Code) (since 2025-01-01)\n"));
    assert!(!o.1.contains("old-skill"));
}

#[test]
fn a_missing_transcript_directory_reports_on_stderr_and_stdout() {
    let w = w();
    let o = go(&w, &args(&[]), &no_cli);
    assert_eq!(o.0, 0);
    assert_eq!(o.1, "No transcript data found.\n");
    assert_eq!(
        o.2,
        format!(
            "radin stats: no transcripts at {}/.claude/projects\n",
            w.home.display()
        )
    );
}

#[test]
fn no_transcripts_skips_the_scan() {
    let w = w();
    transcripts(&w);
    let o = go(&w, &args(&["--no-transcripts"]), &no_cli);
    assert_eq!(o, (0, String::new(), String::new()));
}

#[test]
fn bad_flags_exit_1_with_usage() {
    let w = w();
    let o = go(&w, &["--bogus"], &no_cli);
    assert_eq!(o.0, 1);
    assert!(o.2.starts_with("usage: radin stats [--since YYYY-MM-DD]"));
    let o = go(&w, &["--since"], &no_cli);
    assert_eq!(
        (o.0, o.2.as_str()),
        (1, "radin stats: --since needs a date\n")
    );
    let o = go(&w, &["--repos-root"], &no_cli);
    assert_eq!(
        (o.0, o.2.as_str()),
        (1, "radin stats: --repos-root needs a dir\n")
    );
}

fn at(dir: &Path, msg: &str, file: &str, ts: i64) {
    fs::write(dir.join(file), format!("{msg}\n{ts}\n")).unwrap();
    cli::git(dir, &["add", file]);
    let d = format!("{ts} +0000");
    let o = std::process::Command::new("git")
        .args([
            "-c",
            "user.name=t",
            "-c",
            "user.email=t@t",
            "commit",
            "-q",
            "-m",
            msg,
        ])
        .env("GIT_AUTHOR_DATE", &d)
        .env("GIT_COMMITTER_DATE", &d)
        .current_dir(dir)
        .output()
        .unwrap();
    assert!(o.status.success());
}

#[test]
fn repo_tables_count_journal_events_and_refixed_tasks() {
    let w = w();
    transcripts(&w);
    let root = w.home.join("Documents");
    let r = root.join("r1");
    fs::create_dir_all(r.join(".radin")).unwrap();
    fs::create_dir_all(root.join("plain")).unwrap();
    cli::git(&r, &["init", "-q"]);
    at(&r, "feat: task", "a.rs", 1_700_000_000);
    at(&r, "docs: note", "n.md", 1_700_000_100);
    at(&r, "fix: oops", "a.rs", 1_700_000_200);
    let task = cli::git(&r, &["rev-parse", "HEAD~2"]).trim().to_string();
    let journal = [
        r#"{"ts":"2025-01-02T10:00:00Z","event":"in_progress","id":"t1"}"#,
        r#"{"ts":"2025-01-02T10:00:00Z","event":"done","id":"t1"}"#,
        r#"{"ts":"2025-01-02T10:00:00Z","event":"usage","id":"t1","detail":"execution 1000 4 120000"}"#,
        r#"{"ts":"2020-01-02T10:00:00Z","event":"failed","id":"t0"}"#,
        "not json",
    ]
    .join("\n");
    let stub = move |dir: &Path, a: &[&str], _: &str| -> Out {
        assert!(dir.ends_with("r1"));
        match (a[2], a[3]) {
            ("state", "completed-list") => (0, format!("t1\t{task}\n"), String::new()),
            ("state", "journal-tail") => (0, journal.clone() + "\n", String::new()),
            ("backlog", "count") => (0, "3\n".into(), String::new()),
            _ => (1, String::new(), String::new()),
        }
    };
    let rs = root.to_string_lossy().into_owned();
    let o = go(
        &w,
        &[
            "--no-companions",
            "--repos-root",
            &rs,
            "--since",
            "2024-01-01",
        ],
        &stub,
    );
    assert_eq!(o.0, 0, "{}", o.2);
    assert_eq!(
        table(&o.1, "radin repos under"),
        vec![
            row(&[
                "repo",
                "open",
                "started",
                "done",
                "failed",
                "blocked",
                "debug",
                "sub-agent-tokens",
                "sub-agent-tools",
                "sub-agent-min"
            ]),
            row(&["r1", "3", "1", "1", "0", "0", "0", "1000", "4", "2.0"]),
        ]
    );
    assert_eq!(
        table(&o.1, "Task outcomes"),
        vec![
            row(&["repo", "tasks", "missing", "refixed", "reverted", "clean%"]),
            row(&["r1", "1", "0", "1", "0", "0"]),
        ]
    );
    assert_eq!(
        table(&o.1, "Cost vs quality"),
        vec![
            row(&[
                "kind",
                "tokens/task",
                "tokens/tool",
                "failed%",
                "debug%",
                "clean%"
            ]),
            row(&["execution", "3000", "600", "-", "-", "-"]),
            row(&["all", "3000", "600", "0", "0", "0"]),
        ]
    );
}

#[test]
fn companions_report_their_absence_and_no_companions_skips_them() {
    let w = w();
    let o = go(&w, &["--no-transcripts", "--no-repos"], &no_cli);
    assert_eq!(
        o.1,
        "\n== rtk gain\nradin stats: rtk gain failed\n\n== caveman-stats --all (counts only sessions that ran /caveman-stats)\nradin stats: caveman-stats.js not found under ~/.claude/plugins/cache/caveman\n"
    );
}

#[test]
fn the_repo_scan_reads_dot_radin_for_every_host() {
    let w = w();
    let root = w.home.join("repos");
    fs::create_dir_all(root.join("a/.radin")).unwrap();
    fs::create_dir_all(root.join("b/.claude")).unwrap();
    let rs = root.to_string_lossy().into_owned();
    let o = go_on(
        Host::Agents,
        &w,
        &["--no-transcripts", "--no-companions", "--repos-root", &rs],
        &no_cli,
    );
    let names: Vec<String> = table(&o.1, "radin repos under")
        .iter()
        .skip(1)
        .map(|r| r[0].clone())
        .collect();
    assert_eq!(names, ["a"]);
}

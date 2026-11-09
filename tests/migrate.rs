#[path = "common/cli.rs"]
mod cli;
mod common;

use radin::migrate::{migrate_state, open};
use std::fs;
use std::path::{Path, PathBuf};
use std::time::Duration;

struct W {
    _t: tempfile::TempDir,
    proj: PathBuf,
}

fn w() -> W {
    let t = tempfile::tempdir().unwrap();
    let proj = t.path().canonicalize().unwrap().join("proj");
    fs::create_dir(&proj).unwrap();
    cli::git(&proj, &["init", "-q", "."]);
    W { _t: t, proj }
}

fn seed(dir: &Path, host: &str, id: &str, dep: Option<&str>) {
    let d = dir.join(format!(".{host}/.radin"));
    for s in ["backlog/tasks", "plans", "state"] {
        fs::create_dir_all(d.join(s)).unwrap();
    }
    let dep = dep.map_or(String::new(), |x| format!(",\"depends_on\":[\"{x}\"]"));
    let line =
        format!("{{\"id\":\"{id}\",\"file\":\"tasks/{id}.md\",\"title\":\"{host} task\"{dep}}}\n");
    let idx = d.join("backlog/index.jsonl");
    let old = fs::read_to_string(&idx).unwrap_or_default();
    fs::write(idx, old + &line).unwrap();
    fs::write(
        d.join(format!("backlog/tasks/{id}.md")),
        format!("{host} body\n"),
    )
    .unwrap();
    fs::write(d.join(format!("plans/{id}.md")), format!("{host} plan\n")).unwrap();
}

fn read(p: &Path) -> String {
    fs::read_to_string(p).unwrap()
}

fn index(dir: &Path) -> String {
    read(&dir.join(".radin/backlog/index.jsonl"))
}

#[test]
fn one_legacy_directory_moves_into_radin_and_the_source_is_deleted() {
    let w = w();
    seed(&w.proj, "claude", "solo", None);
    let mut err = String::new();
    let ns = open(&w.proj, &mut err).unwrap();
    assert_eq!(ns.namespace_dir, w.proj.join(".radin"));
    assert_eq!(
        read(&w.proj.join(".radin/backlog/tasks/solo.md")),
        "claude body\n"
    );
    assert!(!w.proj.join(".claude/.radin").exists());
    assert!(!w.proj.join(".radin.migrating").exists());
}

#[test]
fn two_directories_merge_and_a_colliding_id_takes_the_agents_suffix() {
    let w = w();
    seed(&w.proj, "claude", "same", None);
    seed(&w.proj, "claude", "other", None);
    seed(&w.proj, "agents", "same", None);
    seed(&w.proj, "agents", "child", Some("same"));
    open(&w.proj, &mut String::new()).unwrap();
    let idx = index(&w.proj);
    assert_eq!(idx.lines().count(), 4, "{idx}");
    assert!(idx.contains("\"id\":\"same-agents\",\"file\":\"tasks/same-agents.md\""));
    assert!(idx
        .lines()
        .any(|l| l.contains("\"id\":\"child\"") && l.contains("\"depends_on\":[\"same-agents\"]")));
    assert_eq!(
        read(&w.proj.join(".radin/backlog/tasks/same.md")),
        "claude body\n"
    );
    assert_eq!(
        read(&w.proj.join(".radin/backlog/tasks/same-agents.md")),
        "agents body\n"
    );
    assert_eq!(
        read(&w.proj.join(".radin/plans/same-agents.md")),
        "agents plan\n"
    );
    assert!(!w.proj.join(".agents/.radin").exists());
    assert!(!w.proj.join(".claude/.radin").exists());
}

#[test]
fn a_taken_suffix_takes_the_next_number() {
    let w = w();
    seed(&w.proj, "claude", "same", None);
    seed(&w.proj, "claude", "same-agents", None);
    seed(&w.proj, "agents", "same", None);
    open(&w.proj, &mut String::new()).unwrap();
    let idx = index(&w.proj);
    assert!(
        idx.contains("\"id\":\"same-agents-2\",\"file\":\"tasks/same-agents-2.md\""),
        "{idx}"
    );
    assert_eq!(
        read(&w.proj.join(".radin/backlog/tasks/same-agents-2.md")),
        "agents body\n"
    );
    assert_eq!(
        read(&w.proj.join(".radin/backlog/tasks/same-agents.md")),
        "claude body\n"
    );
}

#[test]
fn absolute_plan_paths_in_the_index_follow_the_move() {
    let w = w();
    seed(&w.proj, "claude", "solo", None);
    let idx = w.proj.join(".claude/.radin/backlog/index.jsonl");
    let mut t = read(&idx);
    t.push_str(&format!(
        "{{\"id\":\"p\",\"file\":\"tasks/p.md\",\"plan\":[\"{}/.claude/.radin/plans/p.md\"]}}\n",
        w.proj.display()
    ));
    fs::write(&idx, t).unwrap();
    open(&w.proj, &mut String::new()).unwrap();
    assert!(index(&w.proj).contains(&format!(
        "\"plan\":[\"{}/.radin/plans/p.md\"]",
        w.proj.display()
    )));
}

#[test]
fn a_second_run_migrates_nothing() {
    let w = w();
    seed(&w.proj, "claude", "solo", None);
    open(&w.proj, &mut String::new()).unwrap();
    fs::write(w.proj.join(".radin/marker"), "kept").unwrap();
    open(&w.proj, &mut String::new()).unwrap();
    assert_eq!(read(&w.proj.join(".radin/marker")), "kept");
    assert!(!w.proj.join(".radin.migrating").exists());
}

#[test]
fn gitignore_gets_radin_once_and_a_deleted_line_stays_deleted() {
    let w = w();
    seed(&w.proj, "claude", "solo", None);
    fs::write(w.proj.join(".gitignore"), "node_modules").unwrap();
    let mut err = String::new();
    open(&w.proj, &mut err).unwrap();
    assert_eq!(
        err,
        "radin: added .radin/ to .gitignore; delete the line to track it\n"
    );
    assert_eq!(read(&w.proj.join(".gitignore")), "node_modules\n.radin/\n");
    fs::write(w.proj.join(".gitignore"), "").unwrap();
    open(&w.proj, &mut String::new()).unwrap();
    assert_eq!(read(&w.proj.join(".gitignore")), "");
}

#[test]
fn a_fresh_repo_creates_radin_and_ignores_it() {
    let w = w();
    open(&w.proj, &mut String::new()).unwrap();
    for d in ["backlog/tasks", "plans", "reviews", "state/facts"] {
        assert!(w.proj.join(".radin").join(d).is_dir(), "{d}");
    }
    assert_eq!(read(&w.proj.join(".gitignore")), ".radin/\n");
}

#[test]
fn gitignore_is_left_alone_when_a_legacy_file_is_tracked_and_git_stages_the_removal() {
    let w = w();
    seed(&w.proj, "claude", "solo", None);
    cli::git(&w.proj, &["add", "-f", ".claude/.radin"]);
    cli::git(&w.proj, &["commit", "-q", "-m", "seed"]);
    open(&w.proj, &mut String::new()).unwrap();
    assert!(!w.proj.join(".gitignore").exists());
    let st = cli::git(&w.proj, &["status", "--porcelain"]);
    assert!(
        st.lines()
            .any(|l| l.starts_with('D') && l.contains(".claude/.radin")),
        "{st}"
    );
    assert!(!w.proj.join(".claude/.radin").exists());
}

#[test]
fn gitignore_is_left_alone_when_radin_is_already_ignored() {
    let w = w();
    fs::write(w.proj.join(".gitignore"), ".radin\n").unwrap();
    let mut err = String::new();
    open(&w.proj, &mut err).unwrap();
    assert_eq!(read(&w.proj.join(".gitignore")), ".radin\n");
    assert_eq!(err, "");
}

#[test]
fn outside_git_no_gitignore_is_written() {
    let t = tempfile::tempdir().unwrap();
    let plain = t.path().canonicalize().unwrap().join("plain");
    seed(&plain, "claude", "solo", None);
    open(&plain, &mut String::new()).unwrap();
    assert!(!plain.join(".gitignore").exists());
    assert!(plain.join(".radin/backlog/tasks/solo.md").is_file());
}

#[test]
fn a_stale_stage_is_renamed_and_migration_proceeds() {
    let w = w();
    seed(&w.proj, "claude", "solo", None);
    fs::create_dir(w.proj.join(".radin.migrating")).unwrap();
    fs::write(w.proj.join(".radin.migrating/junk"), "x").unwrap();
    migrate_state(&w.proj, Duration::ZERO).unwrap();
    assert_eq!(
        read(&w.proj.join(".radin/backlog/tasks/solo.md")),
        "claude body\n"
    );
    assert!(!w.proj.join(".radin/junk").exists());
    assert!(!w.proj.join(".radin.migrating").exists());
    let kept = fs::read_dir(&w.proj)
        .unwrap()
        .filter_map(|e| e.ok())
        .any(|e| {
            e.file_name()
                .to_string_lossy()
                .starts_with(".radin.migrating.")
        });
    assert!(kept);
}

#[test]
fn counter_state_files_append_and_session_files_keep_the_first_copy() {
    let w = w();
    seed(&w.proj, "claude", "a", None);
    seed(&w.proj, "agents", "b", None);
    fs::write(w.proj.join(".claude/.radin/state/journal.jsonl"), "one").unwrap();
    fs::write(w.proj.join(".agents/.radin/state/journal.jsonl"), "two\n").unwrap();
    fs::write(w.proj.join(".claude/.radin/state/session"), "first").unwrap();
    fs::write(w.proj.join(".agents/.radin/state/session"), "second").unwrap();
    fs::write(w.proj.join(".agents/.radin/state/only-agents"), "y").unwrap();
    open(&w.proj, &mut String::new()).unwrap();
    assert_eq!(
        read(&w.proj.join(".radin/state/journal.jsonl")),
        "one\ntwo\n"
    );
    assert_eq!(read(&w.proj.join(".radin/state/session")), "first");
    assert_eq!(read(&w.proj.join(".radin/state/only-agents")), "y");
}

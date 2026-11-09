mod common;

use std::fs;
use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use tempfile::TempDir;

struct Run {
    code: i32,
    out: String,
    err: String,
}

struct W {
    _t: TempDir,
    root: PathBuf,
    proj: PathBuf,
}

const IDX: &str = ".radin/backlog/index.jsonl";

impl W {
    fn new() -> W {
        let t = tempfile::tempdir().unwrap();
        let root = t.path().canonicalize().unwrap();
        let proj = root.join("proj");
        fs::create_dir(&proj).unwrap();
        W { _t: t, root, proj }
    }

    fn git_repo() -> W {
        let w = W::new();
        w.git(&w.proj, &["init", "-q"]);
        w
    }

    fn git(&self, dir: &Path, args: &[&str]) {
        let st = Command::new("git")
            .args(["-c", "user.name=t", "-c", "user.email=t@t"])
            .args(args)
            .current_dir(dir)
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .env("GIT_CONFIG_SYSTEM", "/dev/null")
            .status()
            .unwrap();
        assert!(st.success(), "git {args:?}");
    }

    fn run_in(&self, dir: &Path, args: &[&str], stdin: &str, env: &[(&str, &str)]) -> Run {
        let mut cmd = Command::new(env!("CARGO_BIN_EXE_radin"));
        cmd.arg("backlog")
            .args(args)
            .current_dir(dir)
            .envs(env.iter().copied());
        common::isolate(&mut cmd, &self.root.join("home"));
        cmd.env_remove("RADIN_HOST")
            .env_remove("RADIN_EPIC_THRESHOLD")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        for (k, v) in env {
            cmd.env(k, v);
        }
        let mut child = cmd.spawn().unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(stdin.as_bytes())
            .unwrap();
        let o = child.wait_with_output().unwrap();
        Run {
            code: o.status.code().unwrap(),
            out: String::from_utf8(o.stdout).unwrap(),
            err: String::from_utf8(o.stderr).unwrap(),
        }
    }

    fn cli(&self, args: &[&str], stdin: &str) -> Run {
        self.run_in(&self.proj, args, stdin, &[])
    }

    fn ok(&self, args: &[&str], stdin: &str) -> String {
        let r = self.cli(args, stdin);
        assert_eq!(r.code, 0, "{args:?}: {}", r.err);
        r.out
    }

    fn fails(&self, args: &[&str], stdin: &str) -> Run {
        let r = self.cli(args, stdin);
        assert_ne!(r.code, 0, "{args:?} should fail");
        r
    }

    fn index(&self) -> String {
        fs::read_to_string(self.proj.join(IDX)).unwrap_or_default()
    }

    fn line(&self, id: &str) -> String {
        let key = format!("\"id\":\"{id}\"");
        self.index()
            .lines()
            .find(|l| l.contains(&key))
            .unwrap()
            .to_string()
    }

    fn tasks(&self) -> PathBuf {
        self.proj.join(".radin/backlog/tasks")
    }

    fn set_index(&self, text: &str) {
        fs::create_dir_all(self.tasks()).unwrap();
        fs::write(self.proj.join(IDX), text).unwrap();
    }

    fn write_plan(&self, rel: &str, outcome: &str) {
        let p = self.proj.join(rel);
        fs::create_dir_all(p.parent().unwrap()).unwrap();
        fs::write(&p, plan_text(outcome)).unwrap();
    }
}

fn plan_text(outcome: &str) -> String {
    let mut s = format!("## Outcome\n{outcome}\n");
    for h in ["Decisions", "Alternatives rejected"] {
        s += &format!("## {h}\nn/a: test\n");
    }
    s += "## Changes\n- `a.txt` - edit\n  You see: a\n";
    for h in [
        "Reach and reuse",
        "Rubrics triggered",
        "Modes and states",
        "Order",
    ] {
        s += &format!("## {h}\nn/a: test\n");
    }
    s += "## Testing\n- [ ] run it\n";
    for h in ["Risks", "Out of scope"] {
        s += &format!("## {h}\nn/a: test\n");
    }
    s
}

fn prioritized(w: &W) {
    w.set_index(
        r#"{"id":"high","category":"feat","title":"high","file":"tasks/high.md","priority":21}
{"id":"mid-a","category":"feat","title":"mid a","file":"tasks/mid-a.md","priority":5}
{"id":"mid-b","category":"feat","title":"mid b","file":"tasks/mid-b.md","priority":5}
{"id":"low","category":"fix","title":"low","file":"tasks/low.md","priority":1}
"#,
    );
}

fn epic_backlog(w: &W) {
    fs::create_dir_all(w.tasks().join("big")).unwrap();
    fs::create_dir_all(w.tasks().join("small")).unwrap();
    w.set_index(
        r#"{"id":"loose","category":"feat","title":"loose","file":"tasks/loose.md","priority":21}
{"id":"s-1","category":"feat","title":"s 1","file":"tasks/small/s-1.md","priority":13}
{"id":"b-1","category":"feat","title":"b 1","file":"tasks/big/b-1.md","priority":8}
{"id":"b-2","category":"feat","title":"b 2","file":"tasks/big/b-2.md","priority":8}
{"id":"b-3","category":"feat","title":"b 3","file":"tasks/big/b-3.md","priority":5}
"#,
    );
}

fn ids(list_out: &str) -> Vec<&str> {
    list_out
        .lines()
        .map(|l| l.split('\x1f').next().unwrap())
        .collect()
}

#[test]
fn add_writes_meta_flags_with_the_entry_and_rejects_a_bad_one_whole() {
    let w = W::new();
    w.ok(&["add", "fix", "base"], "b\n");
    let id = w.ok(
        &[
            "add",
            "feat",
            "t",
            "--acceptance",
            "a",
            "--acceptance",
            "b",
            "--planning",
            "needed",
            "--location",
            "x.c:3",
            "--deps",
            "base",
        ],
        "body\n",
    );
    assert_eq!(id, "t\n");
    let meta = w.ok(&["meta", "t"], "");
    for l in [
        "acceptance\ta",
        "acceptance\tb",
        "location\tx.c:3",
        "planning\tneeded",
    ] {
        assert!(meta.contains(l), "{meta}");
    }
    assert!(w.ok(&["list"], "").contains("base"));
    assert_ne!(
        w.cli(&["add", "fix", "bad", "--deps", "nope"], "b\n").code,
        0
    );
    assert_eq!(w.ok(&["count"], ""), "2\n");
}

#[test]
fn add_creates_an_index_line_and_a_task_file() {
    let w = W::new();
    let r = w.cli(&["add", "fix", "broken auth"], "Auth times out after 5s.\n");
    assert_eq!(r.code, 0);
    assert_eq!(r.out, "broken-auth\n");
    assert_eq!(
        r.err,
        format!(
            "added \"broken auth\" (id: broken-auth) under fix in {}\n",
            w.proj.join(IDX).display()
        )
    );
    assert_eq!(
        w.ok(&["add", "fix", "broken auth"], "again\n"),
        "broken-auth-2\n"
    );
    let line = w.line("broken-auth");
    for k in [
        r#""id":"broken-auth""#,
        r#""category":"fix""#,
        r#""title":"broken auth""#,
    ] {
        assert!(line.contains(k), "{line}");
    }
    assert_eq!(
        fs::read_to_string(w.tasks().join("broken-auth.md")).unwrap(),
        "Auth times out after 5s.\n"
    );
}

#[test]
fn add_dedupes_ids_from_identical_titles() {
    let w = W::new();
    w.ok(&["add", "fix", "dup title"], "body 1");
    w.ok(&["add", "chore", "dup title"], "body 2");
    assert!(w.tasks().join("dup-title.md").is_file());
    assert!(w.tasks().join("dup-title-2.md").is_file());
}

#[test]
fn add_rejects_unknown_category_and_empty_body() {
    let w = W::new();
    let r = w.fails(&["add", "wat", "title"], "body");
    assert!(
        r.err
            .contains("category must be feat|fix|chore|refactor, got: wat"),
        "{}",
        r.err
    );
    assert!(
        r.err.contains("  add <category> <title>"),
        "usage line follows: {}",
        r.err
    );
    let r = w.fails(&["add", "fix", "title"], "\n");
    assert_eq!(
        r.err,
        "radin-backlog: entry body is empty (pass it on stdin)\n"
    );
}

#[test]
fn add_rejects_a_tab_or_newline_in_the_title() {
    let w = W::new();
    assert_ne!(w.cli(&["add", "feat", "a\tb"], "body").code, 0);
    assert_ne!(w.cli(&["add", "feat", "a\nb"], "body").code, 0);
    assert!(!w.proj.join(IDX).exists());
}

#[test]
fn add_rejects_a_moved_label_a_bad_option_and_a_bad_meta_value() {
    let w = W::new();
    let r = w.fails(&["add", "feat", "t"], "**Plan:** x\n");
    assert!(
        r.err.contains("that label lives on the index line now"),
        "{}",
        r.err
    );
    assert!(w
        .fails(&["add", "feat", "t", "--bogus", "x"], "b")
        .err
        .contains("unknown add option: --bogus"));
    assert!(w
        .fails(&["add", "feat", "t", "--skill"], "b")
        .err
        .contains("--skill needs a name"));
    assert!(w
        .fails(&["add", "feat", "t", "--planning", "soon"], "b")
        .err
        .contains("planning takes only \"needed\""));
    assert!(w
        .fails(&["add", "feat", "t", "--acceptance", "- x"], "b")
        .err
        .contains("acceptance takes one criterion"));
    assert!(w
        .fails(&["add", "feat", "!!!"], "b")
        .err
        .contains("title produced an empty id"));
    assert!(!w.proj.join(IDX).exists());
    assert!(!w.tasks().join("t.md").exists());
}

#[test]
fn add_writes_keys_in_a_fixed_order_with_skills_and_a_stamp() {
    let w = W::git_repo();
    w.ok(&["add", "fix", "base"], "b");
    w.ok(
        &[
            "add",
            "feat",
            "t",
            "--skill",
            "/x",
            "--acceptance",
            "a",
            "--planning",
            "needed",
            "--complexity",
            "low",
            "--location",
            "f:1",
            "--deps",
            "base",
        ],
        "b",
    );
    let line = w.line("t");
    let keys: Vec<&str> = [
        "\"id\"",
        "\"category\"",
        "\"title\"",
        "\"file\"",
        "\"skills\"",
        "\"created\"",
        "\"branch\"",
        "\"acceptance\"",
        "\"planning\"",
        "\"complexity\"",
        "\"location\"",
        "\"depends_on\"",
    ]
    .into();
    let at: Vec<usize> = keys
        .iter()
        .map(|k| line.find(k).unwrap_or_else(|| panic!("{k} in {line}")))
        .collect();
    assert!(at.windows(2).all(|p| p[0] < p[1]), "{line}");
    assert!(line.contains(r#""skills":["Invoke /x to tackle this task."]"#));
}

#[test]
fn find_falls_back_to_exact_title_then_case_insensitive_substring() {
    let w = W::new();
    w.ok(&["add", "feat", "Add OAuth support"], "body");
    assert_eq!(w.ok(&["find", "Add OAuth support"], "").lines().count(), 1);
    assert!(w.ok(&["find", "oauth"], "").contains("Add OAuth support"));
    assert_eq!(
        w.cli(&["find", "nope"], "").err,
        "radin-backlog: no entry matches: nope\n"
    );
    assert!(w
        .fails(&["find"], "")
        .err
        .contains("find needs an id or title"));
}

#[test]
fn add_plan_puts_the_pointer_on_the_tasks_own_entry_only_never_in_a_body() {
    let w = W::new();
    w.ok(&["add", "feat", "planned thing"], "the body");
    w.ok(&["add", "feat", "next thing"], "other body");
    w.write_plan(".radin/plans/planned-thing.md", "x");
    let out = w.ok(
        &["add-plan", "planned thing", ".radin/plans/planned-thing.md"],
        "",
    );
    assert_eq!(out, "plan pointer added to \"planned thing\"\n");
    assert!(w
        .line("planned-thing")
        .contains(r#""plan":[".radin/plans/planned-thing.md"]"#));
    assert!(!w.line("next-thing").contains("\"plan\""));
    assert_eq!(
        fs::read_to_string(w.tasks().join("planned-thing.md")).unwrap(),
        "the body\n"
    );
}

#[test]
fn add_plan_refuses_a_plan_that_fails_plan_lint_and_records_no_pointer() {
    let w = W::new();
    w.ok(&["add", "feat", "bad plan"], "body");
    fs::create_dir_all(w.proj.join(".radin/plans")).unwrap();
    fs::write(
        w.proj.join(".radin/plans/bad-plan.md"),
        "## Outcome\nonly this\n",
    )
    .unwrap();
    let r = w.cli(&["add-plan", "bad plan", ".radin/plans/bad-plan.md"], "");
    assert_eq!(r.code, 1);
    assert!(
        r.err.contains("plan-lint rejects .radin/plans/bad-plan.md"),
        "{}",
        r.err
    );
    assert!(
        r.err.contains("missing or out of order: ## Decisions"),
        "{}",
        r.err
    );
    assert!(!w.line("bad-plan").contains("\"plan\""));
    let r = w.fails(&["add-plan", "bad plan", "nowhere.md"], "");
    assert_eq!(
        r.err,
        "radin-backlog: add-plan: no plan file at nowhere.md\n"
    );
}

#[test]
fn add_plan_appends_pointers_and_records_head_in_a_repo() {
    let w = W::git_repo();
    w.git(&w.proj, &["commit", "-q", "--allow-empty", "-m", "init"]);
    w.ok(&["add", "feat", "split"], "b");
    w.write_plan(".radin/plans/one.md", "1");
    w.write_plan(".radin/plans/two.md", "2");
    w.ok(&["add-plan", "split", ".radin/plans/one.md"], "");
    w.ok(&["add-plan", "split", ".radin/plans/two.md"], "");
    assert!(w
        .line("split")
        .contains(r#""plan":[".radin/plans/one.md",".radin/plans/two.md"]"#));
    let head = fs::read_to_string(w.proj.join(".radin/plans/split.head")).unwrap();
    assert_eq!(head.trim_end().len(), 40, "{head}");
}

#[test]
fn remove_deletes_the_task_file_and_its_index_line() {
    let w = W::new();
    w.ok(&["add", "fix", "keep me"], "body keep");
    w.ok(&["add", "fix", "drop me"], "body drop");
    assert_eq!(
        w.ok(&["remove", "drop me"], ""),
        "removed \"drop me\" (id: drop-me)\n"
    );
    assert!(!w.tasks().join("drop-me.md").exists());
    assert!(w.tasks().join("keep-me.md").exists());
    assert!(!w.index().contains("drop-me"));
    assert!(w.index().contains("keep-me"));
}

#[test]
fn list_meta_carries_each_entrys_meta_lines_on_its_row_joined_by_rs() {
    let w = W::new();
    w.ok(&["add", "feat", "rich task"], "body");
    w.ok(&["add", "fix", "bare task"], "body");
    w.ok(&["set-meta", "rich task", "acceptance", "one", "two"], "");
    let out = w.ok(&["list", "--order", "created", "--meta"], "");
    let rows: Vec<&str> = out.lines().collect();
    assert_eq!(
        rows[0].rsplit('\x1f').next().unwrap(),
        "acceptance\tone\x1eacceptance\ttwo"
    );
    assert_eq!(rows[1].rsplit('\x1f').next().unwrap(), "");
}

#[test]
fn list_created_appends_the_creation_stamp_as_the_last_field() {
    let w = W::new();
    w.ok(&["add", "feat", "dated task"], "body");
    let out = w.ok(&["list", "--order", "created", "--created"], "");
    let stamp = out.lines().next().unwrap().rsplit('\x1f').next().unwrap();
    let b = stamp.as_bytes();
    assert_eq!(b.len(), 20, "{stamp}");
    assert!(
        stamp.starts_with("20") && b[4] == b'-' && b[10] == b'T' && b[19] == b'Z',
        "{stamp}"
    );
}

fn nest_task(w: &W) {
    w.ok(&["add", "feat", "nested thing"], "body");
    fs::create_dir_all(w.tasks().join("epic-a")).unwrap();
    fs::rename(
        w.tasks().join("nested-thing.md"),
        w.tasks().join("epic-a/nested-thing.md"),
    )
    .unwrap();
    w.set_index("{\"id\":\"nested-thing\",\"category\":\"feat\",\"title\":\"nested thing\",\"file\":\"tasks/epic-a/nested-thing.md\"}\n");
}

#[test]
fn append_show_retitle_and_remove_follow_a_non_default_file_value() {
    let w = W::new();
    nest_task(&w);
    w.ok(&["append", "nested-thing"], "appended line");
    assert!(fs::read_to_string(w.tasks().join("epic-a/nested-thing.md"))
        .unwrap()
        .contains("appended line"));
    assert!(w.ok(&["show"], "").contains("appended line"));
    w.ok(&["retitle", "nested-thing", "renamed"], "");
    assert!(w
        .index()
        .contains(r#""file":"tasks/epic-a/nested-thing.md""#));
    w.ok(&["remove", "nested-thing"], "");
    assert!(!w.tasks().join("epic-a/nested-thing.md").exists());
}

#[test]
fn retitle_changes_the_title_but_never_the_id_or_file() {
    let w = W::new();
    w.ok(&["add", "fix", "old name"], "body");
    assert_eq!(
        w.ok(&["retitle", "old-name", "new name"], ""),
        "retitled old-name to \"new name\"\n"
    );
    let idx = w.index();
    for k in [
        r#""id":"old-name""#,
        r#""title":"new name""#,
        r#""file":"tasks/old-name.md""#,
    ] {
        assert!(idx.contains(k), "{idx}");
    }
    assert!(w.tasks().join("old-name.md").is_file());
    assert!(w
        .fails(&["retitle", "old-name", "a\tb"], "")
        .err
        .contains("title must not contain a tab"));
}

#[test]
fn epic_add_creates_the_directory_and_description_epics_and_epic_show_read_it() {
    let w = W::new();
    assert_eq!(
        w.ok(&["epic-add", "auth-overhaul"], "Shared auth context."),
        "created epic auth-overhaul\n"
    );
    assert_eq!(
        fs::read_to_string(w.tasks().join("auth-overhaul/DESCRIPTION.md")).unwrap(),
        "Shared auth context."
    );
    assert_eq!(w.ok(&["epics"], ""), "auth-overhaul\n");
    assert_eq!(
        w.ok(&["epic-show", "auth-overhaul"], ""),
        "Shared auth context."
    );
}

#[test]
fn epic_add_rejects_a_non_slug_id_an_existing_epic_and_a_task_id() {
    let w = W::new();
    w.ok(&["epic-add", "ok"], "d");
    assert!(w
        .fails(&["epic-add", "ok"], "d")
        .err
        .contains("epic already exists: ok"));
    assert!(w
        .fails(&["epic-add", "Not A Slug"], "d")
        .err
        .contains("epic id must be a slug"));
    w.ok(&["add", "feat", "taken"], "b");
    assert!(w
        .fails(&["epic-add", "taken"], "d")
        .err
        .contains("a task already uses that id: taken"));
    assert!(w
        .fails(&["epic-show", "ghost"], "")
        .err
        .contains("no such epic: ghost"));
}

#[test]
fn epic_move_moves_a_task_in_and_back_out_rewriting_the_file_field() {
    let w = W::new();
    w.ok(&["epic-add", "auth"], "ctx");
    w.ok(&["add", "feat", "drifter"], "body");
    assert_eq!(
        w.ok(&["epic-move", "drifter", "auth"], ""),
        "moved drifter to tasks/auth/drifter.md\n"
    );
    assert!(w.tasks().join("auth/drifter.md").is_file());
    assert!(w.index().contains(r#""file":"tasks/auth/drifter.md""#));
    w.ok(&["epic-move", "drifter", "--none"], "");
    assert!(w.tasks().join("drifter.md").is_file());
    assert!(w.index().contains(r#""file":"tasks/drifter.md""#));
    assert!(w
        .fails(&["epic-move", "drifter", "--none"], "")
        .err
        .contains("already there: tasks/drifter.md"));
}

#[test]
fn remove_does_not_leave_an_empty_epic_directory_behind() {
    let w = W::new();
    w.ok(&["epic-add", "auth"], "ctx");
    w.ok(&["add", "feat", "only child"], "body");
    w.ok(&["epic-move", "only-child", "auth"], "");
    w.ok(&["remove", "only-child"], "");
    assert!(!w.tasks().join("auth").exists());
    assert_eq!(w.ok(&["epics"], ""), "");
}

#[test]
fn epic_remove_refuses_child_tasks_then_removes_an_empty_epic() {
    let w = W::new();
    w.ok(&["epic-add", "auth"], "ctx");
    w.ok(&["add", "feat", "kid"], "body");
    w.ok(&["epic-move", "kid", "auth"], "");
    let r = w.fails(&["epic-remove", "auth"], "");
    assert_eq!(
        r.err,
        "radin-backlog: epic auth still holds child tasks; epic-move them out first\n"
    );
    w.ok(&["epic-move", "kid", "--none"], "");
    w.ok(&["epic-add", "empty"], "d");
    assert_eq!(w.ok(&["epic-remove", "empty"], ""), "removed epic empty\n");
    assert!(!w.tasks().join("empty").exists());
}

#[test]
fn set_priority_sets_changes_and_clears_the_priority() {
    let w = W::new();
    w.ok(&["add", "feat", "ranked"], "b");
    assert_eq!(
        w.ok(&["set-priority", "ranked", "8"], ""),
        "priority of ranked set to 8\n"
    );
    assert!(w.index().contains(r#""priority":8"#));
    w.ok(&["set-priority", "ranked", "21"], "");
    assert!(w.index().contains(r#""priority":21"#));
    assert_eq!(
        w.ok(&["set-priority", "ranked", "--none"], ""),
        "priority of ranked set to --none\n"
    );
    assert!(!w.index().contains("\"priority\""));
    assert_ne!(w.cli(&["set-priority", "ranked", "twelve"], "").code, 0);
}

#[test]
fn set_priority_takes_only_the_fibonacci_scale_and_off_scale_stored_values_still_load() {
    let w = W::new();
    w.ok(&["add", "feat", "ranked"], "b");
    let r = w.fails(&["set-priority", "ranked", "7"], "");
    assert!(r.err.contains("1 2 3 5 8 13 21"), "{}", r.err);
    assert!(!w.index().contains("\"priority\""));
    w.ok(&["set-priority", "ranked", "21"], "");
    let off = w.index().replace("\"priority\":21", "\"priority\":70");
    fs::write(w.proj.join(IDX), off).unwrap();
    assert!(w.ok(&["list"], "").contains("70"));
    assert!(w.ok(&["find", "ranked"], "").contains("70"));
}

#[test]
fn set_deps_sets_and_clears_depends_on() {
    let w = W::new();
    for t in ["one", "two", "three"] {
        w.ok(&["add", "feat", t], "b");
    }
    assert_eq!(
        w.ok(&["set-deps", "three", "one,two"], ""),
        "depends_on of three set to one,two\n"
    );
    assert!(w.index().contains(r#""depends_on":["one","two"]"#));
    w.ok(&["set-deps", "three", "--none"], "");
    assert!(!w.index().contains("depends_on"));
}

#[test]
fn set_deps_refuses_an_unknown_id_a_self_reference_and_a_cycle_writing_nothing() {
    let w = W::new();
    w.ok(&["add", "feat", "a task"], "b");
    w.ok(&["add", "feat", "b task"], "b");
    let before = w.index();
    assert_ne!(w.cli(&["set-deps", "a-task", "ghost"], "").code, 0);
    assert_eq!(w.index(), before);
    let r = w.fails(&["set-deps", "a-task", "a-task"], "");
    assert_eq!(
        r.err,
        "radin-backlog: depends_on would create a cycle through a-task\n"
    );
    assert_eq!(w.index(), before);
    w.ok(&["set-deps", "b-task", "a-task"], "");
    let before = w.index();
    assert_ne!(w.cli(&["set-deps", "a-task", "b-task"], "").code, 0);
    assert_eq!(w.index(), before);
}

#[test]
fn set_deps_and_add_deps_resolve_titles_and_refuse_no_match_or_several() {
    let w = W::new();
    w.ok(&["add", "fix", "Broken Auth"], "b");
    w.ok(&["add", "feat", "three"], "b");
    w.ok(&["set-deps", "three", "Broken Auth"], "");
    assert!(w.index().contains(r#""depends_on":["broken-auth"]"#));
    w.ok(&["add", "feat", "four", "--deps", "Broken Auth"], "b");
    assert!(w.line("four").contains(r#""depends_on":["broken-auth"]"#));
    let r = w.fails(&["add", "feat", "five", "--deps", "ghost"], "b");
    assert!(r.err.contains("no entry matches: ghost"), "{}", r.err);
    w.ok(&["add", "fix", "Broken Auth"], "b");
    let before = w.index();
    let r = w.fails(&["set-deps", "three", "Broken Auth"], "");
    assert!(r.err.contains("matches 2 entries"), "{}", r.err);
    assert!(
        r.err
            .contains("broken-auth-2\tfix\tBroken Auth\ttasks/broken-auth-2.md"),
        "{}",
        r.err
    );
    assert_eq!(w.index(), before);
}

#[test]
fn remove_prunes_the_removed_id_from_other_entries_depends_on() {
    let w = W::new();
    w.ok(&["add", "feat", "keeper"], "b");
    w.ok(&["add", "feat", "doomed"], "b");
    w.ok(&["set-deps", "keeper", "doomed"], "");
    w.ok(&["remove", "doomed"], "");
    assert!(!w.index().contains("depends_on"));
    assert_eq!(
        w.ok(&["find", "keeper"], ""),
        "keeper\tfeat\tkeeper\ttasks/keeper.md\t\t\n"
    );
}

#[test]
fn set_category_and_epic_move_preserve_priority_and_depends_on() {
    let w = W::new();
    w.ok(&["add", "feat", "anchor"], "b");
    w.ok(&["add", "feat", "mover"], "b");
    w.ok(&["set-priority", "mover", "8"], "");
    w.ok(&["set-deps", "mover", "anchor"], "");
    w.ok(&["epic-add", "grouped"], "ctx");
    assert_eq!(
        w.ok(&["set-category", "mover", "fix"], ""),
        "moved \"mover\" to fix\n"
    );
    w.ok(&["epic-move", "mover", "grouped"], "");
    let line = w.line("mover");
    assert!(
        line.starts_with(
            r#"{"id":"mover","category":"fix","title":"mover","file":"tasks/grouped/mover.md""#
        ) && line.ends_with(r#""priority":8,"depends_on":["anchor"]}"#),
        "{line}"
    );
}

#[test]
fn a_failed_index_rewrite_leaves_no_tmp_behind_and_keeps_the_index_intact() {
    let w = W::new();
    w.ok(&["add", "feat", "keeper"], "b");
    w.ok(&["add", "feat", "doomed"], "b");
    let before = w.index();
    let dir = w.proj.join(".radin/backlog");
    fs::set_permissions(&dir, fs::Permissions::from_mode(0o555)).unwrap();
    let probe = fs::write(dir.join("probe"), "x");
    let r = w.cli(&["remove", "doomed"], "");
    fs::set_permissions(&dir, fs::Permissions::from_mode(0o755)).unwrap();
    if probe.is_ok() {
        return;
    }
    assert_ne!(r.code, 0);
    assert!(!dir.join("index.jsonl.tmp").exists());
    assert_eq!(w.index(), before);
    assert!(w.tasks().join("doomed.md").is_file());
}

#[test]
fn list_order_created_gives_index_order_the_default_stays_priority() {
    let w = W::new();
    w.ok(&["add", "feat", "added first"], "b");
    w.ok(&["set-priority", "added-first", "1"], "");
    w.ok(&["add", "feat", "added second"], "b");
    w.ok(&["set-priority", "added-second", "13"], "");
    w.ok(&["add", "feat", "unranked"], "b");
    assert_eq!(
        ids(&w.ok(&["list"], "")),
        ["added-second", "added-first", "unranked"]
    );
    assert_eq!(
        ids(&w.ok(&["list", "--order", "priority"], "")),
        ["added-second", "added-first", "unranked"]
    );
    assert_eq!(
        ids(&w.ok(&["list", "--order", "created"], "")),
        ["added-first", "added-second", "unranked"]
    );
    let r = w.fails(&["list", "--order", "bogus"], "");
    assert!(
        r.err
            .contains("--order must be created|priority, got: bogus")
            && r.err.contains("  list "),
        "{}",
        r.err
    );
    assert!(w
        .fails(&["list", "--wat"], "")
        .err
        .contains("unknown list option: --wat"));
}

#[test]
fn a_title_carrying_a_json_looking_key_and_a_backslash_round_trips() {
    let w = W::new();
    let evil = r#"evil "file":"tasks/hack.md" and back\slash"#;
    w.ok(&["add", "chore", evil], "escaping fixture");
    w.ok(&["add", "feat", "innocent"], "b");
    let list = w.ok(&["list"], "");
    assert!(list.contains(evil));
    assert!(list.contains("tasks/evil-file-tasks-hack-md-and-back-slash.md"));
    assert!(w.ok(&["find", evil], "").contains(evil));
    let f = w.ok(&["find", r"back\slash"], "");
    assert!(f.contains(evil) && !f.contains("innocent"));
}

#[test]
fn order_moves_a_dependency_up_and_leaves_every_other_position_alone() {
    let w = W::new();
    prioritized(&w);
    w.ok(&["set-deps", "mid-a", "low"], "");
    assert_eq!(
        w.ok(&["order", "--report"], ""),
        "1. high (id: high)\n2. low (id: low)\n3. mid a (id: mid-a)\n4. mid b (id: mid-b)\ndependency override: low moved above mid-a (priority 5)\n"
    );
}

#[test]
fn order_report_prints_no_override_line_when_no_edge_is_violated() {
    let w = W::new();
    prioritized(&w);
    w.ok(&["set-deps", "low", "high"], "");
    let out = w.ok(&["order", "--report"], "");
    assert_eq!(out.lines().count(), 4);
    assert!(!out.contains("dependency override"));
}

#[test]
fn scope_returns_an_epics_tasks_plus_outside_dependencies_and_exits_1_on_no_match_2_on_several() {
    let w = W::new();
    fs::create_dir_all(w.tasks().join("ep")).unwrap();
    w.set_index(
        r#"{"id":"out","category":"feat","title":"outside dep","file":"tasks/out.md"}
{"id":"a","category":"feat","title":"alpha thing","file":"tasks/ep/a.md","depends_on":["out"]}
{"id":"b","category":"feat","title":"beta thing","file":"tasks/ep/b.md"}
{"id":"c","category":"feat","title":"gamma thing","file":"tasks/c.md"}
"#,
    );
    assert_eq!(
        w.ok(&["scope", "ep"], ""),
        "ids\tout,a,b\ndependencies\tout\n"
    );
    assert_eq!(w.ok(&["scope", "c"], ""), "ids\tc\n");
    let r = w.cli(&["scope", "nothing-here"], "");
    assert_eq!(
        (r.code, r.err.as_str()),
        (1, "radin-backlog: no entry matches: nothing-here\n")
    );
    let r = w.cli(&["scope", "thing"], "");
    assert_eq!(r.code, 2);
    assert!(
        r.err.contains("candidate\ta\tfeat\talpha thing"),
        "{}",
        r.err
    );
}

#[test]
fn order_first_and_only_derive_the_deferred_set_two_selectors_are_refused() {
    let w = W::new();
    prioritized(&w);
    let steps = |args: &[&str]| -> Vec<String> {
        let mut a = vec!["order", "--steps"];
        a.extend_from_slice(args);
        w.ok(&a, "").lines().map(String::from).collect()
    };
    let l = steps(&["--first"]);
    assert_eq!(l[0], "high\t1\t\tpending");
    assert_eq!(l[1], "mid-a\t2\t\tdeferred");
    assert_eq!(l[3], "low\t4\t\tdeferred");
    let l = steps(&["--only", "mid-b,low"]);
    assert_eq!(
        (l[0].as_str(), l[2].as_str(), l[3].as_str()),
        (
            "high\t1\t\tdeferred",
            "mid-b\t3\t\tpending",
            "low\t4\t\tpending"
        )
    );
    assert_ne!(w.cli(&["order", "--steps", "--only", "nope"], "").code, 0);
    let l = steps(&["--only", "4,mid-a"]);
    assert_eq!(
        (l[0].as_str(), l[1].as_str(), l[3].as_str()),
        (
            "high\t1\t\tdeferred",
            "mid-a\t2\t\tpending",
            "low\t4\t\tpending"
        )
    );
    let r = w.cli(&["order", "--steps", "--only", "9"], "");
    assert_eq!(
        (r.code, r.err.as_str()),
        (1, "radin-backlog: --only: no task at that order number\n")
    );
    assert_eq!(steps(&["--only", "mid b"])[2], "mid-b\t3\t\tpending");
    let r = w.cli(&["order", "--steps", "--only", "mid"], "");
    assert_eq!(r.code, 2);
    assert!(r.err.contains("candidate\tmid-a"), "{}", r.err);
    assert_ne!(
        w.cli(&["order", "--steps", "--only", "low", "--first"], "")
            .code,
        0
    );
}

#[test]
fn order_only_keeps_a_trailing_t_on_an_id() {
    let w = W::new();
    w.set_index(
        r#"{"id":"disk-budget","category":"feat","title":"disk budget","file":"tasks/disk-budget.md","priority":3}
{"id":"other","category":"feat","title":"other","file":"tasks/other.md","priority":1}
"#,
    );
    let out = w.ok(&["order", "--steps", "--only", "disk-budget"], "");
    assert_eq!(out.lines().next().unwrap(), "disk-budget\t1\t\tpending");
}

#[test]
fn order_rank_needed_rank_and_infer_deps_report_each_error_string() {
    let w = W::new();
    w.set_index(
        r#"{"id":"p","category":"feat","title":"p","file":"tasks/p.md","priority":5}
{"id":"u1","category":"feat","title":"u1","file":"tasks/u1.md"}
{"id":"u2","category":"feat","title":"u2","file":"tasks/u2.md"}
{"id":"d","category":"feat","title":"d","file":"tasks/d.md","priority":1,"depends_on":["p"]}
"#,
    );
    let r = w.cli(&["order", "--rank-needed"], "");
    assert_eq!((r.code, r.out.as_str()), (0, "u1\nu2\n"));
    let err = |args: &[&str]| w.fails(&[&["order", "--steps"][..], args].concat(), "").err;
    assert_eq!(err(&["--rank", "u1"]), "radin-backlog: --rank must name every unset-priority id exactly once: 2 expected, 1 given\n");
    assert_eq!(
        err(&["--rank", "p,u1,u2"]),
        "radin-backlog: --rank: p already has a priority\n"
    );
    assert_eq!(
        err(&["--rank", "zz"]),
        "radin-backlog: --rank: no such task id: zz\n"
    );
    assert_eq!(
        err(&["--rank", "u1,u1"]),
        "radin-backlog: --rank: duplicate id: u1\n"
    );
    assert_eq!(
        err(&["--infer-deps", "u1"]),
        "radin-backlog: --infer-deps needs <id>=<csv>, got: u1\n"
    );
    assert_eq!(
        err(&["--infer-deps", "zz=u1"]),
        "radin-backlog: --infer-deps: no such task id: zz\n"
    );
    assert_eq!(
        err(&["--infer-deps", "d=u1"]),
        "radin-backlog: --infer-deps: d already has depends_on in the index\n"
    );
    assert_eq!(
        err(&["--infer-deps", "u1=u1"]),
        "radin-backlog: --infer-deps: u1 cannot depend on itself\n"
    );
    assert_eq!(
        err(&["--infer-deps", "u1=u2", "--infer-deps", "u2=u1"]),
        "radin-backlog: --infer-deps would create a cycle through u1\n"
    );
    assert_eq!(
        err(&["--defer", "zz"]),
        "radin-backlog: --defer: no such task id: zz\n"
    );
    let out = w.ok(
        &[
            "order",
            "--steps",
            "--rank",
            "u2,u1",
            "--infer-deps",
            "u1=u2",
            "--defer",
            "d",
        ],
        "",
    );
    assert_eq!(
        out,
        "p\t1\t\tpending\nd\t2\tp\tdeferred\nu2\t3\t\tpending\nu1\t4\tu2\tpending\n"
    );
    w.ok(&["set-priority", "u1", "3"], "");
    w.ok(&["set-priority", "u2", "2"], "");
    let r = w.cli(&["order", "--rank-needed"], "");
    assert_eq!(r.code, 1);
}

#[test]
fn order_argument_errors() {
    let w = W::new();
    prioritized(&w);
    let err = |args: &[&str]| w.fails(&[&["order"][..], args].concat(), "").err;
    assert!(err(&[]).contains("order needs one of --rank-needed, --report, --steps"));
    assert!(err(&["--report", "--steps"])
        .contains("order takes exactly one mode, got --report and --steps"));
    assert!(err(&["--steps", "--rank"]).contains("--rank needs a csv of task ids"));
    assert!(err(&["--steps", "--bogus"]).contains("unknown order option: --bogus"));
    assert!(err(&["--steps", "--defer", "low", "--first"])
        .contains("order takes at most one of --only, --first, --defer"));
}

#[test]
fn list_planned_appends_p_for_planned_tasks_and_empty_for_unplanned() {
    let w = W::new();
    w.ok(&["add", "feat", "planned one"], "body");
    w.ok(&["add", "feat", "unplanned one"], "body");
    w.write_plan(".radin/plans/planned-one.md", "x");
    w.ok(
        &["add-plan", "planned-one", ".radin/plans/planned-one.md"],
        "",
    );
    let out = w.ok(&["list", "--planned"], "");
    let rows: Vec<&str> = out.lines().collect();
    assert_eq!(rows.len(), 2);
    assert!(rows[0].ends_with("\x1fP"));
    assert!(rows[1].ends_with('\x1f') && !rows[1].ends_with("\x1fP"));
}

#[test]
fn field_and_find_in_a_linked_worktree_with_an_empty_backlog_read_the_main_checkouts_entry() {
    let w = W::git_repo();
    w.ok(&["add", "fix", "base"], "b");
    w.git(&w.proj, &["commit", "-q", "--allow-empty", "-m", "init"]);
    let wt = w.root.join("wt");
    w.git(&w.proj, &["worktree", "add", "-q", wt.to_str().unwrap()]);
    let r = w.run_in(&wt, &["field", "base", "TASK_FILE"], "", &[]);
    assert_eq!(r.code, 0, "{}", r.err);
    assert_eq!(r.out, format!("{}\n", w.tasks().join("base.md").display()));
    assert_eq!(w.run_in(&wt, &["find", "base"], "", &[]).code, 0);
}

#[test]
fn skills_dropped_drops_only_the_hosts_own_grilling_spelling() {
    let w = W::new();
    for h in ["claude", "agents"] {
        let r = w.run_in(
            &w.proj,
            &[
                "add",
                "fix",
                &format!("a {h}"),
                "--skill",
                "/mattpocock-skills:grilling",
                "--skill",
                "/grilling",
            ],
            "b",
            &[("RADIN_HOST", h)],
        );
        assert_eq!(r.code, 0, "{}", r.err);
    }
    let r = w.cli(&["field", "a-claude", "SKILLS_DROPPED"], "");
    assert_eq!(
        (r.code, r.out.as_str()),
        (
            0,
            "Invoke /mattpocock-skills:grilling to tackle this task.\n"
        )
    );
    let r = w.run_in(
        &w.proj,
        &["field", "a-agents", "SKILLS_DROPPED"],
        "",
        &[("RADIN_HOST", "agents")],
    );
    assert_eq!(
        (r.code, r.out.as_str()),
        (0, "Invoke /grilling to tackle this task.\n")
    );
    let r = w.cli(&["field", "a-claude", "SKILLS"], "");
    assert_eq!(r.out, "Invoke /grilling to tackle this task.\n");
}

#[test]
fn suggest_names_the_epic_holding_the_highest_priority_task_and_recommends_it_only_above_the_threshold(
) {
    let w = W::new();
    epic_backlog(&w);
    assert_eq!(w.ok(&["suggest"], ""), "tasks\t5\tall\nepic\tsmall\t1\n");
    let r = w.run_in(&w.proj, &["suggest"], "", &[("RADIN_EPIC_THRESHOLD", "4")]);
    assert_eq!(r.out.lines().next().unwrap(), "tasks\t5\tepic");
    let r = w.run_in(&w.proj, &["suggest"], "", &[("RADIN_EPIC_THRESHOLD", "0x")]);
    assert_eq!(
        r.err,
        "radin-backlog: suggest: RADIN_EPIC_THRESHOLD needs a positive integer, got: 0x\n"
    );
}

#[test]
fn suggest_prints_no_epic_line_when_the_backlog_holds_no_epic_and_swallows_an_order_failure() {
    let w = W::new();
    prioritized(&w);
    assert_eq!(w.ok(&["suggest"], ""), "tasks\t4\tall\n");
    let r = w.cli(&["suggest", "--rank", "ghost"], "");
    assert_eq!(r.code, 0);
    assert_eq!(r.out, "tasks\t4\tall\n");
    assert!(
        r.err.contains("--rank: no such task id: ghost"),
        "{}",
        r.err
    );
}

#[test]
fn plan_target_reports_each_route_by_exit_code() {
    let w = W::new();
    w.ok(&["add", "feat", "alpha thing"], "b");
    w.ok(&["add", "feat", "alpha other"], "b");
    w.ok(&["add", "feat", "solo"], "b");
    let r = w.cli(&["plan-target", "solo"], "");
    let (tasks, plans) = (
        w.tasks().join("solo.md"),
        w.proj.join(".radin/plans/solo.md"),
    );
    assert_eq!(r.code, 0);
    assert_eq!(
        r.out,
        format!(
            "id\tsolo\ntitle\tsolo\ntask_file\t{}\nplan_file\t{}\n",
            tasks.display(),
            plans.display()
        )
    );
    let r = w.cli(&["plan-target", "solo", "Part One!"], "");
    assert!(r.out.ends_with("plans/solo-part-one.md\n"), "{}", r.out);
    assert_eq!(w.cli(&["plan-target", "ghost"], "").code, 1);
    let r = w.cli(&["plan-target", "alpha"], "");
    assert_eq!(r.code, 2);
    assert!(r.err.contains("candidate\talpha-thing"), "{}", r.err);
    w.write_plan(".radin/plans/solo.md", "x");
    w.ok(&["add-plan", "solo", ".radin/plans/solo.md"], "");
    w.ok(
        &["set-meta", "solo", "facts", ".radin/state/facts/solo.md"],
        "",
    );
    let r = w.cli(&["plan-target", "solo"], "");
    assert_eq!(r.code, 3);
    assert!(
        r.out
            .contains("facts\t.radin/state/facts/solo.md\nplan\t.radin/plans/solo.md\n"),
        "{}",
        r.out
    );
}

#[test]
fn files_unions_changes_across_pointers_and_ignores_fences_and_nesting() {
    let w = W::new();
    w.ok(&["add", "feat", "multi"], "b");
    let plan = |a: &str, b: &str| {
        format!("## Outcome\n- `not/a/change.sh` - x\n\n## Changes\n\n- `{a}` - first\n- `{b}` - second\n  - `nested/x` - ignored\n\n```\n- `in/fence.sh` - s\n```\n\n## Order\n- `order/item` - x\n")
    };
    fs::create_dir_all(w.proj.join("p")).unwrap();
    fs::write(w.proj.join("p/one.md"), plan("a.rs", "b.rs")).unwrap();
    fs::write(w.proj.join("p/two.md"), plan("b.rs", "c.rs")).unwrap();
    assert_eq!(w.ok(&["files", "p/one.md"], ""), "a.rs\nb.rs\n");
    w.ok(
        &[
            "set-meta",
            "multi",
            "plan",
            "p/one.md",
            "p/two.md",
            "p/gone.md",
        ],
        "",
    );
    let r = w.cli(&["files", "multi"], "");
    assert_eq!(r.out, "a.rs\nb.rs\nc.rs\n");
    assert_eq!(r.err, "radin-backlog: plan file not found: p/gone.md\n");
    w.ok(&["add", "feat", "none"], "b");
    let r = w.cli(&["files", "none"], "");
    assert_eq!((r.code, r.out.as_str()), (1, ""));
}

#[test]
fn plan_lint_prints_each_defect_and_exits_1() {
    let w = W::new();
    fs::write(w.proj.join("ok.md"), plan_text("x")).unwrap();
    let r = w.cli(&["plan-lint", "ok.md"], "");
    assert_eq!((r.code, r.out.as_str()), (0, ""));
    fs::write(w.proj.join("bad.md"), "## Outcome\nonly this\n").unwrap();
    let r = w.cli(&["plan-lint", "bad.md"], "");
    assert_eq!(r.code, 1);
    assert!(
        r.out.starts_with("missing or out of order: ## Decisions\n"),
        "{}",
        r.out
    );
    assert!(r
        .out
        .contains("changes: no `path` entry\ntesting: no - [ ] check box\n"));
    assert!(w
        .fails(&["plan-lint", "nope.md"], "")
        .err
        .contains("plan-lint needs a plan file"));
}

#[test]
fn open_decisions_lists_only_entries_after_the_last_decision() {
    let w = W::new();
    w.ok(&["add", "feat", "dec"], "b");
    w.ok(&["append", "dec"], "**Open decision:** old one\n**Decision:** settled\n**Open decision:** a or b?\n**Open decision:**c?");
    assert_eq!(w.ok(&["open-decisions", "dec"], ""), "a or b?\nc?\n");
    w.ok(&["append", "dec"], "**Decision:** all settled");
    let r = w.cli(&["open-decisions", "dec"], "");
    assert_eq!((r.code, r.out.as_str()), (1, ""));
}

#[test]
fn fact_appends_the_line_and_long_sets_facts() {
    let w = W::new();
    w.ok(&["add", "feat", "fx"], "body");
    assert_eq!(
        w.ok(&["fact", "fx", "measured", "ran it"], ""),
        "fact recorded on \"fx\"\n"
    );
    w.ok(
        &[
            "fact",
            "fx",
            "guess",
            "maybe",
            "--long",
            ".radin/state/facts/fx.md",
        ],
        "",
    );
    let body = fs::read_to_string(w.tasks().join("fx.md")).unwrap();
    assert_eq!(
        body,
        "body\n\n**Fact:** [measured] ran it\n\n**Fact:** [guess] maybe\n"
    );
    assert!(w
        .line("fx")
        .contains(r#""facts":".radin/state/facts/fx.md""#));
    assert!(w
        .fails(&["fact", "fx", "sure", "x"], "")
        .err
        .contains("label must be measured|inferred|guess, got: sure"));
    assert!(w
        .fails(&["fact", "fx", "guess", ""], "")
        .err
        .contains("fact line is empty"));
    assert!(w
        .fails(&["fact", "fx", "guess", "x", "--bogus"], "")
        .err
        .contains("unknown argument: --bogus"));
    assert!(w
        .fails(&["fact", "fx", "guess", "x", "--long"], "")
        .err
        .contains("--long needs a path"));
}

#[test]
fn field_prints_each_placeholder_and_exits_1_with_nothing_when_empty() {
    let w = W::new();
    w.ok(&["add", "feat", "flat"], "flat body");
    w.ok(
        &[
            "add",
            "fix",
            "kid",
            "--acceptance",
            "one",
            "--acceptance",
            "two",
            "--location",
            "a.c:1",
            "--skill",
            "/ok-skill",
            "--skill",
            "/radin-batch",
            "--complexity",
            "high",
            "--planning",
            "needed",
        ],
        "kid body",
    );
    w.ok(&["epic-add", "ep"], "epic ctx");
    w.ok(&["epic-move", "kid", "ep"], "");
    let f = |id: &str, n: &str| w.cli(&["field", id, n], "");
    assert_eq!(f("kid", "TASK_ID").out, "kid\n");
    assert_eq!(f("kid", "CATEGORY").out, "fix\n");
    assert_eq!(f("kid", "TASK_BODY").out, "kid body\n");
    assert_eq!(f("kid", "EPIC_CONTEXT").out, "epic ctx");
    assert_eq!(f("kid", "LOCATION").out, "a.c:1\n");
    assert_eq!(f("kid", "COMPLEXITY").out, "high\n");
    assert_eq!(f("kid", "PLANNING").out, "needed\n");
    assert_eq!(
        f("kid", "SKILLS").out,
        "Invoke /ok-skill to tackle this task.\n"
    );
    assert_eq!(
        f("kid", "SKILLS_DROPPED").out,
        "Invoke /radin-batch to tackle this task.\n"
    );
    assert_eq!(
        f("kid", "ACCEPTANCE").out,
        "1b. This task states its own acceptance criteria. They are the bar it is\n   measured against, so satisfy every one of them:\n   - one\n   - two\n"
    );
    assert_eq!(
        f("kid", "PLAN_PATHS").out,
        "none — implement directly from the entry\n"
    );
    assert_eq!(f("kid", "PLAN_PATHS").code, 1);
    for n in [
        "EPIC_CONTEXT",
        "FACTS",
        "LOCATION",
        "ACCEPTANCE",
        "SKILLS_DROPPED",
        "COMPLEXITY",
        "PLANNING",
    ] {
        let r = f("flat", n);
        assert_eq!((r.code, r.out.as_str()), (1, ""), "{n}");
    }
    assert_eq!(f("flat", "SKILLS").out, "none\n");
    fs::write(w.tasks().join("flat.md"), "").unwrap();
    assert_eq!(f("flat", "TASK_BODY").code, 1);
    let r = f("flat", "BOGUS");
    assert!(
        r.err.contains("unknown field name: BOGUS") && r.err.contains("  field "),
        "{}",
        r.err
    );
    assert!(w
        .fails(&["field", "flat"], "")
        .err
        .contains("field needs an id or title and a placeholder name"));
}

#[test]
fn skills_matching_a_saved_workflow_are_dropped() {
    let w = W::new();
    w.ok(
        &[
            "add", "feat", "wf", "--skill", "/my-flow", "--skill", "/other",
        ],
        "b",
    );
    fs::create_dir_all(w.proj.join(".claude/workflows")).unwrap();
    fs::write(w.proj.join(".claude/workflows/my-flow.md"), "x").unwrap();
    assert_eq!(
        w.ok(&["field", "wf", "SKILLS_DROPPED"], ""),
        "Invoke /my-flow to tackle this task.\n"
    );
    assert_eq!(
        w.ok(&["field", "wf", "SKILLS"], ""),
        "Invoke /other to tackle this task.\n"
    );
}

#[test]
fn duplicates_stamps_count_and_meta() {
    let w = W::new();
    assert_eq!(w.ok(&["count"], ""), "0\n");
    assert_eq!(w.cli(&["stamps"], "").out, "");
    w.set_index(
        r#"{"id":"a","category":"feat","title":"same","file":"tasks/a.md","created":"2024-01-01T00:00:00Z","branch":"main"}
{"id":"b","category":"feat","title":"same","file":"tasks/b.md"}
{"id":"a","category":"fix","title":"other","file":"tasks/a2.md","branch":"dev"}
"#,
    );
    assert_eq!(w.ok(&["count"], ""), "3\n");
    let r = w.cli(&["duplicates"], "");
    assert_eq!(
        (r.code, r.out.as_str()),
        (0, "id\ta\ta,a\ntitle\tsame\ta,b\n")
    );
    assert_eq!(
        w.ok(&["stamps"], ""),
        "a\t2024-01-01T00:00:00Z\tmain\nb\t\t\na\t\tdev\n"
    );
    assert_eq!(w.ok(&["stamps", "dev"], ""), "a\t\tdev\n");
    assert!(w
        .fails(&["count", "x"], "")
        .err
        .contains("count takes no argument, got: x"));
    w.set_index("{\"id\":\"u\",\"category\":\"feat\",\"title\":\"u\",\"file\":\"tasks/u.md\"}\n");
    assert_eq!(w.cli(&["duplicates"], "").code, 1);
    assert_eq!(w.ok(&["meta", "u"], ""), "");
}

#[test]
fn set_meta_sets_clears_and_rejects() {
    let w = W::new();
    w.ok(&["add", "feat", "m"], "b");
    assert_eq!(
        w.ok(&["set-meta", "m", "location", "x.c:9"], ""),
        "location of m set\n"
    );
    assert!(w.line("m").contains(r#""location":"x.c:9""#));
    w.ok(&["set-meta", "m", "skills", "/a", "/b"], "");
    assert!(w.line("m").contains(
        r#""skills":["Invoke /a to tackle this task.","Invoke /b to tackle this task."]"#
    ));
    assert_eq!(
        w.ok(&["set-meta", "m", "location", "--none"], ""),
        "location of m cleared\n"
    );
    assert!(!w.line("m").contains("location"));
    w.ok(&["set-meta", "m", "exclusive", "yes"], "");
    assert!(w.ok(&["meta", "m"], "").contains("exclusive\tyes\n"));
    w.ok(&["set-meta", "m", "exclusive", "--none"], "");
    assert!(!w.ok(&["meta", "m"], "").contains("exclusive"));
    for (args, msg) in [
        (
            &["set-meta", "m", "nope", "x"][..],
            "key must be plan|skills|acceptance|facts|location|planning|complexity|exclusive, got: nope",
        ),
        (
            &["set-meta", "m", "location"][..],
            "set-meta needs at least one value, or --none",
        ),
        (
            &["set-meta", "m", "location", "a", "b"][..],
            "location takes exactly one value, got 2",
        ),
        (
            &["set-meta", "m", "acceptance", "--none", "x"][..],
            "--none takes no other value, got: x",
        ),
        (
            &["set-meta", "m", "planning", "later"][..],
            "planning takes only \"needed\", got: later",
        ),
        (
            &["set-meta", "m", "exclusive", "maybe"][..],
            "exclusive takes only \"yes\", got: maybe",
        ),
        (
            &["set-meta", "m", "acceptance", "[ ] x"][..],
            "acceptance takes one criterion as bare text",
        ),
    ] {
        assert!(w.fails(args, "").err.contains(msg), "{args:?}");
    }
}

#[test]
fn reconcile_reports_its_three_outcomes() {
    let w = W::new();
    w.ok(&["add", "feat", "alive"], "b");
    w.ok(&["add", "feat", "done"], "b");
    assert_eq!(
        w.ok(&["reconcile"], ""),
        "reconcile: no completed file, nothing to do\n"
    );
    let completed = w.proj.join(".radin/state/completed.json");
    fs::write(&completed, "{\"id\":\"ghost\"}\n").unwrap();
    assert_eq!(
        w.ok(&["reconcile"], ""),
        "reconcile: no stale completed entries\n"
    );
    fs::write(
        &completed,
        "{\"id\":\"done\"}\nnot json\n{\"id\":\"done\"}\n",
    )
    .unwrap();
    assert_eq!(
        w.ok(&["reconcile"], ""),
        "reconcile: dropped already-completed entries: done\n"
    );
    assert!(!w.index().contains("\"done\"") && w.index().contains("alive"));
    assert!(!w.tasks().join("done.md").exists());
}

#[test]
fn show_prints_categories_and_an_epic_section() {
    let w = W::new();
    w.ok(&["epic-add", "grp"], "group ctx\n");
    w.ok(&["add", "feat", "flat one"], "flat body");
    w.ok(&["add", "feat", "kid one"], "kid body");
    w.ok(&["add", "fix", "a fix"], "fix body");
    w.ok(&["set-meta", "flat one", "acceptance", "crit"], "");
    w.ok(&["epic-move", "kid one", "grp"], "");
    assert_eq!(
        w.ok(&["show"], ""),
        "# Backlog\n\n## feat\n\n### flat one\nacceptance\tcrit\nflat body\n\n### epic: grp\ngroup ctx\n\n#### kid one\nkid body\n\n## fix\n\n### a fix\nfix body\n"
    );
    assert_eq!(
        w.ok(&["show", "fix"], ""),
        "# Backlog\n\n## fix\n\n### a fix\nfix body\n"
    );
    assert!(w
        .fails(&["show", "wat"], "")
        .err
        .contains("category must be feat|fix|chore|refactor, got: wat"));
    assert!(w
        .fails(&["show", "fix", "feat"], "")
        .err
        .contains("show takes at most one category, got: feat"));
    fs::remove_file(w.tasks().join("a-fix.md")).unwrap();
    let r = w.fails(&["show", "fix"], "");
    assert!(
        r.out.starts_with("# Backlog") && r.err.contains("cannot read"),
        "{}",
        r.err
    );
}

#[test]
fn env_prints_quoted_namespace_variables() {
    let w = W::new();
    let spaced = w.root.join("a b");
    fs::create_dir(&spaced).unwrap();
    let r = w.run_in(&spaced, &["env"], "", &[]);
    let base = format!("{}", spaced.display()).replace(' ', "\\ ");
    assert_eq!(
        r.out,
        format!("REPO_ROOT={base}\nNAMESPACE_DIR={base}/.radin\nBACKLOG_INDEX={base}/.radin/backlog/index.jsonl\nBACKLOG_TASKS_DIR={base}/.radin/backlog/tasks\n")
    );
    let r = w.run_in(&spaced, &["env", "--export"], "", &[]);
    assert!(
        r.out.starts_with("export REPO_ROOT=") && r.out.lines().all(|l| l.starts_with("export "))
    );
    assert!(w
        .fails(&["env", "x"], "")
        .err
        .contains("env takes only --export, got: x"));
    assert!(w
        .fails(&["env", "--export", "y"], "")
        .err
        .contains("env takes at most one argument, got: y"));
}

#[test]
fn help_unknown_verbs_and_missing_index() {
    let w = W::new();
    let all = w.ok(&["help"], "");
    assert_eq!(all.lines().count(), 33);
    assert!(all.starts_with("  help [command]"));
    for flag in ["--help", "-h"] {
        assert_eq!(w.ok(&[flag], ""), all);
    }
    let one = w.ok(&["help", "count"], "");
    assert_eq!(one.lines().count(), 1);
    assert!(one.starts_with("  count "));
    assert_eq!(w.ok(&["help", "plan-lint"], "").lines().count(), 1);
    let r = w.fails(&["help", "nope"], "");
    assert!(r
        .err
        .starts_with("radin-backlog: unknown command: nope\n  help [command]"));
    let r = w.fails(&["nope"], "");
    assert_eq!(r.err.lines().count(), 34);
    assert!(r.err.starts_with("radin-backlog: unknown command: nope\n"));
    assert!(w
        .fails(&[], "")
        .err
        .starts_with("radin-backlog: unknown command: <none>\n"));
    assert!(
        !w.proj.join(".radin").exists(),
        "help and unknown verbs create nothing"
    );
    for v in [
        "show",
        "list",
        "meta",
        "order",
        "duplicates",
        "suggest",
        "scope",
    ] {
        let r = w.fails(
            &[v, "x"][..if v == "list" || v == "duplicates" || v == "show" {
                1
            } else {
                2
            }],
            "",
        );
        assert_eq!(
            r.err,
            format!(
                "radin-backlog: no backlog at {}\n",
                w.proj.join(IDX).display()
            ),
            "{v}"
        );
    }
    assert_eq!(w.ok(&["count"], ""), "0\n");
    assert!(w.proj.join(".radin/backlog/tasks").is_dir());
}

#[test]
fn a_line_that_is_not_a_json_object_fails_naming_its_number() {
    let w = W::new();
    w.set_index("{\"id\":\"a\",\"title\":\"a\",\"file\":\"tasks/a.md\"}\n[1]\n");
    assert_eq!(
        w.fails(&["list"], "").err,
        "radin-backlog: index line 2 is not a JSON object\n"
    );
}

#[test]
fn untouched_lines_keep_their_bytes_when_another_entry_changes() {
    let w = W::new();
    let legacy =
        "{ \"id\" : \"old\", \"category\":\"feat\",\"title\":\"old\",\"file\":\"tasks/old.md\" }";
    w.set_index(&format!(
        "{legacy}\n{{\"id\":\"new\",\"category\":\"feat\",\"title\":\"new\",\"file\":\"tasks/new.md\"}}\n"
    ));
    w.ok(&["set-priority", "new", "5"], "");
    assert_eq!(w.index().lines().next().unwrap(), legacy);
}

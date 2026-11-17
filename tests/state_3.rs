mod common;
use common::W;

#[test]
fn prepare_wip_commits_a_dirty_tree_while_the_default_gitignore_hides_radin() {
    let w = W::new();
    w.write("a.txt", "draft\n");
    let r = w.state(&["prepare", "t-one"]);
    assert_eq!(r.code, 0, "{}", r.all());
    assert_eq!(
        w.git(&["log", "-1", "--format=%s"]),
        "wip: update .gitignore, a.txt"
    );
    assert!(w.git(&["status", "--porcelain"]).is_empty());
    assert!(!r.all().contains("ignored by one of your"));
}

#[test]
fn task_report_planned_with_an_exclusive_clause_flags_the_task_and_silence_keeps_it() {
    let w = W::new();
    w.plan_with(&["lib/a.sh"]);
    w.state(&[
        "task-report",
        "t-one",
        "STATUS: PLANNED — ok; complexity low: x; checks: plan-review=pass",
    ]);
    assert!(!w.bl(&["meta", "t-one"], "").out.contains("exclusive"));
    w.state(&[
        "task-report",
        "t-one",
        "STATUS: PLANNED — ok; complexity low: x; exclusive: bench p99; checks: plan-review=pass",
    ]);
    assert!(w
        .bl(&["meta", "t-one"], "")
        .out
        .contains("exclusive\tyes\n"));
    w.state(&["task-report", "t-one", PLANNED]);
    assert!(w
        .bl(&["meta", "t-one"], "")
        .out
        .contains("exclusive\tyes\n"));
    let j = w.read(".radin/state/journal.jsonl");
    for d in [
        "complexity=low exclusive=no plan=yes",
        "complexity=low exclusive=yes plan=yes",
    ] {
        assert!(
            j.contains(&format!(
                "\"event\":\"planned\",\"id\":\"t-one\",\"detail\":\"{d}\""
            )),
            "{d} in {j}"
        );
    }
}

#[test]
fn task_next_prints_no_overlap_line() {
    let w = W::new();
    w.plan_with(&["lib/a.sh"]);
    let r = w.state(&["task-next"]);
    assert_eq!(r.code, 0, "{}", r.all());
    assert!(!r.out.contains("overlap"));
    assert_eq!(
        r.out,
        "id\tt-one\norder\t1\nkind\texecution\nPROMPT execution t-one\n"
    );
}

const PLANNED: &str = "STATUS: PLANNED — ok; complexity low: x; checks: plan-review=pass";

#[test]
fn task_report_rejects_an_all_zero_usage_as_made_up_and_records_no_tokens() {
    let w = W::new();
    w.plan_with(&["lib/a.sh"]);
    let r = w.state(&["task-report", "t-one", PLANNED, "--usage", "planning 0 0 0"]);
    assert_eq!(r.code, 0, "{}", r.all());
    assert_eq!(
        r.err,
        "radin-state: ignoring malformed --usage: planning 0 0 0\n"
    );
}

fn leftover_setup(w: &W) -> std::path::PathBuf {
    w.plan_with(&["a.txt", "dir/b c.txt"]);
    w.git(&["add", ".gitignore"]);
    w.git(&["commit", "-q", "-m", "ignore"]);
    w.steps_init("t-one\t1\t\tpending\n");
    std::path::PathBuf::from(w.task_tree("t-one"))
}

#[test]
fn leftover_file_in_a_pending_tasks_plan_lands_on_its_branch_and_main_stays_clean() {
    let w = W::new();
    let wt = leftover_setup(&w);
    let head = w.git(&["rev-parse", "HEAD"]);
    w.write("a.txt", "draft\n");
    w.write("dir/b c.txt", "spaced\n");
    let r = w.state(&["report"]);
    assert_eq!(r.code, 0, "{}", r.all());
    assert!(
        r.out
            .contains("residual changes moved to their tasks (2 files)."),
        "{}",
        r.out
    );
    assert_eq!(
        w.git_at(&wt, &["log", "-1", "--format=%s"]),
        "wip(t-one): unfinished work, task not complete"
    );
    assert_eq!(w.git_at(&wt, &["show", "HEAD:dir/b c.txt"]), "spaced");
    assert_eq!(w.git(&["rev-parse", "HEAD"]), head);
    assert!(w.git(&["status", "--porcelain"]).is_empty());
    assert!(!w.exists("a.txt"));
}

#[test]
fn leftover_file_of_an_in_progress_task_goes_to_main() {
    let w = W::new();
    let wt = leftover_setup(&w);
    w.state(&["set-status", "t-one", "in_progress", ""]);
    let tip = w.git_at(&wt, &["rev-parse", "HEAD"]);
    w.write("a.txt", "draft\n");
    let r = w.state(&["report"]);
    assert_eq!(r.code, 0, "{}", r.all());
    assert_eq!(w.git_at(&wt, &["rev-parse", "HEAD"]), tip);
    assert_eq!(w.git(&["log", "-1", "--format=%s"]), "wip: update a.txt");
    assert!(
        r.out.contains("residual changes committed as "),
        "{}",
        r.out
    );
}

#[test]
fn leftover_file_goes_to_main_when_the_idle_worktree_has_uncommitted_work() {
    let w = W::new();
    let wt = leftover_setup(&w);
    let tip = w.git_at(&wt, &["rev-parse", "HEAD"]);
    std::fs::write(wt.join("a.txt"), "task edit\n").unwrap();
    w.write("a.txt", "draft\n");
    let r = w.state(&["report"]);
    assert_eq!(r.code, 0, "{}", r.all());
    assert_eq!(w.git_at(&wt, &["rev-parse", "HEAD"]), tip);
    assert_eq!(
        std::fs::read_to_string(wt.join("a.txt")).unwrap(),
        "task edit\n"
    );
    assert_eq!(w.git(&["show", "HEAD:a.txt"]), "draft");
}

#[test]
fn leftover_file_no_plan_names_or_a_branch_changed_goes_to_main_and_a_mixed_dirty_tree_splits() {
    let w = W::new();
    let wt = leftover_setup(&w);
    std::fs::create_dir_all(wt.join("dir")).unwrap();
    std::fs::write(wt.join("dir/b c.txt"), "branch\n").unwrap();
    w.git_at(&wt, &["add", "-A"]);
    w.git_at(&wt, &["commit", "-qm", "feat: branch edit"]);
    w.write("a.txt", "mine\n");
    w.write("dir/b c.txt", "main edit\n");
    w.write("other.txt", "stray\n");
    let r = w.state(&["report"]);
    assert_eq!(r.code, 0, "{}", r.all());
    assert!(
        r.out.contains("and 1 files moved to their tasks."),
        "{}",
        r.out
    );
    assert_eq!(w.git_at(&wt, &["show", "HEAD:a.txt"]), "mine");
    assert_eq!(w.git_at(&wt, &["show", "HEAD:dir/b c.txt"]), "branch");
    let main = w.git(&["show", "--name-only", "--format=", "HEAD"]);
    assert_eq!(
        main.lines().collect::<Vec<_>>(),
        ["dir/b c.txt", "other.txt"]
    );
    assert!(w.git(&["status", "--porcelain"]).is_empty());
}

#[test]
fn reconcile_routes_a_dirty_base_the_same_way() {
    let w = W::new();
    leftover_setup(&w);
    w.write("a.txt", "draft\n");
    w.write("other.txt", "stray\n");
    let r = w.state(&["reconcile"]);
    assert_eq!(r.code, 0, "{}", r.all());
    assert!(
        r.out
            .contains("committed\tt-one\t1 files moved to radin/t-one\n"),
        "{}",
        r.out
    );
    assert!(
        r.out
            .contains("committed\t-\tbase checkout was dirty, saved as "),
        "{}",
        r.out
    );
}

#[test]
fn base_failing_records_and_clears_per_task() {
    let w = W::new();
    assert_eq!(w.state_in(&["base-failing", "t-one"], "").code, 1);
    assert_eq!(
        w.state_in(&["base-failing", "t-one", "--set"], "b\na\na\n\n")
            .code,
        0
    );
    assert_eq!(w.state(&["base-failing", "t-one"]).out, "a\nb\n");
    assert_eq!(w.state(&["base-failing", "t-two"]).code, 1);
    w.state_in(&["base-failing", "t-one", "--set"], "c\n");
    assert_eq!(w.state(&["base-failing", "t-one"]).out, "c\n");
    w.state_in(&["base-failing", "t-one", "--set"], "");
    assert_eq!(w.state(&["base-failing", "t-one"]).code, 1);
    let r = w.state_in(&["base-failing", "a/b", "--set"], "x\n");
    assert_eq!(r.code, 1, "{}", r.all());
    assert!(!w.p.join(".radin/state/base-failing/a").exists());
}

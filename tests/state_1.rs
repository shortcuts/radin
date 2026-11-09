mod common;
use common::{git_in, W};

#[test]
fn task_done_exits_3_for_a_commit_that_changes_a_file_under_radin() {
    let w = W::new();
    w.write(".radin/state/leak", "x\n");
    w.git(&["add", "-f", ".radin/state/leak"]);
    w.git(&["commit", "-q", "-m", "leak"]);
    let r = w.state(&["task-done", "t-one", "HEAD"]);
    assert_eq!(r.code, 3);
    assert!(r.all().contains(".radin/"), "{}", r.all());
}

#[test]
fn task_report_accepts_a_commit_inside_the_plan_paths() {
    let w = W::new();
    w.plan_with(&["lib/a.sh"]);
    w.commit_files(&["lib/a.sh"]);
    let r = w.report_success();
    assert_eq!(r.code, 0);
    assert!(
        r.all()
            .contains(&format!("recorded at {}", w.hash.borrow())),
        "{}",
        r.all()
    );
    assert!(w.tele.borrow().is_empty());
}

#[test]
fn task_report_fails_a_commit_with_a_file_outside_the_plan_and_records_out_of_bounds() {
    let w = W::new();
    w.plan_with(&["lib/a.sh"]);
    w.commit_files(&["lib/a.sh", "lib/other.sh"]);
    let r = w.report_success();
    assert_eq!(r.code, 0);
    assert!(r.out.contains("next\tdebug"), "{}", r.out);
    let tele = w.tele.borrow().clone();
    assert_eq!(tele.len(), 1);
    assert!(tele[0].starts_with("out-of-bounds "), "{}", tele[0]);
    assert!(
        tele[0].contains("plan=lib/a.sh") && tele[0].contains("extra=lib/other.sh"),
        "{}",
        tele[0]
    );
    let r = w.report_success();
    let h = w.hash.borrow().clone();
    assert!(
        r.out.contains(&format!("❌ Task 1 't one' failed: commit {h} changes files outside its plan paths: lib/other.sh (plan: lib/a.sh)")),
        "{}",
        r.out
    );
}

#[test]
fn a_directory_plan_path_matches_by_prefix() {
    let w = W::new();
    w.plan_with(&["lib/"]);
    w.commit_files(&["lib/x.sh"]);
    assert!(w.report_success().out.contains("recorded at"));
}

#[test]
fn a_directory_plan_path_rejects_a_sibling_name_sharing_its_prefix() {
    let w = W::new();
    w.plan_with(&["lib/"]);
    w.commit_files(&["libx.sh"]);
    assert!(w
        .report_failed()
        .out
        .contains("outside its plan paths: libx.sh"));
}

#[test]
fn a_plan_path_that_is_an_existing_directory_without_a_slash_matches_by_prefix() {
    let w = W::new();
    w.write("lib/old.sh", "x\n");
    w.git(&["add", "lib"]);
    w.git(&["commit", "-q", "-m", "old"]);
    w.plan_with(&["lib"]);
    w.commit_files(&["lib/new.sh"]);
    assert!(w.report_success().out.contains("recorded at"));
}

#[test]
fn a_plan_file_path_does_not_accept_a_longer_sibling_name() {
    let w = W::new();
    w.plan_with(&["lib/a"]);
    w.commit_files(&["lib/a", "lib/ab.sh"]);
    assert!(w
        .report_failed()
        .out
        .contains("outside its plan paths: lib/ab.sh"));
}

#[test]
fn a_test_file_outside_the_plan_is_exempt() {
    let w = W::new();
    w.plan_with(&["lib/a.sh"]);
    w.commit_files(&["lib/a.sh", "tests/a.bats"]);
    assert!(w.report_success().out.contains("recorded at"));
}

#[test]
fn a_commit_touching_radin_still_exits_through_task_dones_message() {
    let w = W::new();
    w.plan_with(&["lib/a.sh"]);
    git_in(&w.p, &["add", ".gitignore"]);
    git_in(&w.p, &["commit", "-q", "-m", "ignore"]);
    w.write(".radin/state/leak", "x\n");
    w.git(&["add", "-f", ".radin/state/leak"]);
    w.git(&["commit", "-q", "-m", "leak"]);
    *w.hash.borrow_mut() = w.git(&["rev-parse", "--short=12", "HEAD"]);
    let out = w.report_failed().out;
    assert!(out.contains("changes a file under .radin/"), "{out}");
    assert!(!out.contains("outside its plan paths"), "{out}");
}

#[test]
fn generated_install_sh_passes_when_shipped_is_in_the_plan() {
    let w = W::new();
    w.plan_with(&["SHIPPED"]);
    w.commit_files(&["SHIPPED", "install.sh"]);
    assert!(w.report_success().out.contains("recorded at"));
}

#[test]
fn generated_install_sh_fails_when_shipped_is_not_in_the_plan() {
    let w = W::new();
    w.plan_with(&["lib/a.sh"]);
    w.commit_files(&["lib/a.sh", "install.sh"]);
    assert!(w
        .report_failed()
        .out
        .contains("outside its plan paths: install.sh"));
}

#[test]
fn generated_svg_passes_with_its_mmd_in_the_plan() {
    let w = W::new();
    w.plan_with(&["docs/agents/lifecycle/f.mmd"]);
    w.commit_files(&["docs/agents/lifecycle/f.mmd", "docs/agents/lifecycle/f.svg"]);
    assert!(w.report_success().out.contains("recorded at"));
}

#[test]
fn generated_svg_fails_without_its_mmd_in_the_plan() {
    let w = W::new();
    w.plan_with(&["lib/a.sh"]);
    w.commit_files(&["lib/a.sh", "docs/agents/lifecycle/f.svg"]);
    assert!(w
        .report_failed()
        .out
        .contains("outside its plan paths: docs/agents/lifecycle/f.svg"));
}

#[test]
fn a_task_with_no_plan_paths_passes() {
    let w = W::new();
    w.commit_files(&["lib/any.sh"]);
    w.steps_init("t-one\t1\t\tpending\n");
    assert!(w.report_success().out.contains("recorded at"));
}

#[test]
fn a_failing_telemetry_call_still_fails_the_task_with_the_reason() {
    let w = W::new();
    w.tele_fail.set(true);
    w.plan_with(&["lib/a.sh"]);
    w.commit_files(&["lib/other.sh"]);
    let r = w.report_success();
    assert_eq!(r.code, 0);
    assert!(r.out.contains("next\tdebug"), "{}", r.out);
    assert!(w.tele.borrow().is_empty());
}

#[test]
fn task_fact_keeps_the_evidence_token_and_records_the_long_form_path() {
    let w = W::new();
    let r = w.state(&[
        "task-fact",
        "t-one",
        "STATUS: FOUND — [measured] lib/x.sh sets A=1; long form: /p/state/facts/t-one.md",
    ]);
    assert_eq!(r.out, "task-fact: recorded on t-one\n");
    let task = std::fs::read_to_string(w.task_file("t-one")).unwrap();
    assert!(
        task.contains("**Fact:** [measured] lib/x.sh sets A=1"),
        "{task}"
    );
    assert!(!task.contains("long form"), "{task}");
    assert!(w
        .bl(&["meta", "t-one"], "")
        .out
        .contains("facts\t/p/state/facts/t-one.md"));
}

#[test]
fn task_fact_labels_a_tokenless_answer_a_guess_and_not_found_exits_non_zero() {
    let w = W::new();
    w.state(&["task-fact", "t-one", "STATUS: FOUND — no token here"]);
    assert!(std::fs::read_to_string(w.task_file("t-one"))
        .unwrap()
        .contains("**Fact:** [guess] no token here"));
    assert_ne!(
        w.state(&["task-fact", "t-one", "STATUS: NOT FOUND — looked"])
            .code,
        0
    );
}

#[test]
fn task_diagnosis_records_a_root_cause_from_the_diagnosed_line_not_diagnosed_exits_non_zero() {
    let w = W::new();
    w.state(&[
        "task-diagnosis",
        "t-one",
        "STATUS: DIAGNOSED — [inferred] off by one in f; no siblings",
    ]);
    assert!(std::fs::read_to_string(w.task_file("t-one"))
        .unwrap()
        .contains("**Root cause:** [inferred] off by one in f; no siblings"));
    assert_ne!(
        w.state(&["task-diagnosis", "t-one", "STATUS: NOT DIAGNOSED — nothing"])
            .code,
        0
    );
}

#[test]
fn steps_waiting_prints_id_note_for_each_deferred_entry_and_skips_max_attempts_blocks() {
    let w = W::new();
    w.write(
        ".radin/state/BACKLOG_STEPS.json",
        "{\"id\":\"t-one\",\"order\":1,\"status\":\"blocked\",\"depends_on\":[],\"attempts\":1,\"debugged\":0,\"note\":\"deferred: which db?\"}\n{\"id\":\"t-two\",\"order\":2,\"status\":\"blocked\",\"depends_on\":[],\"attempts\":3,\"debugged\":0,\"note\":\"MAX_ATTEMPTS: crashed\"}\n",
    );
    let r = w.state(&["steps-waiting"]);
    assert_eq!(
        (r.code, r.out.as_str()),
        (0, "t-one\tdeferred: which db?\n")
    );
}

#[test]
fn preflight_prints_one_tagged_line_per_applicable_branch_and_only_empty_on_an_empty_backlog() {
    let w = W::new();
    w.write(
        ".radin/state/BACKLOG_STEPS.json",
        "{\"id\":\"t-one\",\"order\":1,\"status\":\"blocked\",\"depends_on\":[],\"attempts\":1,\"debugged\":0,\"note\":\"deferred: which db?\"}\n{\"id\":\"t-two\",\"order\":2,\"status\":\"in_progress\",\"depends_on\":[],\"attempts\":2,\"debugged\":0,\"note\":\"dispatched\"}\n",
    );
    let r = w.state(&["preflight"]);
    assert_eq!(r.code, 0);
    for line in [
        "session\tmissing",
        "stuck\tt-two\t2\tdispatched",
        "waiting\tt-one\tdeferred: which db?",
        "rank\tt-one",
    ] {
        assert!(r.out.contains(line), "{line} in {}", r.out);
    }
    w.bl(&["remove", "t-one"], "");
    let r = w.state(&["preflight"]);
    assert_eq!((r.code, r.out.as_str()), (0, "empty\n"));
}

#[test]
fn resume_moves_failed_and_retryable_blocked_entries_to_pending_and_keeps_waiting_and_max_attempts_blocks(
) {
    let w = W::new();
    w.write(
        ".radin/state/BACKLOG_STEPS.json",
        "{\"id\":\"t-one\",\"order\":1,\"status\":\"failed\",\"depends_on\":[],\"attempts\":2,\"debugged\":1,\"note\":\"tests red\"}\n\
         {\"id\":\"t-two\",\"order\":2,\"status\":\"blocked\",\"depends_on\":[],\"attempts\":1,\"debugged\":0,\"note\":\"crashed\"}\n\
         {\"id\":\"t-three\",\"order\":3,\"status\":\"blocked\",\"depends_on\":[],\"attempts\":1,\"debugged\":0,\"note\":\"deferred: which db?\"}\n\
         {\"id\":\"t-four\",\"order\":4,\"status\":\"blocked\",\"depends_on\":[],\"attempts\":3,\"debugged\":0,\"note\":\"dispatched 3 times without finishing (MAX_ATTEMPTS) -- needs a human look\"}\n",
    );
    let r = w.state(&["resume"]);
    assert_eq!(
        (r.code, r.out.as_str()),
        (0, "t-one\tfailed\nt-two\tblocked\n")
    );
    let list = w.state(&["steps-list"]).out;
    for row in [
        "t-one\t1\tpending\t2\t\n",
        "t-two\t2\tpending\t1\t\n",
        "t-three\t3\tblocked\t1\tdeferred: which db?\n",
        "t-four\t4\tblocked\t3\t",
    ] {
        assert!(list.contains(row), "{row:?} in {list:?}");
    }
    assert!(
        w.read(".radin/state/BACKLOG_STEPS.json")
            .contains("\"debugged\":1"),
        "debugged flag kept"
    );
}

#[test]
fn an_unknown_state_command_lists_every_subcommand_in_its_usage_line_steps_open_included() {
    let w = W::new();
    let r = w.state(&["no-such-command"]);
    assert_ne!(r.code, 0);
    assert!(
        r.err
            .starts_with("radin-state: unknown command: no-such-command (teardown|steps-init|"),
        "{}",
        r.err
    );
    for name in [
        "steps-open",
        "steps-list",
        "wave",
        "steps-waiting",
        "answered",
        "retry",
    ] {
        assert!(r.err.contains(name), "{name}");
    }
    assert!(w.state(&[]).err.contains("unknown command: <none> ("));
}

#[test]
fn reconcile_lands_every_leftover_branch_but_a_live_one_and_files_a_follow_up_for_unfinished_work()
{
    let w = W::new();
    let base = w.base();
    w.bl(&["add", "fix", "t two", "--deps", "t-one"], "body\n");
    w.bl(&["add", "fix", "t three"], "body\n");
    w.steps_init("t-one\t1\t\tpending\nt-two\t2\tt-one\tpending\nt-three\t3\t\tpending\n");
    w.state(&["set-status", "t-one", "failed", "tests red"]);
    w.state(&["set-status", "t-three", "in_progress", ""]);
    for b in ["t-one", "t-three", "b", "c"] {
        w.git(&["checkout", "-q", "-b", &format!("radin/{b}"), &base]);
        w.write(&format!("{b}.txt"), &format!("{b}\n"));
        w.git(&["add", &format!("{b}.txt")]);
        w.git(&["commit", "-q", "-m", &format!("feat: {b}")]);
    }
    w.git(&["checkout", "-q", &base]);
    w.git(&["branch", "radin/e"]);
    let (wc, we) = (w.work.join("proj-c"), w.work.join("proj-e"));
    w.git(&["worktree", "add", "-q", wc.to_str().unwrap(), "radin/c"]);
    w.git(&["worktree", "add", "-q", we.to_str().unwrap(), "radin/e"]);
    std::fs::write(wc.join("dirt.txt"), "dirt\n").unwrap();
    assert!(w.state(&["preflight"]).out.contains("leftovers"));
    let r = w.state(&["reconcile"]);
    assert_eq!(r.code, 0, "{}", r.all());
    for line in [
        "merged\tradin/t-one\t",
        "merged\tradin/b\t",
        "merged\tradin/c\t",
        "skipped\tradin/t-three\tin progress",
        "removed\tradin/e",
    ] {
        assert!(r.out.contains(line), "{line} in {}", r.out);
    }
    for b in ["t-one", "b", "c", "e"] {
        assert!(
            w.git(&["branch", "--list", &format!("radin/{b}")])
                .is_empty(),
            "{b}"
        );
    }
    assert!(!w.git(&["branch", "--list", "radin/t-three"]).is_empty());
    assert!(!wc.exists() && !we.exists());
    assert!(w.exists("t-one.txt") && w.exists("dirt.txt"));
    assert!(w
        .state(&["completed-list"])
        .out
        .lines()
        .any(|l| l.starts_with("t-one\t")));
    let fu = w
        .bl(&["find", "Finish: t one"], "")
        .out
        .split('\t')
        .next()
        .unwrap()
        .to_string();
    assert!(!fu.is_empty());
    let task = std::fs::read_to_string(w.task_file(&fu)).unwrap();
    assert!(
        task.contains("t-one") && task.contains("tests red"),
        "{task}"
    );
    let two = w.bl(&["find", "t-two"], "").out;
    assert_eq!(two.lines().next().unwrap().split('\t').nth(5).unwrap(), fu);
    assert!(!w.state(&["reconcile"]).out.contains("merged"));
}

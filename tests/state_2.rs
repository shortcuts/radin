mod common;
use common::W;
use std::fs;

#[test]
fn a_done_task_whose_branch_is_gone_is_recorded_done_once_its_work_is_on_the_base_else_its_branch_comes_back_and_lands(
) {
    let w = W::new();
    let base = w.base();
    w.bl(&["add", "fix", "t two"], "body\n");
    for t in ["t-one", "t-two"] {
        w.git(&["checkout", "-q", "-b", &format!("radin/{t}"), &base]);
        w.write(&format!("{t}.txt"), &format!("{t}\n"));
        w.git(&["add", &format!("{t}.txt")]);
        w.git(&["commit", "-q", "-m", &format!("feat: {t}")]);
        let h = w.git(&["rev-parse", "--short=12", "HEAD"]);
        w.write(&format!(".radin/state/unmerged/{t}"), &format!("{h}\n"));
        w.git(&["checkout", "-q", &base]);
        w.git(&["branch", "-q", "-D", &format!("radin/{t}")]);
    }
    w.write("t-one.txt", "t-one\n");
    w.git(&["add", "t-one.txt"]);
    w.git(&["commit", "-q", "-m", "feat: t-one again"]);
    let r = w.state(&["reconcile"]);
    assert_eq!(r.code, 0, "{}", r.all());
    assert!(r.out.contains("adopted\tradin/t-one"), "{}", r.out);
    assert!(r.out.contains("merged\tradin/t-two\t"), "{}", r.out);
    assert!(w.exists("t-two.txt"));
    let mut ids: Vec<String> = w
        .state(&["completed-list"])
        .out
        .lines()
        .map(|l| l.split('\t').next().unwrap().to_string())
        .collect();
    ids.sort();
    assert_eq!(ids.join(","), "t-one,t-two");
    assert_eq!(w.state(&["unlanded"]).code, 1);
}

#[test]
fn a_task_done_on_a_side_branch_stays_on_the_backlog_until_its_merge_lands() {
    let w = W::new();
    let base = w.base();
    w.steps_init("t-one\t1\t\tpending\n");
    w.git(&["checkout", "-q", "-b", "radin/t-one"]);
    w.write("x.txt", "x\n");
    w.git(&["add", "x.txt"]);
    let o = std::process::Command::new("git")
        .args([
            "-c",
            "user.name=t",
            "-c",
            "user.email=t@t",
            "commit",
            "-q",
            "-m",
            "feat: x",
        ])
        .env("GIT_AUTHOR_DATE", "2020-01-01T00:00:00")
        .env("GIT_COMMITTER_DATE", "2020-01-01T00:00:00")
        .current_dir(&w.p)
        .output()
        .unwrap();
    assert!(o.status.success());
    let h = w.git(&["rev-parse", "--short=12", "HEAD"]);
    w.git(&["checkout", "-q", &base]);
    w.write(
        ".radin/state/prepared/t-one.json",
        "{\"branch\":\"radin/t-one\",\"worktree\":\"\"}\n",
    );
    let r = w.state(&["task-done", "t-one", &h]);
    assert_eq!(r.code, 0);
    assert!(r.out.contains("unmerged"), "{}", r.out);
    assert_eq!(w.bl(&["find", "t-one"], "").code, 0);
    assert_ne!(w.state(&["completed-list"]).code, 0);
    assert!(w
        .state(&["unlanded"])
        .out
        .contains(&format!("t-one\t{h}\tradin/t-one\tpending")));
    assert_eq!(w.state(&["reconcile"]).code, 0);
    let list = w.state(&["completed-list"]).out;
    assert!(list.starts_with("t-one\t"), "{list}");
    let landed = list.trim_end().split('\t').nth(1).unwrap().to_string();
    assert_ne!(landed, h);
    let long = w.state(&["completed-list", "--long"]).out;
    let f: Vec<&str> = long.trim_end().split('\t').collect();
    assert_eq!(
        (f.len(), f[0], f[1]),
        (4, "t-one", landed.as_str()),
        "{long}"
    );
    assert!(!f[2].is_empty(), "{long}");
    assert!(w.git_ok(&["merge-base", "--is-ancestor", &landed, &base]));
    assert_ne!(w.bl(&["find", "t-one"], "").code, 0);
    assert_eq!(w.state(&["unlanded"]).code, 1);
}

#[test]
fn a_claimed_stash_is_applied_in_the_tasks_tree_and_kept_a_conflicting_one_leaves_a_clean_tree() {
    let w = W::new();
    let base = w.base();
    w.write("a.txt", "one\n");
    w.git(&["add", "a.txt"]);
    w.git(&["commit", "-q", "-m", "add a"]);
    let task = w.task_file("t-one");
    let mut f = fs::read_to_string(&task).unwrap();
    f.push_str("touch a.txt\n");
    fs::write(&task, f).unwrap();
    w.state(&["session-set", "yes", "no"]);
    w.state(&["group-set", "t-one", "t-two"]);
    w.write("a.txt", "draft\n");
    w.write("b.txt", "new\n");
    w.git(&[
        "stash",
        "push",
        "-u",
        "-q",
        "-m",
        "radin-batch: uncommitted changes found before task other",
        "--",
        "a.txt",
        "b.txt",
    ]);
    let h = w.git(&["rev-parse", "stash@{0}"]);
    let r = w.state(&["stash-triage"]);
    assert_eq!(r.code, 0);
    assert!(
        r.out.contains(&format!("candidate\t{h}\tt-one")),
        "{}",
        r.out
    );
    assert!(r.out.contains("left\t1"), "{}", r.out);
    assert_eq!(w.state(&["stash-claim", &h, "t-one"]).code, 0);
    let again = w.state(&["stash-claim", &h, "t-one"]);
    assert_ne!(again.code, 0);
    assert!(again.all().contains("already triaged"));
    let r = w.state(&["prepare", "t-one"]);
    assert_eq!(r.code, 0, "{}", r.all());
    let dir = r.out.lines().last().unwrap().to_string();
    assert_eq!(
        fs::read_to_string(format!("{dir}/a.txt")).unwrap().trim(),
        "draft"
    );
    assert_eq!(w.git(&["stash", "list"]).lines().count(), 1);
    w.write("a.txt", "other\n");
    w.git(&[
        "stash",
        "push",
        "-q",
        "-m",
        "radin-batch: uncommitted changes found before task other",
        "--",
        "a.txt",
    ]);
    let h2 = w.git(&["rev-parse", "stash@{0}"]);
    w.state(&["stash-claim", &h2, "t-two"]);
    let wt2 = w.work.join("proj-t-two");
    w.git(&[
        "worktree",
        "add",
        "-q",
        wt2.to_str().unwrap(),
        "-b",
        "radin/t-two",
        &base,
    ]);
    fs::write(wt2.join("a.txt"), "clash\n").unwrap();
    w.git_at(&wt2, &["commit", "-qam", "clash"]);
    let r = w.state(&["prepare", "t-two"]);
    assert_eq!(r.code, 0, "{}", r.all());
    assert!(r.all().contains("did not apply"), "{}", r.all());
    assert!(w.git_at(&wt2, &["status", "--porcelain"]).is_empty());
    assert_eq!(w.git(&["stash", "list"]).lines().count(), 2);
}

#[test]
fn report_prints_the_unverified_line_when_the_session_gate_never_ran() {
    let w = W::new();
    w.steps_init("t-one\t1\t\tpending\n");
    let r = w.state(&["report"]);
    assert_eq!(r.code, 0);
    assert!(
        r.out.contains(
            "Net-new backlog entries this session: 0. Nothing verified these commits yet"
        ),
        "{}",
        r.out
    );
}

#[test]
fn report_says_the_session_gate_reviewed_the_session_once_gate_done_is_set() {
    let w = W::new();
    w.steps_init("t-one\t1\t\tpending\n");
    w.state(&["gate-done"]);
    let r = w.state(&["report"]);
    assert_eq!(r.code, 0);
    assert!(
        r.out
            .contains("Net-new backlog entries this session: 0. Reviewed by the session gate."),
        "{}",
        r.out
    );
    assert!(!r.out.contains("Nothing verified"));
}

#[test]
fn steps_init_clears_gate_done_so_the_next_session_prints_the_unverified_line_again() {
    let w = W::new();
    w.steps_init("t-one\t1\t\tpending\n");
    w.state(&["gate-done"]);
    w.steps_init("t-one\t1\t\tpending\n");
    assert!(w
        .state(&["report"])
        .out
        .contains("Nothing verified these commits yet"));
}

#[test]
fn deps_check_resolves_an_unmerged_dependency_to_its_branch_tip_two_unmerged_siblings_still_block()
{
    let w = W::new();
    let base = w.stack_setup();
    let r = w.state(&["deps-check", "t-two"]);
    assert_eq!(r.code, 0, "{}", r.all());
    assert_eq!(
        r.out,
        format!(
            "t-one\t{}\n",
            w.git(&["rev-parse", "--short=12", "radin/t-one"])
        )
    );
    w.bl(&["add", "fix", "t three"], "body\n");
    w.bl(
        &["add", "fix", "t four", "--deps", "t-one,t-three"],
        "body\n",
    );
    w.git(&["checkout", "-q", "-b", "radin/t-three", &base]);
    w.git(&["commit", "-q", "--allow-empty", "-m", "feat: t-three"]);
    w.git(&["checkout", "-q", &base]);
    w.write(".radin/state/unmerged/t-three", "");
    w.steps_init("t-one\t1\t\tpending\nt-three\t2\t\tpending\nt-four\t3\tt-one,t-three\tpending\n");
    let r = w.state(&["deps-check", "t-four"]);
    assert_ne!(r.code, 0);
    assert!(r.all().contains("waiting on dependency"), "{}", r.all());
}

#[test]
fn wave_prints_only_the_pending_task_whose_dependencies_are_all_resolved_exit_0() {
    let w = W::new();
    w.steps_init("t-one\t1\t\tpending\nt-two\t2\tt-one\tpending\n");
    let r = w.state(&["wave"]);
    assert_eq!((r.code, r.out.as_str()), (0, "t-one\t1\n"));
}

#[test]
fn wave_prints_every_independent_pending_task_in_order_and_reading_it_twice_changes_nothing() {
    let w = W::new();
    w.steps_init("t-one\t1\t\tpending\nt-two\t2\t\tpending\nt-three\t3\t\tpending\n");
    let before = w.state(&["steps-list"]).out;
    let first = w.state(&["wave"]).out;
    let second = w.state(&["wave"]).out;
    assert_eq!(second, "t-one\t1\nt-two\t2\nt-three\t3\n");
    assert_eq!(first, second);
    assert_eq!(w.state(&["steps-list"]).out, before);
}

fn six(w: &W) {
    let rows: String = (1..=6)
        .map(|i| format!("t-{i}\t{i}\t\tpending\n"))
        .collect();
    w.steps_init(&rows);
}

#[test]
fn wave_prints_at_most_2_ready_tasks_by_default_the_first_by_order() {
    let w = W::new();
    w.cap.set(None);
    six(&w);
    let r = w.state(&["wave"]);
    assert_eq!(r.code, 0);
    assert_eq!(r.out, "t-1\t1\nt-2\t2\n");
    assert_eq!(w.state(&["wave-cap"]).out, "2\n");
}

#[test]
fn the_wave_cap_comes_from_radin_wave_cap_else_the_install_manifest_and_must_be_positive() {
    let w = W::new();
    w.cap.set(None);
    six(&w);
    fs::create_dir_all(w.home.join(".radin")).unwrap();
    fs::write(
        w.home.join(".radin/manifest.json"),
        "{\n  \"wave_cap\": 3,\n  \"version\": \"x\"\n}\n",
    )
    .unwrap();
    assert_eq!(w.state(&["wave"]).out.lines().count(), 3);
    assert_eq!(w.state(&["wave-cap"]).out, "3\n");
    assert_eq!(w.state_cap(&["wave"], "", Some("4")).out.lines().count(), 4);
    assert_ne!(w.state_cap(&["wave"], "", Some("0")).code, 0);
    let r = w.state_cap(&["wave-cap"], "", Some("0"));
    assert_ne!(r.code, 0);
    assert_eq!(
        r.err,
        "radin-state: wave cap needs a positive integer, got: 0\n"
    );
}

#[test]
fn wave_reads_hundreds_of_completed_tasks_and_prints_every_ready_one() {
    let w = W::new();
    let done: String = (1..=400)
        .map(|i| format!("{{\"id\":\"done-{i}\",\"commit\":\"abc{i}\"}}\n"))
        .collect();
    w.write(".radin/state/completed.json", &done);
    let rows: String = (1..=30)
        .map(|i| format!("t-{i}\t{i}\tdone-{},done-{}\tpending\n", i * 10, i * 12))
        .collect();
    w.steps_init(&rows);
    let r = w.state_cap(&["wave"], "", Some("30"));
    assert_eq!(r.out.lines().count(), 30);
}

#[test]
fn wave_counts_a_done_dependency_as_resolved() {
    let w = W::new();
    w.write(
        ".radin/state/completed.json",
        "{\"id\":\"t-one\",\"commit\":\"abc123def456\"}\n",
    );
    w.steps_init("t-two\t2\tt-one\tpending\n");
    let r = w.state(&["wave"]);
    assert_eq!((r.code, r.out.as_str()), (0, "t-two\t2\n"));
}

#[test]
fn wave_skips_a_pending_task_that_carries_an_unmerged_marker() {
    let w = W::new();
    w.stack_setup();
    let r = w.state(&["wave"]);
    assert_eq!((r.code, r.out.as_str()), (0, "t-two\t2\n"));
}

#[test]
fn wave_skips_excluded_blocked_and_in_progress_tasks() {
    let w = W::new();
    w.steps_init(
        "t-one\t1\t\texcluded\nt-two\t2\t\tpending\nt-three\t3\t\tpending\nt-four\t4\t\tpending\n",
    );
    w.state(&["set-status", "t-two", "blocked", "waiting"]);
    w.state(&["set-status", "t-three", "in_progress"]);
    let r = w.state(&["wave"]);
    assert_eq!((r.code, r.out.as_str()), (0, "t-four\t4\n"));
}

#[test]
fn wave_prints_nothing_and_exits_1_when_every_pending_task_waits_on_an_unresolved_dependency() {
    let w = W::new();
    w.steps_init("t-one\t1\tt-zero\tpending\nt-two\t2\tt-one\tpending\n");
    let r = w.state(&["wave"]);
    assert_eq!((r.code, r.out.as_str()), (1, ""));
}

#[test]
fn prepare_starts_a_dependent_on_its_unmerged_dependencys_branch_and_records_the_stack() {
    let w = W::new();
    w.stack_setup();
    let r = w.state(&["prepare", "t-two"]);
    assert_eq!(r.code, 0, "{}", r.all());
    let dir = r.out.lines().last().unwrap();
    assert_eq!(
        w.git_at(std::path::Path::new(dir), &["show", "HEAD:shared.txt"]),
        "one\nfrom-one"
    );
    let tip = w.git(&["rev-parse", "--short=12", "radin/t-one"]);
    assert_eq!(
        w.read(".radin/state/stacked/t-two").trim(),
        format!("t-one {tip}")
    );
}

#[test]
fn prepare_moves_an_existing_dependent_branch_with_no_commit_of_its_own_onto_the_dependency() {
    let w = W::new();
    w.stack_setup();
    w.git(&["branch", "radin/t-two"]);
    let r = w.state(&["prepare", "t-two"]);
    assert_eq!(r.code, 0, "{}", r.all());
    let dir = r.out.lines().last().unwrap();
    assert_eq!(
        w.git_at(std::path::Path::new(dir), &["show", "HEAD:shared.txt"]),
        "one\nfrom-one"
    );
    let tip = w.git(&["rev-parse", "--short=12", "radin/t-one"]);
    assert_eq!(
        w.read(".radin/state/stacked/t-two").trim(),
        format!("t-one {tip}")
    );
}

#[test]
fn prepare_leaves_an_existing_dependent_branch_that_holds_its_own_commit() {
    let w = W::new();
    let base = w.stack_setup();
    w.git(&["checkout", "-q", "-b", "radin/t-two"]);
    w.write("own.txt", "own\n");
    w.git(&["add", "own.txt"]);
    w.git(&["commit", "-q", "-m", "feat: t-two"]);
    w.git(&["checkout", "-q", &base]);
    let own = w.git(&["rev-parse", "radin/t-two"]);
    let r = w.state(&["prepare", "t-two"]);
    assert_eq!(r.code, 0, "{}", r.all());
    assert_eq!(w.git(&["rev-parse", "radin/t-two"]), own);
    assert!(r
        .err
        .contains("prepare: radin/t-two does not contain radin/t-one"));
    assert!(!w.exists(".radin/state/stacked/t-two"));
    assert!(w
        .read(".radin/state/journal.jsonl")
        .contains("stack-missed"));
}

#[test]
fn prepare_records_the_stack_of_an_existing_dependent_branch_that_contains_the_dependency() {
    let w = W::new();
    w.stack_setup();
    w.git(&["branch", "radin/t-two", "radin/t-one"]);
    let r = w.state(&["prepare", "t-two"]);
    assert_eq!(r.code, 0, "{}", r.all());
    let tip = w.git(&["rev-parse", "--short=12", "radin/t-one"]);
    assert_eq!(w.git(&["rev-parse", "--short=12", "radin/t-two"]), tip);
    assert_eq!(
        w.read(".radin/state/stacked/t-two").trim(),
        format!("t-one {tip}")
    );
}

#[test]
fn prepare_gives_a_solo_task_its_own_worktree_and_the_main_checkout_keeps_its_branch() {
    let w = W::new();
    let base = w.base();
    w.state(&["session-set", "yes", "yes"]);
    let wt = format!("{}-t-one", w.p.display());
    assert_eq!(w.prep_dir("t-one"), wt);
    assert_eq!(
        w.git_at(std::path::Path::new(&wt), &["branch", "--show-current"]),
        "radin/t-one"
    );
    assert_eq!(w.base(), base);
    assert_eq!(w.git(&["worktree", "list"]).lines().count(), 2);
}

#[test]
fn prepare_commits_to_the_base_when_worktree_and_branch_are_no() {
    let w = W::new();
    let before = w.base();
    w.state(&["session-set", "no", "no"]);
    assert_eq!(w.prep_dir("t-one"), w.p.to_string_lossy());
    assert_eq!(w.base(), before);
    assert!(w.git(&["branch", "--list", "radin/t-one"]).is_empty());
}

#[test]
fn prepare_makes_a_worktree_for_each_member_of_a_recorded_group() {
    let w = W::new();
    w.state(&["session-set", "yes", "no"]);
    w.state(&["group-set", "t-one", "t-two"]);
    let wt = format!("{}-t-one", w.p.display());
    assert_eq!(w.prep_dir("t-one"), wt);
    assert_eq!(
        w.git_at(std::path::Path::new(&wt), &["branch", "--show-current"]),
        "radin/t-one"
    );
}

#[test]
fn prepare_makes_no_worktree_for_a_group_when_the_worktree_answer_is_no() {
    let w = W::new();
    w.state(&["session-set", "no", "yes"]);
    w.state(&["group-set", "t-one", "t-two"]);
    assert_eq!(w.prep_dir("t-one"), w.p.to_string_lossy());
    assert_eq!(w.git(&["worktree", "list"]).lines().count(), 1);
}

#[test]
fn prepare_reuses_the_worktree_a_dead_attempt_left_for_a_task_that_runs_alone() {
    let w = W::new();
    let base = w.base();
    let wt = format!("{}-t-one", w.p.display());
    w.git(&["worktree", "add", "-q", &wt, "-b", "radin/t-one", &base]);
    w.state(&["session-set", "yes", "yes"]);
    assert_eq!(w.prep_dir("t-one"), wt);
}

#[test]
fn prepare_fails_on_a_leftover_directory_at_the_worktree_path_and_keeps_it() {
    let w = W::new();
    w.state(&["session-set", "yes", "yes"]);
    let wt = format!("{}-t-one", w.p.display());
    fs::create_dir_all(format!("{wt}/.gradle")).unwrap();
    let r = w.state(&["prepare", "t-one"]);
    assert_ne!(r.code, 0, "{}", r.all());
    assert!(r.all().contains(&wt), "{}", r.all());
    assert!(r.all().contains("not a registered worktree"), "{}", r.all());
    assert!(std::path::Path::new(&format!("{wt}/.gradle")).is_dir());
}

#[test]
fn group_set_rejects_no_id_and_a_path_character() {
    let w = W::new();
    assert_ne!(w.state(&["group-set"]).code, 0);
    assert_ne!(w.state(&["group-set", "../x"]).code, 0);
}

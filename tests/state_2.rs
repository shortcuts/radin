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
        w.write(&format!(".radin/state/landing/{t}"), &format!("{h}\n"));
        w.mark_finished(t);
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
    w.lane_mode("lanes");
    let wt2 = w.work.join("proj-maintenance");
    w.git(&[
        "worktree",
        "add",
        "-q",
        wt2.to_str().unwrap(),
        "-b",
        "radin/maintenance",
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
fn the_lane_cap_comes_from_radin_lane_cap_else_the_install_manifest_and_must_be_positive() {
    let w = W::new();
    w.cap.set(None);
    assert_eq!(w.state(&["lane-cap"]).out, "2\n");
    fs::create_dir_all(w.home.join(".radin")).unwrap();
    fs::write(
        w.home.join(".radin/manifest.json"),
        "{\n  \"lane_cap\": 3,\n  \"version\": \"x\"\n}\n",
    )
    .unwrap();
    assert_eq!(w.state(&["lane-cap"]).out, "3\n");
    assert_eq!(w.state_cap(&["lane-cap"], "", Some("4")).out, "4\n");
    let r = w.state_cap(&["lane-cap"], "", Some("0"));
    assert_ne!(r.code, 0);
    assert_eq!(
        r.err,
        "radin-state: lane cap needs a positive integer, got: 0\n"
    );
}

#[test]
fn reconcile_records_a_branch_whose_last_event_is_done_unmerged_without_a_follow_up() {
    let w = W::new();
    let base = w.base();
    w.bl(&["add", "fix", "t two"], "body\n");
    for t in ["t-one", "t-two"] {
        w.git(&["checkout", "-q", "-b", &format!("radin/{t}"), &base]);
        w.write(&format!("{t}.txt"), &format!("{t}\n"));
        w.git(&["add", &format!("{t}.txt")]);
        w.git(&["commit", "-q", "-m", &format!("feat: {t}")]);
        w.git(&["checkout", "-q", &base]);
    }
    w.mark_finished("t-one");
    let r = w.state(&["reconcile"]);
    assert_eq!(r.code, 0, "{}", r.all());
    assert!(!r.out.contains("follow-up\tt-one"), "{}", r.out);
    assert!(r.out.contains("follow-up\tt-two\t"), "{}", r.out);
    let list = w.bl(&["list", "--order", "created"], "").out;
    assert!(list.contains("Finish: t two"), "{list}");
    assert!(!list.contains("Finish: t one"), "{list}");
    let done: Vec<String> = w
        .state(&["completed-list"])
        .out
        .lines()
        .map(|l| l.split('\t').next().unwrap().to_string())
        .collect();
    assert_eq!(done.len(), 2, "{done:?}");
}

#[test]
fn prepare_gives_a_lane_task_the_epic_worktree_and_the_main_checkout_keeps_its_branch() {
    let w = W::new();
    let base = w.base();
    w.lane_mode("lanes");
    let wt = format!("{}-maintenance", w.p.display());
    assert_eq!(w.prep_dir("t-one"), wt);
    assert_eq!(
        w.git_at(std::path::Path::new(&wt), &["branch", "--show-current"]),
        "radin/maintenance"
    );
    assert_eq!(w.base(), base);
    assert_eq!(w.git(&["worktree", "list"]).lines().count(), 2);
}

#[test]
fn a_lane_task_commit_lands_on_its_lane_branch_never_on_the_base() {
    let w = W::new();
    let before = w.git(&["rev-parse", "HEAD"]);
    w.lane_mode("lanes");
    let dir = w.prep_dir("t-one");
    assert_ne!(dir, w.p.to_string_lossy());
    let wt = std::path::Path::new(&dir);
    fs::write(wt.join("work.txt"), "x").unwrap();
    w.git_at(wt, &["add", "work.txt"]);
    w.git_at(wt, &["commit", "-q", "-m", "feat: work"]);
    assert_eq!(w.git(&["rev-parse", "HEAD"]), before);
    assert_eq!(
        w.git_at(wt, &["branch", "--show-current"]),
        "radin/maintenance"
    );
}

#[test]
fn prepare_works_on_the_base_in_main_mode() {
    let w = W::new();
    let before = w.base();
    w.lane_mode("main");
    assert_eq!(w.prep_dir("t-one"), w.p.to_string_lossy());
    assert_eq!(w.base(), before);
    assert!(w.git(&["branch", "--list", "radin/*"]).is_empty());
}

#[test]
fn prepare_reuses_the_worktree_a_dead_attempt_left_for_the_lane() {
    let w = W::new();
    let base = w.base();
    let wt = format!("{}-maintenance", w.p.display());
    w.git(&[
        "worktree",
        "add",
        "-q",
        &wt,
        "-b",
        "radin/maintenance",
        &base,
    ]);
    w.lane_mode("lanes");
    assert_eq!(w.prep_dir("t-one"), wt);
}

#[test]
fn prepare_fails_on_a_leftover_directory_at_the_worktree_path_and_keeps_it() {
    let w = W::new();
    w.lane_mode("lanes");
    let wt = format!("{}-maintenance", w.p.display());
    fs::create_dir_all(format!("{wt}/.gradle")).unwrap();
    let r = w.state(&["prepare", "t-one"]);
    assert_ne!(r.code, 0, "{}", r.all());
    assert!(r.all().contains(&wt), "{}", r.all());
    assert!(r.all().contains("not a registered worktree"), "{}", r.all());
    assert!(std::path::Path::new(&format!("{wt}/.gradle")).is_dir());
}

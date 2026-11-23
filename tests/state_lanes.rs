mod common;
use common::W;
use std::path::Path;

fn epics(w: &W) {
    w.cap.set(None);
    for e in ["ea", "eb"] {
        assert_eq!(w.bl(&["epic-add", e], "").code, 0);
    }
    for (t, e, deps) in [
        ("a one", "ea", ""),
        ("a two", "ea", "a-one"),
        ("b one", "eb", ""),
    ] {
        let mut a = vec!["add", "fix", t, "--epic", e];
        if !deps.is_empty() {
            a.extend(["--deps", deps]);
        }
        assert_eq!(w.bl(&a, "body\n").code, 0);
    }
    w.steps_init("a-one\t1\t\tpending\na-two\t2\ta-one\tpending\nb-one\t3\t\tpending\n");
}

fn merged(w: &W, epic: &str) {
    w.write(".radin/state/merge-queue", &format!("{epic}\tmerged\n"));
    w.write(&format!(".radin/state/gate/{epic}"), "green\n");
}

#[test]
fn lanes_init_picks_the_mode_and_resets_lane_markers() {
    let w = W::new();
    epics(&w);
    w.write(".radin/state/lanes/stale", "running\n");
    let r = w.state(&["lanes-init"]);
    assert_eq!(
        (r.code, r.out.as_str()),
        (
            0,
            "mode\tlanes\ncap\t2\nlane\tea\twaiting\t2\nlane\teb\twaiting\t1\n"
        )
    );
    assert_eq!(w.read(".radin/state/lane-mode"), "lanes\n");
    assert!(!w.exists(".radin/state/lanes/stale"));
    assert_eq!(w.bl(&["epic-set-deps", "eb", "ea"], "").code, 0);
    let r = w.state(&["lanes-init"]);
    assert!(r.out.starts_with("mode\tmain\ncap\t2\n"), "{}", r.out);
    assert_eq!(w.state(&["session-set", "no"]).code, 0);
    assert_eq!(
        w.read(".radin/state/session.json"),
        "{\"parallel\":false}\n"
    );
    assert_eq!(w.bl(&["epic-set-deps", "eb", "--none"], "").code, 0);
    let r = w.state(&["lanes-init"]);
    assert!(r.out.starts_with("mode\tmain\n"), "{}", r.out);
    assert_eq!(w.state(&["session-get"]).out, "parallel\tno\n");
}

#[test]
fn lanes_init_rejects_epics_whose_tasks_depend_on_each_other() {
    let w = W::new();
    epics(&w);
    w.steps_init("a-one\t1\tb-one\tpending\nb-one\t3\ta-one\tpending\n");
    let r = w.state(&["lanes-init"]);
    assert_eq!(
        (r.code, r.err.as_str()),
        (
            1,
            "radin-state: epic dependency cycle: ea waits for eb (task a-one depends on b-one); eb waits for ea (task b-one depends on a-one)\n"
        )
    );
}

#[test]
fn lane_next_fills_slots_waits_for_merges_and_asks_for_clearance() {
    let w = W::new();
    epics(&w);
    w.state(&["lanes-init"]);
    let r = w.state(&["lane-next"]);
    assert_eq!((r.code, r.out.as_str()), (0, "start\tea\n"));
    let r = w.state(&["lane-next"]);
    assert_eq!((r.code, r.out.as_str()), (2, "judge\teb\tea\n"));
    assert_eq!(w.state(&["lane-next", "--cleared", "zz"]).code, 2);
    let r = w.state(&["lane-next", "--cleared", "eb"]);
    assert_eq!((r.code, r.out.as_str()), (0, "start\teb\n"));
    let r = w.state(&["lane-next"]);
    assert_eq!((r.code, r.out.as_str()), (1, ""));
    merged(&w, "ea");
    assert_eq!(w.state(&["lane-done", "ea"]).code, 0);
    assert_eq!(w.state(&["lane-next"]).code, 1);
    assert_eq!(w.state(&["lane-next", "--bogus"]).code, 1);
}

#[test]
fn a_lane_of_only_deferred_tasks_is_never_started() {
    let w = W::new();
    epics(&w);
    assert_eq!(
        w.state(&[
            "set-status",
            "b-one",
            "blocked",
            "--reason",
            "deferred",
            "q?"
        ])
        .code,
        0
    );
    w.steps_init("a-one\t1\t\tpending\na-two\t2\ta-one\tpending\nb-one\t3\t\tpending\n");
    w.state(&["lanes-init"]);
    assert_eq!(w.state(&["lane-next"]).out, "start\tea\n");
    assert_eq!(w.state(&["lane-next", "--cleared", "eb"]).code, 1);
}

#[test]
fn a_dependent_epic_starts_only_after_its_dependency_lane_is_done() {
    let w = W::new();
    epics(&w);
    w.bl(&["epic-set-deps", "eb", "ea"], "");
    w.state(&["lanes-init"]);
    assert_eq!(w.state(&["lane-next"]).out, "start\tea\n");
    let r = w.state(&["lane-next"]);
    assert_eq!(
        (r.code, r.out.as_str()),
        (1, "wait\teb\twaits for epic ea (running)\n")
    );
    merged(&w, "ea");
    assert_eq!(w.state(&["lane-done", "ea"]).code, 0);
    assert_eq!(w.state(&["lane-next"]).out, "start\teb\n");
}

#[test]
fn lane_done_needs_a_running_lane_and_lanes_show_lists_states() {
    let w = W::new();
    epics(&w);
    assert_eq!(w.state(&["lanes-show"]).out, "mode\tmain\n");
    w.state(&["lanes-init"]);
    let r = w.state(&["lane-done", "ea"]);
    assert_eq!(r.code, 1);
    assert_eq!(r.err, "radin-state: lane ea is not running\n");
    w.state(&["lane-next"]);
    assert_eq!(
        w.state(&["lanes-show"]).out,
        "mode\tlanes\ncap\t2\nlane\tea\trunning\t2\nlane\teb\twaiting\t1\n"
    );
    let r = w.state(&["lane-done", "ea"]);
    assert_eq!(
        (r.code, r.err.as_str()),
        (1, "radin-state: lane ea has not merged\n")
    );
    merged(&w, "ea");
    w.state(&["lane-done", "ea"]);
    assert_eq!(
        w.state(&["lanes-show"]).out.lines().nth(2),
        Some("lane\tea\tdone\t2")
    );
}

#[test]
fn prepare_works_on_main_in_main_mode_and_in_the_lane_worktree_in_lanes_mode() {
    let w = W::new();
    epics(&w);
    let base = w.base();
    w.lane_mode("main");
    assert_eq!(w.prep_dir("a-one"), w.p.to_string_lossy());
    assert!(w.git(&["branch", "--list", "radin/*"]).is_empty());
    assert_eq!(
        w.state(&["task-dir", "a-one"]).out,
        format!("{}\n", w.p.display())
    );
    w.lane_mode("lanes");
    let wt = format!("{}-ea", w.p.display());
    assert_eq!(w.prep_dir("a-one"), wt);
    assert_eq!(w.state(&["task-dir", "a-one"]).out, format!("{wt}\n"));
    assert_eq!(
        w.git_at(Path::new(&wt), &["branch", "--show-current"]),
        "radin/ea"
    );
    assert_eq!(w.prep_dir("a-two"), wt);
    assert_eq!(w.state(&["task-dir", "a-two"]).out, format!("{wt}\n"));
    let eb = format!("{}-eb", w.p.display());
    assert_eq!(w.prep_dir("b-one"), eb);
    assert_eq!(w.base(), base);
    std::fs::create_dir_all(format!("{}-maintenance/x", w.p.display())).unwrap();
    let r = w.state(&["prepare", "t-one"]);
    assert_eq!(r.code, 1);
    assert!(
        r.err.contains("exists but is not a registered worktree"),
        "{}",
        r.err
    );
}

#[test]
fn a_lane_task_is_done_at_its_lane_commit_and_next_is_refused_in_lane_mode() {
    let w = W::new();
    epics(&w);
    w.lane_mode("lanes");
    let wt = w.prep_dir("a-one");
    std::fs::write(Path::new(&wt).join("a.txt"), "a\n").unwrap();
    w.git_at(Path::new(&wt), &["add", "a.txt"]);
    w.git_at(Path::new(&wt), &["commit", "-qm", "feat: a-one"]);
    let hash = w.git_at(Path::new(&wt), &["rev-parse", "--short=12", "HEAD"]);
    let r = w.state(&["task-done", "a-one", &hash]);
    assert_eq!(r.code, 0, "{}", r.all());
    assert!(!r.all().contains("unmerged"), "{}", r.all());
    assert_eq!(w.state(&["completed-show", "a-one"]).code, 0);
    let shown = w.state(&["completed-show", "a-one"]).out;
    assert!(shown.contains(&hash), "{shown}");
    assert!(shown.contains("branch\tradin/ea\n"), "{shown}");
    assert!(shown.contains(&format!("worktree\t{wt}\n")), "{shown}");
    let r = w.state(&["task-report", "a-two", "STATUS: FAILED — boom", "--next"]);
    assert_eq!(r.code, 1);
    assert!(
        r.err.contains("--next is refused in lane mode"),
        "{}",
        r.err
    );
}

fn commit_in(w: &W, dir: &Path, file: &str, text: &str) -> String {
    std::fs::write(dir.join(file), text).unwrap();
    w.git_at(dir, &["add", file]);
    w.git_at(dir, &["commit", "-qm", &format!("edit {file}")]);
    w.git_at(dir, &["rev-parse", "HEAD"])
}

fn lane_tree(w: &W, id: &str) -> std::path::PathBuf {
    std::path::PathBuf::from(w.prep_dir(id))
}

#[test]
fn lane_sync_merges_main_into_the_lane_only_when_main_moved() {
    let w = W::new();
    epics(&w);
    w.lane_mode("main");
    let r = w.state(&["lane-sync", "a-one"]);
    assert_eq!((r.code, r.out.as_str()), (0, ""));
    w.lane_mode("lanes");
    assert_eq!(w.state(&["lane-sync", "a-one"]).out, "current\tea\n");
    commit_in(&w, &w.p, "m.txt", "main\n");
    let r = w.state(&["lane-sync", "a-one"]);
    assert_eq!(r.code, 0, "{}", r.all());
    assert!(r.out.starts_with("synced\tea\t"), "{}", r.out);
    let wt = std::path::PathBuf::from(format!("{}-ea", w.p.display()));
    assert_eq!(std::fs::read_to_string(wt.join("m.txt")).unwrap(), "main\n");
    assert_eq!(w.state(&["lane-sync", "a-one"]).out, "current\tea\n");
}

#[test]
fn lane_sync_hands_a_conflict_to_the_merge_agent_and_finishes_or_aborts() {
    let w = W::new();
    epics(&w);
    w.lane_mode("lanes");
    w.state(&["lane-sync", "a-one"]);
    let wt = std::path::PathBuf::from(format!("{}-ea", w.p.display()));
    commit_in(&w, &wt, "c.txt", "lane\n");
    commit_in(&w, &w.p, "c.txt", "main\n");
    let r = w.state(&["lane-sync", "a-one"]);
    assert_eq!(r.code, 3, "{}", r.all());
    assert_eq!(r.out, format!("conflict\tea\t{}\n", wt.display()));
    assert!(
        w.git_at(&wt, &["rev-parse", "-q", "--verify", "MERGE_HEAD"])
            .len()
            > 7
    );
    let r = w.state(&["prepare", "a-one"]);
    assert_eq!(r.code, 1);
    assert!(r.err.contains("has a merge in progress"), "{}", r.err);
    assert_eq!(w.state(&["lane-sync", "a-one"]).code, 3);
    std::fs::write(wt.join("c.txt"), "both\n").unwrap();
    w.git_at(&wt, &["add", "c.txt"]);
    let r = w.state(&["lane-sync", "a-one"]);
    assert!(r.out.starts_with("synced\tea\t"), "{}", r.all());
    commit_in(&w, &wt, "c.txt", "lane2\n");
    commit_in(&w, &w.p, "c.txt", "main2\n");
    assert_eq!(w.state(&["lane-sync", "a-one"]).code, 3);
    assert_eq!(
        w.state(&["lane-sync", "a-one", "--abort"]).out,
        "aborted\tea\n"
    );
    assert_eq!(w.git_at(&wt, &["status", "--porcelain"]), "");
    assert_eq!(
        w.state(&["lane-sync", "a-one", "--abort"]).out,
        "current\tea\n"
    );
}

#[test]
fn an_unrecovered_lane_task_is_parked_and_the_lane_resets() {
    let w = W::new();
    epics(&w);
    w.lane_mode("lanes");
    let wt = lane_tree(&w, "a-one");
    let before = w.git_at(&wt, &["rev-parse", "HEAD"]);
    assert_eq!(
        w.read(".radin/state/lane-base/a-one"),
        format!("{before}\n")
    );
    let work = commit_in(&w, &wt, "w.txt", "partial\n");
    let line = "STATUS: FAILED — boom";
    assert_eq!(w.state(&["task-report", "a-one", line]).code, 0);
    let r = w.state(&["task-report", "a-one", line]);
    assert_eq!(r.code, 0, "{}", r.all());
    assert!(
        r.out.contains("parked\ta-one\tradin/wip/a-one\t"),
        "{}",
        r.out
    );
    assert_eq!(w.git(&["rev-parse", "radin/wip/a-one~1"]), work);
    assert_eq!(
        w.git(&["log", "-1", "--format=%s", "radin/wip/a-one"]),
        "wip(a-one): parked, boom"
    );
    assert_eq!(w.git_at(&wt, &["rev-parse", "HEAD"]), before);
    assert_eq!(w.git_at(&wt, &["status", "--porcelain"]), "");
    assert!(!w.exists(".radin/state/lane-base/a-one"));
    let rep = w.state(&["report"]);
    assert!(
        rep.out.contains(
            "Kept on a wip branch (resumes on the next batch):\n- a one — radin/wip/a-one at "
        ) && rep.out.contains(": boom"),
        "{}",
        rep.all()
    );
    assert!(!w.state(&["leftovers"]).out.contains("wip"));
}

#[test]
fn park_fires_on_inconclusive_and_set_status_but_not_on_blocked_clarify() {
    let w = W::new();
    epics(&w);
    w.lane_mode("lanes");
    let wt = lane_tree(&w, "a-one");
    commit_in(&w, &wt, "one.txt", "1\n");
    let r = w.state(&["set-status", "a-one", "blocked", "need a human"]);
    assert_eq!(r.code, 0, "{}", r.all());
    assert!(w.git_ok(&["rev-parse", "--verify", "-q", "radin/wip/a-one"]));
    assert!(!wt.join("one.txt").exists());
    lane_tree(&w, "a-two");
    commit_in(&w, &wt, "two.txt", "2\n");
    let r = w.state(&["task-report", "a-two", "STATUS: INCONCLUSIVE — no device"]);
    assert!(
        r.out.contains("parked\ta-two\tradin/wip/a-two\t"),
        "{}",
        r.all()
    );
    assert!(!wt.join("two.txt").exists());
    lane_tree(&w, "b-one");
    let eb = std::path::PathBuf::from(format!("{}-eb", w.p.display()));
    commit_in(&w, &eb, "b.txt", "b\n");
    w.state(&[
        "task-report",
        "b-one",
        "STATUS: BLOCKED (FACT) — which api?",
    ]);
    assert!(eb.join("b.txt").exists());
    assert!(!w.git_ok(&["rev-parse", "--verify", "-q", "radin/wip/b-one"]));
}

#[test]
fn prepare_resumes_a_parked_task_from_its_wip_branch() {
    let w = W::new();
    epics(&w);
    w.lane_mode("lanes");
    let wt = lane_tree(&w, "a-one");
    commit_in(&w, &wt, "w.txt", "wip\n");
    w.state(&["set-status", "a-one", "blocked", "q"]);
    let other = commit_in(&w, &wt, "w.txt", "other\n");
    let r = w.state(&["prepare", "a-one"]);
    assert_eq!(r.code, 1);
    assert!(
        r.err
            .contains("resume of a-one from radin/wip/a-one conflicts with the lane"),
        "{}",
        r.err
    );
    assert!(w.git_ok(&["rev-parse", "--verify", "-q", "radin/wip/a-one"]));
    assert_eq!(w.git_at(&wt, &["status", "--porcelain"]), "");
    w.git_at(&wt, &["reset", "-q", "--hard", &format!("{other}~1")]);
    let r = w.state(&["prepare", "a-one"]);
    assert_eq!(r.code, 0, "{}", r.all());
    assert_eq!(std::fs::read_to_string(wt.join("w.txt")).unwrap(), "wip\n");
    assert!(!w.git_ok(&["rev-parse", "--verify", "-q", "radin/wip/a-one"]));
    assert!(w
        .state(&["journal-tail", "20"])
        .out
        .contains("\"event\":\"resume\""));
}

#[test]
fn park_keeps_the_marker_across_a_retry() {
    let w = W::new();
    epics(&w);
    w.lane_mode("lanes");
    let wt = lane_tree(&w, "a-one");
    let first = w.read(".radin/state/lane-base/a-one");
    commit_in(&w, &wt, "x.txt", "x\n");
    lane_tree(&w, "a-one");
    assert_eq!(w.read(".radin/state/lane-base/a-one"), first);
}

fn finish_lane_task(w: &W, id: &str, file: &str) -> std::path::PathBuf {
    let wt = lane_tree(w, id);
    let hash = commit_in(w, &wt, file, "x\n");
    assert_eq!(w.state(&["task-done", id, &hash[..12]]).code, 0);
    wt
}

fn clean_root(w: &W) {
    w.git(&["add", "-A"]);
    w.git(&["commit", "-qm", "track the ignore file"]);
}

fn run_lane(w: &W, epic: &str) {
    w.write(&format!(".radin/state/lanes/{epic}"), "running\n");
}

#[test]
fn teardown_queues_a_lane_that_still_has_a_ready_task() {
    let w = W::new();
    epics(&w);
    w.lane_mode("lanes");
    clean_root(&w);
    run_lane(&w, "ea");
    finish_lane_task(&w, "a-one", "a1.txt");
    assert_eq!(w.state(&["lane-queue", "ea"]).code, 1);
    w.state(&["teardown"]);
    let r = w.state(&["lane-queue", "ea"]);
    assert_eq!(
        (r.code, r.out.as_str()),
        (0, "queued\tea\t1\n"),
        "{}",
        r.all()
    );
}

#[test]
fn lane_queue_waits_for_the_last_task_then_queues_in_order() {
    let w = W::new();
    epics(&w);
    w.lane_mode("lanes");
    clean_root(&w);
    run_lane(&w, "ea");
    run_lane(&w, "eb");
    let r = w.state(&["lane-queue", "ea"]);
    assert_eq!(
        (r.code, r.err.as_str()),
        (1, "radin-state: lane ea has a ready task\n")
    );
    assert_eq!(w.state(&["lane-queue"]).code, 1);
    finish_lane_task(&w, "a-one", "a1.txt");
    finish_lane_task(&w, "a-two", "a2.txt");
    let r = w.state(&["lane-queue", "ea"]);
    assert_eq!((r.code, r.out.as_str()), (0, "queued\tea\t1\n"));
    assert_eq!(w.state(&["lane-queue", "ea"]).out, "queued\tea\t1\n");
    finish_lane_task(&w, "b-one", "b1.txt");
    assert_eq!(w.state(&["lane-queue", "eb"]).out, "queued\teb\t2\n");
    assert_eq!(
        w.read(".radin/state/merge-queue"),
        "ea\tqueued\neb\tqueued\n"
    );
    let r = w.state(&["lane-queue", "zz"]);
    assert_eq!(
        (r.code, r.err.as_str()),
        (1, "radin-state: lane zz is not running\n")
    );
}

#[test]
fn lane_queue_marks_a_lane_with_no_commit_merged_and_main_mode_prints_nothing() {
    let w = W::new();
    epics(&w);
    w.lane_mode("main");
    let r = w.state(&["lane-queue", "ea"]);
    assert_eq!((r.code, r.out.as_str()), (0, ""));
    assert_eq!(w.state(&["lane-merge"]).code, 1);
    w.lane_mode("lanes");
    run_lane(&w, "eb");
    w.state(&["set-status", "b-one", "failed", "boom"]);
    let r = w.state(&["lane-queue", "eb"]);
    assert_eq!((r.code, r.out.as_str()), (0, "empty\teb\n"), "{}", r.all());
    assert_eq!(w.read(".radin/state/merge-queue"), "eb\tmerged\n");
}

#[test]
fn lane_merge_merges_no_ff_one_lane_at_a_time_and_lane_done_frees_the_queue() {
    let w = W::new();
    epics(&w);
    w.lane_mode("lanes");
    clean_root(&w);
    run_lane(&w, "ea");
    run_lane(&w, "eb");
    let ea = finish_lane_task(&w, "a-one", "a1.txt");
    finish_lane_task(&w, "a-two", "a2.txt");
    let a2 = w.git_at(&ea, &["rev-parse", "HEAD"]);
    finish_lane_task(&w, "b-one", "b1.txt");
    w.state(&["lane-queue", "ea"]);
    w.state(&["lane-queue", "eb"]);
    let before = w.git(&["rev-parse", "HEAD"]);
    let r = w.state(&["lane-merge"]);
    assert_eq!(r.code, 0, "{}", r.all());
    assert!(r.out.starts_with("merged\tea\t"), "{}", r.out);
    assert_eq!(
        w.git(&["rev-list", "--parents", "-n1", "HEAD"])
            .split(' ')
            .count(),
        3
    );
    assert_eq!(w.git(&["rev-parse", "HEAD^1"]), before);
    assert!(w.git_ok(&["merge-base", "--is-ancestor", &a2, "HEAD"]));
    let r = w.state(&["lane-merge"]);
    assert_eq!((r.code, r.out.as_str()), (2, "waiting\tea\n"));
    assert!(!w.git_ok(&["merge-base", "--is-ancestor", "radin/eb", "HEAD"]));
    let gate = w.state(&[
        "lane-gate",
        "ea",
        "--report",
        "STATUS: SUCCESS — checks green",
    ]);
    assert_eq!(gate.out, "green\tea\n");
    let r = w.state(&["lane-done", "ea"]);
    assert_eq!(r.code, 0, "{}", r.all());
    assert!(!ea.exists());
    assert!(!w.git_ok(&["rev-parse", "--verify", "-q", "radin/ea"]));
    assert_eq!(w.read(".radin/state/merge-queue"), "eb\tqueued\n");
    let r = w.state(&["lane-merge"]);
    assert!(r.out.starts_with("merged\teb\t"), "{}", r.all());
    assert!(w.git_ok(&["merge-base", "--is-ancestor", "radin/eb", "HEAD"]));
    w.state(&["lane-gate", "eb", "--report", "STATUS: SUCCESS — ok"]);
    assert_eq!(w.state(&["lane-done", "eb"]).code, 0);
    assert_eq!(w.state(&["lane-merge"]).code, 1);
}

#[test]
fn lane_merge_hands_a_conflict_to_the_sync_agent_and_a_held_lane_yields_the_queue() {
    let w = W::new();
    epics(&w);
    w.lane_mode("lanes");
    clean_root(&w);
    run_lane(&w, "ea");
    run_lane(&w, "eb");
    let ea = finish_lane_task(&w, "a-one", "c.txt");
    finish_lane_task(&w, "a-two", "a2.txt");
    finish_lane_task(&w, "b-one", "b1.txt");
    commit_in(&w, &w.p, "c.txt", "main\n");
    w.state(&["lane-queue", "ea"]);
    w.state(&["lane-queue", "eb"]);
    let r = w.state(&["lane-merge"]);
    assert_eq!(r.code, 3, "{}", r.all());
    assert_eq!(r.out, format!("conflict\tea\t{}\n", ea.display()));
    assert_eq!(w.state(&["lane-merge"]).code, 3);
    assert!(!w.git_ok(&["merge-base", "--is-ancestor", "radin/ea", "HEAD"]));
    let r = w.state(&["lane-merge", "--abort"]);
    assert_eq!((r.code, r.out.as_str()), (0, "held\tea\n"));
    assert_eq!(w.git_at(&ea, &["status", "--porcelain"]), "");
    assert_eq!(w.read(".radin/state/merge-queue"), "ea\theld\neb\tqueued\n");
    let r = w.state(&["lane-merge"]);
    assert!(r.out.starts_with("merged\teb\t"), "{}", r.all());
}

#[test]
fn a_resolved_conflict_merges_on_the_next_call() {
    let w = W::new();
    epics(&w);
    w.lane_mode("lanes");
    clean_root(&w);
    run_lane(&w, "ea");
    let ea = finish_lane_task(&w, "a-one", "c.txt");
    finish_lane_task(&w, "a-two", "a2.txt");
    commit_in(&w, &w.p, "c.txt", "main\n");
    w.state(&["lane-queue", "ea"]);
    assert_eq!(w.state(&["lane-merge"]).code, 3);
    std::fs::write(ea.join("c.txt"), "both\n").unwrap();
    w.git_at(&ea, &["add", "c.txt"]);
    let r = w.state(&["lane-merge"]);
    assert_eq!(r.code, 0, "{}", r.all());
    assert!(r.out.starts_with("merged\tea\t"), "{}", r.out);
    assert_eq!(
        std::fs::read_to_string(w.p.join("c.txt")).unwrap(),
        "both\n"
    );
}

#[test]
fn reconcile_leaves_a_running_lane_branch_alone_and_lanes_init_drops_the_queue() {
    let w = W::new();
    epics(&w);
    w.lane_mode("lanes");
    clean_root(&w);
    run_lane(&w, "ea");
    finish_lane_task(&w, "a-one", "a1.txt");
    let r = w.state(&["reconcile"]);
    assert!(r.out.contains("skipped\tradin/ea\tlane\n"), "{}", r.all());
    assert!(w.git_ok(&["rev-parse", "--verify", "-q", "radin/ea"]));
    merged(&w, "ea");
    w.state(&["lanes-init"]);
    assert!(!w.exists(".radin/state/merge-queue"));
}

#[test]
fn completed_show_prints_the_acceptance_and_epic() {
    let w = W::new();
    epics(&w);
    w.lane_mode("lanes");
    finish_lane_task(&w, "a-one", "a1.txt");
    let out = w.state(&["completed-show", "a-one"]).out;
    assert!(out.contains("\nepic\tea\n"), "{out}");
    assert!(out.contains("\nacceptance\t"), "{out}");
}

fn queue_and_merge(w: &W, epic: &str) -> String {
    assert_eq!(w.state(&["lane-queue", epic]).code, 0);
    let r = w.state(&["lane-merge"]);
    assert_eq!(r.code, 0, "{}", r.all());
    r.out.trim().rsplit('\t').next().unwrap().to_string()
}

fn merged_ea(w: &W) -> String {
    epics(w);
    w.lane_mode("lanes");
    clean_root(w);
    run_lane(w, "ea");
    finish_lane_task(w, "a-one", "a1.txt");
    finish_lane_task(w, "a-two", "a2.txt");
    queue_and_merge(w, "ea")
}

const FAIL: &str = "STATUS: FAILED — lint\tred";

fn red_ea(w: &W) -> String {
    merged_ea(w);
    assert_eq!(
        w.state(&["lane-gate", "ea", "--report", FAIL]).out,
        "retry\tea\t2\n"
    );
    let r = w.state(&["lane-gate", "ea", "--report", FAIL]);
    let id = r
        .out
        .strip_prefix("red\tea\t")
        .unwrap_or_else(|| panic!("{}", r.all()));
    id.trim().to_string()
}

#[test]
fn lane_gate_runs_after_the_merge_and_a_green_report_frees_lane_done() {
    let w = W::new();
    epics(&w);
    w.lane_mode("lanes");
    clean_root(&w);
    run_lane(&w, "ea");
    finish_lane_task(&w, "a-one", "a1.txt");
    finish_lane_task(&w, "a-two", "a2.txt");
    let r = w.state(&["lane-gate", "ea"]);
    assert_eq!(
        (r.code, r.err.as_str()),
        (1, "radin-state: lane ea has not merged\n")
    );
    let hash = queue_and_merge(&w, "ea");
    assert_eq!(w.state(&["lane-gate", "ea"]).out, "run\tea\t1\n");
    let r = w.state(&["lane-done", "ea"]);
    assert_eq!(
        (r.code, r.err.as_str()),
        (1, "radin-state: lane ea gate is run\n")
    );
    let map = w.state(&["lane-gate", "ea", "--map"]).out;
    assert_eq!(
        map,
        format!("{}\t{hash}\t{}\t{hash}\n", w.base(), w.p.display())
    );
    let r = w.state(&[
        "lane-gate",
        "ea",
        "--report",
        "`STATUS: SUCCESS — checks green at abc`",
    ]);
    assert_eq!(r.out, "green\tea\n");
    assert_eq!(w.state(&["lane-gate", "ea"]).out, "green\tea\n");
    assert_eq!(w.state(&["lane-gate", "ea", "--report", FAIL]).code, 1);
    assert_eq!(w.state(&["lane-done", "ea"]).code, 0);
}

#[test]
fn two_failed_gates_file_a_priority_21_fix_with_the_lane_tasks_and_the_failures() {
    let w = W::new();
    let merge = merged_ea(&w);
    assert_eq!(
        w.state(&["lane-gate", "ea", "--report", FAIL]).out,
        "retry\tea\t2\n"
    );
    let map = w.state(&["lane-gate", "ea", "--map"]).out;
    assert!(
        map.ends_with("\nprevious\tSTATUS: FAILED — lint red\n"),
        "{map}"
    );
    let r = w.state(&[
        "lane-gate",
        "ea",
        "--report",
        "STATUS: INCONCLUSIVE — no cargo",
    ]);
    let id = format!("fix-red-{}-after-lane-ea", w.base());
    assert_eq!(r.out, format!("red\tea\t{id}\n"), "{}", r.all());
    let body = std::fs::read_to_string(w.task_file(&id)).unwrap();
    assert!(
        body.contains(&format!("merged into {} at {merge}", w.base())),
        "{body}"
    );
    assert!(body.contains("**Introduced by:** a-one, a-two\n"), "{body}");
    assert!(
        body.trim_end().ends_with(
            "- attempt 1: STATUS: FAILED — lint red\n- attempt 2: STATUS: INCONCLUSIVE — no cargo"
        ),
        "{body}"
    );
    let meta = w.bl(&["meta", &id], "").out;
    assert!(meta.contains("origin\ta-one"), "{meta}");
    let list = w.bl(&["list", "--order", "created"], "").out;
    let row = list.lines().find(|l| l.starts_with(&id)).unwrap();
    assert!(row.contains("maintenance"), "{row}");
    assert!(row.split('\x1f').any(|f| f == "21"), "{row:?}");
    assert!(w.read(".radin/state/BACKLOG_STEPS.json").contains(&format!(
        "{{\"id\":\"{id}\",\"order\":0,\"status\":\"pending\""
    )));
    assert_eq!(w.read(&format!(".radin/state/hotfix/{id}")), "open\n");
    assert_eq!(
        w.state(&["lane-gate", "ea"]).out,
        format!("red\tea\t{id}\n")
    );
    assert_eq!(w.bl(&["list", "--order", "created"], "").out, list);
}

#[test]
fn a_gate_with_no_lane_task_in_the_merge_files_a_fix_without_origin() {
    let w = W::new();
    epics(&w);
    w.lane_mode("lanes");
    clean_root(&w);
    run_lane(&w, "ea");
    w.state(&["set-status", "a-one", "failed", "boom"]);
    w.state(&["set-status", "a-two", "failed", "boom"]);
    commit_in(&w, &lane_tree(&w, "a-one"), "x.txt", "x\n");
    queue_and_merge(&w, "ea");
    w.state(&["lane-gate", "ea", "--report", FAIL]);
    let r = w.state(&["lane-gate", "ea", "--report", FAIL]);
    let id = r.out.trim().rsplit('\t').next().unwrap().to_string();
    let body = std::fs::read_to_string(w.task_file(&id)).unwrap();
    assert!(
        body.contains("**Introduced by:** no lane task matched"),
        "{body}"
    );
    assert!(!w.bl(&["meta", &id], "").out.contains("origin"));
}

fn hotfix_merged(w: &W, id: &str) {
    let wt = format!("{}-hotfix-{id}", w.p.display());
    assert_eq!(w.prep_dir(id), wt);
    assert_eq!(
        w.git_at(Path::new(&wt), &["branch", "--show-current"]),
        format!("radin/hotfix-{id}")
    );
    finish_lane_task(w, id, "fix.txt");
    assert_eq!(queue_and_merge(w, &format!("hotfix-{id}")).len(), 12);
}

#[test]
fn an_open_hotfix_pauses_the_queue_takes_a_slot_without_a_judge_and_closes_on_green() {
    let w = W::new();
    let id = red_ea(&w);
    assert_eq!(w.state(&["lane-merge"]).out, "waiting\tea\n");
    assert_eq!(
        w.state(&["lane-done", "ea"]).code,
        0,
        "a red lane may finish"
    );
    run_lane(&w, "eb");
    w.write(".radin/state/merge-queue", "eb\tqueued\n");
    let r = w.state(&["lane-merge"]);
    assert_eq!(
        (r.code, r.out.as_str()),
        (2, format!("paused\teb\t{id}\n").as_str())
    );
    let r = w.state(&["lane-next"]);
    assert_eq!(
        (r.code, r.out.as_str()),
        (0, format!("start\thotfix-{id}\n").as_str()),
        "{}",
        r.all()
    );
    finish_lane_task(&w, "b-one", "b1.txt");
    let wt = format!("{}-hotfix-{id}", w.p.display());
    assert_eq!(w.prep_dir(&id), wt);
    finish_lane_task(&w, &id, "fix.txt");
    let r = w.state(&["lane-queue", &format!("hotfix-{id}")]);
    assert_eq!(r.out, format!("queued\thotfix-{id}\t1\n"), "{}", r.all());
    assert_eq!(
        w.read(".radin/state/merge-queue"),
        format!("hotfix-{id}\tqueued\neb\tqueued\n")
    );
    let r = w.state(&["lane-merge"]);
    assert!(
        r.out.starts_with(&format!("merged\thotfix-{id}\t")),
        "{}",
        r.all()
    );
    let hot = format!("hotfix-{id}");
    assert_eq!(
        w.state(&["lane-gate", &hot, "--report", "STATUS: SUCCESS — ok"])
            .out,
        format!("green\t{hot}\n")
    );
    assert_eq!(w.read(&format!(".radin/state/hotfix/{id}")), "open\n");
    assert_eq!(w.state(&["lane-done", &hot]).code, 0);
    assert_eq!(w.read(&format!(".radin/state/hotfix/{id}")), "closed\n");
    let r = w.state(&["lane-merge"]);
    assert!(r.out.starts_with("merged\teb\t"), "{}", r.all());
}

#[test]
fn a_hotfix_lane_that_fails_twice_asks_the_user_and_files_no_entry() {
    let w = W::new();
    let id = red_ea(&w);
    w.state(&["lane-done", "ea"]);
    assert_eq!(w.state(&["lane-next"]).out, format!("start\thotfix-{id}\n"));
    hotfix_merged(&w, &id);
    let hot = format!("hotfix-{id}");
    let before = w.bl(&["list", "--order", "created"], "").out;
    assert_eq!(
        w.state(&["lane-gate", &hot, "--report", FAIL]).out,
        format!("retry\t{hot}\t2\n")
    );
    assert_eq!(
        w.state(&["lane-gate", &hot, "--report", FAIL]).out,
        format!("ask\t{hot}\n")
    );
    assert_eq!(w.bl(&["list", "--order", "created"], "").out, before);
    let r = w.state(&["lane-done", &hot]);
    assert_eq!(r.err, format!("radin-state: lane {hot} gate is ask\n"));
    assert_eq!(
        w.state(&["lane-gate", &hot, "--reset"]).out,
        format!("run\t{hot}\t1\n")
    );
    assert_eq!(w.state(&["lane-gate", &hot, "--reset"]).code, 1);
}

#[test]
fn lanes_init_clears_gate_and_hotfix_files_and_rejects_a_hotfix_epic_while_main_prints_nothing() {
    let w = W::new();
    epics(&w);
    w.write(".radin/state/gate/ea", "green\n");
    w.write(".radin/state/hotfix/x", "open\n");
    assert_eq!(w.state(&["lanes-init"]).code, 0);
    assert!(!w.exists(".radin/state/gate/ea") && !w.exists(".radin/state/hotfix/x"));
    w.lane_mode("main");
    let r = w.state(&["lane-gate", "ea"]);
    assert_eq!((r.code, r.out.as_str()), (0, ""));
    assert_eq!(w.state(&["lane-gate"]).code, 1);
    w.bl(&["epic-add", "hotfix-z"], "");
    assert_eq!(
        w.bl(&["add", "fix", "z one", "--epic", "hotfix-z"], "body\n")
            .code,
        0
    );
    w.steps_init("a-one\t1\t\tpending\nz-one\t2\t\tpending\n");
    let r = w.state(&["lanes-init"]);
    assert_eq!(
        (r.code, r.err.as_str()),
        (1, "radin-state: epic hotfix-z is reserved\n")
    );
}

fn wait_a_second() {
    std::thread::sleep(std::time::Duration::from_millis(1100));
}

#[test]
fn lanes_recover_parks_unverified_work_and_queues_the_lane() {
    let w = W::new();
    epics(&w);
    w.lane_mode("lanes");
    clean_root(&w);
    let wt = finish_lane_task(&w, "a-one", "a1.txt");
    let marker = w.git_at(&wt, &["rev-parse", "HEAD"]);
    w.prep_dir("a-two");
    std::fs::write(wt.join("w.txt"), "partial\n").unwrap();
    w.lane_mode("main");
    let r = w.state(&["lanes-recover"]);
    assert_eq!(r.code, 0, "{}", r.all());
    assert!(
        r.out.contains("parked\ta-two\tradin/wip/a-two\t"),
        "{}",
        r.out
    );
    assert!(r.out.ends_with("queued\tea\t1\n"), "{}", r.out);
    assert_eq!(w.read(".radin/state/lane-mode"), "lanes\n");
    assert_eq!(w.git_at(&wt, &["rev-parse", "HEAD"]), marker);
    assert_eq!(w.git_at(&wt, &["status", "--porcelain"]), "");
    assert_eq!(w.git(&["show", "radin/wip/a-two:w.txt"]), "partial");
    assert_eq!(w.read(".radin/state/lanes/ea"), "running\n");
    let r = w.state(&["lane-merge"]);
    assert!(r.out.starts_with("merged\tea\t"), "{}", r.all());
    assert!(!w.p.join("w.txt").exists());
    assert!(w.p.join("a1.txt").exists());
}

#[test]
fn lanes_recover_queue_orders_oldest_tip_first_and_drops_stale_rows_and_empty_lanes() {
    let w = W::new();
    epics(&w);
    assert_eq!(w.bl(&["epic-add", "ec"], "").code, 0);
    w.lane_mode("lanes");
    clean_root(&w);
    finish_lane_task(&w, "b-one", "b1.txt");
    wait_a_second();
    finish_lane_task(&w, "a-one", "a1.txt");
    w.git(&["branch", "radin/ec"]);
    w.write(".radin/state/merge-queue", "eb\theld\nzz\tqueued\n");
    let r = w.state(&["lanes-recover"]);
    assert_eq!(r.code, 0, "{}", r.all());
    assert_eq!(r.out, "dropped\tradin/ec\nqueued\teb\t1\nqueued\tea\t2\n");
    assert_eq!(
        w.read(".radin/state/merge-queue"),
        "eb\tqueued\nea\tqueued\n"
    );
    assert!(!w.git_ok(&["rev-parse", "--verify", "-q", "radin/ec"]));
    assert_eq!(w.read(".radin/state/lanes/eb"), "running\n");
    assert!(!w.exists(".radin/state/lanes/zz"));
}

#[test]
fn lanes_recover_routes_a_merged_row_and_repairs_its_missing_merge_record() {
    let w = W::new();
    epics(&w);
    w.lane_mode("lanes");
    clean_root(&w);
    merged(&w, "ea");
    let r = w.state(&["lanes-recover"]);
    assert_eq!(
        (r.code, r.out.as_str()),
        (0, "merged\tea\t-\n"),
        "{}",
        r.all()
    );
    assert_eq!(w.state(&["lane-done", "ea"]).code, 0);

    let w = W::new();
    epics(&w);
    w.lane_mode("lanes");
    clean_root(&w);
    run_lane(&w, "ea");
    finish_lane_task(&w, "a-one", "a1.txt");
    finish_lane_task(&w, "a-two", "a2.txt");
    w.state(&["lane-queue", "ea"]);
    w.state(&["lane-merge"]);
    let record = w.read(".radin/state/gate/ea");
    assert!(record.starts_with("merge\t"), "{record}");
    w.write(".radin/state/gate/ea", "");
    let r = w.state(&["lanes-recover"]);
    assert_eq!(r.out, "merged\tea\t-\n", "{}", r.all());
    assert_eq!(w.read(".radin/state/gate/ea"), record);

    let w = W::new();
    epics(&w);
    w.lane_mode("lanes");
    clean_root(&w);
    run_lane(&w, "ea");
    finish_lane_task(&w, "a-one", "a1.txt");
    w.write(".radin/state/merge-queue", "ea\tmerged\n");
    let r = w.state(&["lanes-recover"]);
    assert_eq!(r.out, "queued\tea\t1\n", "{}", r.all());
    assert_eq!(w.read(".radin/state/merge-queue"), "ea\tqueued\n");
}

#[test]
fn lanes_recover_keeps_a_dirty_lane_and_lists_wip_tasks_and_closes_an_orphan_hotfix() {
    let w = W::new();
    let r = w.state(&["lanes-recover"]);
    assert_eq!((r.code, r.out.as_str()), (1, ""), "{}", r.all());
    epics(&w);
    w.lane_mode("lanes");
    clean_root(&w);
    let wt = lane_tree(&w, "a-one");
    std::fs::remove_file(w.p.join(".radin/state/lane-base/a-one")).unwrap();
    std::fs::write(wt.join("d.txt"), "dirty\n").unwrap();
    w.git(&["branch", "radin/wip/b-one"]);
    w.git(&["branch", "radin/wip/gone"]);
    w.write(".radin/state/hotfix/xx", "open\n");
    let r = w.state(&["lanes-recover"]);
    assert_eq!(r.code, 0, "{}", r.all());
    assert!(
        r.out.contains(&format!(
            "kept\tradin/ea\tuncommitted changes in {}\n",
            wt.display()
        )),
        "{}",
        r.out
    );
    assert!(
        r.out.contains("resume\tb-one\tradin/wip/b-one\n"),
        "{}",
        r.out
    );
    assert!(
        r.out
            .contains("kept\tradin/wip/gone\ttask is not on the backlog\n"),
        "{}",
        r.out
    );
    assert!(!r.out.contains("queued"), "{}", r.out);
    assert_eq!(w.read(".radin/state/hotfix/xx"), "closed\n");
    assert!(wt.join("d.txt").exists());
    let rep = w.state(&["report"]);
    assert!(
        rep.out
            .contains("Lane branches kept (not merged, retried next batch):\n- ea — radin/ea at "),
        "{}",
        rep.all()
    );
}

#[test]
fn lanes_recover_aborts_a_merge_left_in_a_lane_tree() {
    let w = W::new();
    epics(&w);
    w.lane_mode("lanes");
    clean_root(&w);
    w.state(&["lane-sync", "a-one"]);
    let wt = std::path::PathBuf::from(format!("{}-ea", w.p.display()));
    commit_in(&w, &wt, "c.txt", "lane\n");
    commit_in(&w, &w.p, "c.txt", "main\n");
    assert_eq!(w.state(&["lane-sync", "a-one"]).code, 3);
    let r = w.state(&["lanes-recover"]);
    assert_eq!(r.out, "queued\tea\t1\n", "{}", r.all());
    assert!(
        !common::git_in(&wt, &["rev-parse", "-q", "--verify", "MERGE_HEAD"])
            .status
            .success()
    );
    assert_eq!(w.git_at(&wt, &["status", "--porcelain"]), "");
}

#[test]
fn recover_parks_a_lane_task_and_lists_only_its_own_commits() {
    let w = W::new();
    epics(&w);
    w.lane_mode("lanes");
    clean_root(&w);
    let wt = finish_lane_task(&w, "a-one", "a1.txt");
    w.prep_dir("a-two");
    commit_in(&w, &wt, "a2.txt", "two\n");
    let r = w.state(&["recover", "a-two"]);
    assert_eq!(r.code, 3, "{}", r.all());
    assert_eq!(r.out.matches("branch_commit\t").count(), 1, "{}", r.out);
    let r = w.state(&["recover-reject", "a-two"]);
    assert_eq!(r.code, 0, "{}", r.all());
    assert!(
        r.out.starts_with("parked\ta-two\tradin/wip/a-two\t"),
        "{}",
        r.out
    );
    assert!(r.out.contains("they sit on radin/wip/a-two"), "{}", r.out);
    assert_eq!(w.git_at(&wt, &["status", "--porcelain"]), "");
    assert!(!wt.join("a2.txt").exists());

    let eb = lane_tree(&w, "b-one");
    std::fs::write(eb.join("d.txt"), "dirty\n").unwrap();
    let r = w.state(&["recover", "b-one"]);
    assert_eq!(r.code, 0, "{}", r.all());
    assert!(
        r.out.starts_with("parked\tb-one\tradin/wip/b-one\t"),
        "{}",
        r.out
    );
    assert!(
        r.out
            .contains("recovered\tb-one\tparked on radin/wip/b-one"),
        "{}",
        r.out
    );
    assert_eq!(w.git_at(&eb, &["status", "--porcelain"]), "");
}

#[test]
fn prepare_resumes_a_parked_task_in_main_mode() {
    let w = W::new();
    epics(&w);
    w.lane_mode("lanes");
    clean_root(&w);
    let wt = lane_tree(&w, "a-one");
    commit_in(&w, &wt, "w.txt", "wip\n");
    w.state(&["set-status", "a-one", "blocked", "q"]);
    assert!(w.git_ok(&["rev-parse", "--verify", "-q", "radin/wip/a-one"]));
    w.lane_mode("main");
    let r = w.state(&["prepare", "a-one"]);
    assert_eq!(r.code, 0, "{}", r.all());
    assert_eq!(std::fs::read_to_string(w.p.join("w.txt")).unwrap(), "wip\n");
    assert!(!w.git_ok(&["rev-parse", "--verify", "-q", "radin/wip/a-one"]));
}

#[test]
fn reconcile_skips_a_lane_branch_with_no_marker_and_no_lane_mode_file() {
    let w = W::new();
    epics(&w);
    w.lane_mode("lanes");
    clean_root(&w);
    finish_lane_task(&w, "a-one", "a1.txt");
    std::fs::remove_file(w.p.join(".radin/state/lane-mode")).unwrap();
    let r = w.state(&["reconcile"]);
    assert!(r.out.contains("skipped\tradin/ea\tlane\n"), "{}", r.all());
    assert!(w.git_ok(&["rev-parse", "--verify", "-q", "radin/ea"]));
}

#[test]
fn preflight_reports_leftovers_for_a_lone_wip_branch_a_queue_row_or_a_lane_base() {
    let w = W::new();
    epics(&w);
    assert!(!w.state(&["preflight"]).out.contains("leftovers"));
    w.git(&["branch", "radin/wip/a-one"]);
    assert!(w.state(&["preflight"]).out.contains("leftovers\n"));
    w.git(&["branch", "-D", "radin/wip/a-one"]);
    w.write(".radin/state/merge-queue", "ea\tqueued\n");
    assert!(w.state(&["preflight"]).out.contains("leftovers\n"));
    w.write(".radin/state/merge-queue", "");
    w.write(".radin/state/lane-base/a-one", "abc\n");
    assert!(w.state(&["preflight"]).out.contains("leftovers\n"));
}

#[test]
fn task_next_lane_picks_per_epic_refuses_a_waiting_lane_and_honors_teardown() {
    let w = W::new();
    epics(&w);
    w.state(&["lanes-init"]);
    let r = w.state(&["task-next", "--lane", "eb"]);
    assert_eq!(r.code, 1, "{}", r.all());
    assert!(r.err.contains("lane eb is not running"), "{}", r.err);
    w.state(&["lane-next"]);
    w.state(&["lane-next", "--cleared", "eb"]);
    let r = w.state(&["task-next", "--lane", "eb"]);
    assert_eq!(r.code, 0, "{}", r.all());
    assert!(r.out.starts_with("id\tb-one\n"), "{}", r.out);
    let r = w.state(&["task-next", "--lane", "ea"]);
    assert!(r.out.starts_with("id\ta-one\n"), "{}", r.out);
    assert_eq!(w.state(&["task-next", "--lane", "eb"]).code, 1);
    assert_eq!(w.state(&["task-next", "--lane"]).code, 1);
    w.state(&["teardown"]);
    assert_eq!(w.state(&["task-next", "--lane", "ea"]).code, 1);
}

#[test]
fn lane_judge_records_one_judged_line_per_decision() {
    let w = W::new();
    epics(&w);
    let cases = [
        ("STATUS: PARALLEL — yes: disjoint", "yes", "disjoint"),
        (
            "STATUS: PARALLEL — no: both edit cli",
            "no",
            "both edit cli",
        ),
        ("maybe", "no", "no PARALLEL line: maybe"),
    ];
    for (line, verdict, reason) in cases {
        let r = w.state(&["lane-judge", "ea", "eb", line]);
        assert_eq!(r.code, 0, "{}", r.all());
        assert_eq!(r.out, format!("judged\tea\teb\t{verdict}\n"));
        let last = w.tele.borrow().last().unwrap().clone();
        assert!(
            last.starts_with(&format!(
                "judged epic=ea with=eb verdict={verdict} reason={reason} evidence="
            )),
            "{last}"
        );
    }
    assert_eq!(w.tele.borrow().len(), 3);
    assert_eq!(w.state(&["lane-judge", "ea", "eb"]).code, 1);
}

#[test]
fn lanes_view_lists_running_lanes_with_task_sync_and_queue() {
    let w = W::new();
    epics(&w);
    assert_eq!(w.state(&["lanes-view"]).out, "");
    w.state(&["lanes-init"]);
    w.state(&["lane-next"]);
    assert_eq!(w.state(&["lanes-view"]).out, "lane\tea\t-\tnone\t-\n");
    w.state(&["set-status", "a-one", "in_progress"]);
    assert_eq!(w.state(&["lanes-view"]).out, "lane\tea\ta-one\tnone\t-\n");
    w.state(&["lane-next", "--cleared", "eb"]);
    w.write(".radin/state/merge-queue", "ea\tqueued\neb\tqueued\n");
    assert_eq!(
        w.state(&["lanes-view"]).out,
        "lane\tea\ta-one\tnone\t1\nlane\teb\t-\tnone\t2\n"
    );
    w.write(".radin/state/merge-queue", "ea\tmerged\n");
    assert_eq!(
        w.state(&["lanes-view"]).out.lines().next(),
        Some("lane\tea\ta-one\tnone\tmerged")
    );
}

#[test]
fn lanes_view_derives_sync_from_the_lane_worktree() {
    let w = W::new();
    epics(&w);
    w.lane_mode("lanes");
    w.write(".radin/state/lanes/ea", "running\n");
    let sync = || {
        w.state(&["lanes-view"])
            .out
            .split('\t')
            .nth(3)
            .unwrap()
            .to_string()
    };
    w.state(&["lane-sync", "a-one"]);
    assert_eq!(sync(), "current");
    commit_in(&w, &w.p, "m.txt", "main\n");
    assert_eq!(sync(), "behind");
    let wt = std::path::PathBuf::from(format!("{}-ea", w.p.display()));
    commit_in(&w, &wt, "c.txt", "lane\n");
    commit_in(&w, &w.p, "c.txt", "main\n");
    assert_eq!(w.state(&["lane-sync", "a-one"]).code, 3);
    assert_eq!(sync(), "conflict");
    std::fs::write(wt.join("c.txt"), "both\n").unwrap();
    w.git_at(&wt, &["add", "c.txt"]);
    assert_eq!(sync(), "merging");
}

#[test]
fn a_lane_map_prints_risk_high_only_after_a_lane_task_reported_high_risk() {
    let w = W::new();
    merged_ea(&w);
    assert!(!w.state(&["lane-gate", "ea", "--map"]).out.contains("risk"));
    let j = ".radin/state/journal.jsonl";
    let line = "{\"ts\":\"2026-01-01T00:00:00Z\",\"event\":\"risk\",\"id\":\"a-two\",\"detail\":\"high\"}\n";
    w.write(j, &format!("{}{line}", w.read(j)));
    let map = w.state(&["lane-gate", "ea", "--map"]).out;
    assert!(map.ends_with("\nrisk\thigh\n"), "{map}");
}

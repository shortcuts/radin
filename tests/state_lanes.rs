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
    assert_eq!(w.state(&["lane-done", "ea"]).code, 0);
    assert_eq!(w.state(&["lane-next"]).code, 1);
    assert_eq!(w.state(&["lane-next", "--bogus"]).code, 1);
}

#[test]
fn a_dependent_epic_starts_only_after_its_dependency_lane_is_done() {
    let w = W::new();
    epics(&w);
    w.bl(&["epic-set-deps", "eb", "ea"], "");
    w.state(&["lanes-init"]);
    assert_eq!(w.state(&["lane-next"]).out, "start\tea\n");
    assert_eq!(w.state(&["lane-next"]).code, 1);
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
        w.read(".radin/state/prepared/a-one.json"),
        format!("{{\"branch\":\"{base}\",\"worktree\":\"\",\"lane\":\"\"}}\n")
    );
    w.lane_mode("lanes");
    let wt = format!("{}-ea", w.p.display());
    assert_eq!(w.prep_dir("a-one"), wt);
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
    assert!(w.state(&["completed-show", "a-one"]).out.contains(&hash));
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

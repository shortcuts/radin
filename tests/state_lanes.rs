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

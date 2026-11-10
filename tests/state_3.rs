mod common;
use common::W;

#[test]
fn reconcile_lands_a_stack_in_dependency_order_one_squash_per_task_even_when_both_edit_the_same_line(
) {
    let w = W::new();
    let base = w.stack_setup();
    let dir = w.prep_dir("t-two");
    let dir = std::path::Path::new(&dir);
    std::fs::write(dir.join("shared.txt"), "one\nfrom-two\n").unwrap();
    w.git_at(dir, &["commit", "-qam", "feat: t-two"]);
    let tip = w.git(&["rev-parse", "--short=12", "radin/t-two"]);
    w.write(".radin/state/unmerged/t-two", &format!("{tip}\n"));
    let r = w.state(&["reconcile"]);
    assert_eq!(r.code, 0, "{}", r.all());
    let one = r.out.find("merged\tradin/t-one\t").expect("t-one merged");
    let two = r.out.find("merged\tradin/t-two\t").expect("t-two merged");
    assert!(one < two, "{}", r.out);
    let subjects: Vec<String> = w
        .git(&["log", "--format=%s", &base])
        .lines()
        .take(2)
        .map(String::from)
        .collect();
    assert_eq!(subjects.join(","), "feat: t-two,feat: t-one");
    assert_eq!(w.read("shared.txt"), "one\nfrom-two\n");
    let mut ids: Vec<String> = w
        .state(&["completed-list"])
        .out
        .lines()
        .map(|l| l.split('\t').next().unwrap().to_string())
        .collect();
    ids.sort();
    assert_eq!(ids.join(","), "t-one,t-two");
    assert!(w.git(&["branch", "--list", "radin/*"]).is_empty());
    assert!(!w.exists(".radin/state/stacked/t-two"));
}

#[test]
fn reconcile_leaves_a_dependent_waiting_while_its_parent_branch_conflicts() {
    let w = W::new();
    w.stack_setup();
    let dir = w.prep_dir("t-two");
    let dir = std::path::Path::new(&dir);
    std::fs::write(dir.join("two.txt"), "two\n").unwrap();
    w.git_at(dir, &["add", "two.txt"]);
    w.git_at(dir, &["commit", "-qm", "feat: t-two"]);
    let tip = w.git(&["rev-parse", "--short=12", "radin/t-two"]);
    w.write(".radin/state/unmerged/t-two", &format!("{tip}\n"));
    w.write("shared.txt", "clash\n");
    w.git(&["commit", "-qam", "base clash"]);
    let r = w.state(&["reconcile"]);
    assert_eq!(r.code, 3, "{}", r.all());
    assert!(r.out.contains("conflict\tradin/t-one"), "{}", r.out);
    assert!(
        r.out
            .contains("skipped\tradin/t-two\twaiting on radin/t-one"),
        "{}",
        r.out
    );
    assert!(!w.git(&["branch", "--list", "radin/t-two"]).is_empty());
}

#[test]
fn prepare_wip_commits_a_dirty_tree_while_the_default_gitignore_hides_radin() {
    let w = W::new();
    w.write("a.txt", "draft\n");
    assert_eq!(w.state(&["session-set", "no", "no"]).code, 0);
    let r = w.state(&["prepare", "t-one"]);
    assert_eq!(r.code, 0, "{}", r.all());
    assert_eq!(
        w.git(&["log", "-1", "--format=%s"]),
        "wip: update .gitignore, a.txt"
    );
    assert!(w.git(&["status", "--porcelain"]).is_empty());
    assert!(!r.all().contains("ignored by one of your"));
}

fn ids(w: &W, args: &[&str], ids: &str) -> common::Run {
    w.state_in(args, ids)
}

#[test]
fn wave_partition_puts_tasks_with_disjoint_paths_in_one_group_and_prints_no_apart_line() {
    let w = W::new();
    w.planned("w a", &["lib/a.sh"]);
    w.planned("w b", &["lib/b.sh"]);
    w.planned("w c", &["docs/c.md"]);
    let r = ids(&w, &["wave-partition"], "w-a\nw-b\nw-c\n");
    assert_eq!((r.code, r.out.as_str()), (0, "group\t3\tw-a,w-b,w-c\n"));
}

#[test]
fn wave_partition_keeps_a_directory_apart_from_a_file_under_it_and_prints_the_shared_path() {
    let w = W::new();
    w.planned("w a", &["lib/x.sh"]);
    w.planned("w b", &["lib/"]);
    w.planned("w c", &["docs/y.md"]);
    let r = ids(&w, &["wave-partition"], "w-a\nw-b\nw-c\n");
    assert_eq!(
        (r.code, r.out.as_str()),
        (
            0,
            "group\t2\tw-a,w-c\ngroup\t1\tw-b\napart\tw-a\tw-b\tlib/x.sh\n"
        )
    );
}

#[test]
fn wave_partition_does_not_match_a_file_name_by_string_prefix() {
    let w = W::new();
    std::fs::create_dir_all(w.p.join("lib/a")).unwrap();
    w.planned("w a", &["lib/a"]);
    w.planned("w b", &["lib/ab.sh"]);
    w.planned("w c", &["lib/a/z.sh"]);
    let r = ids(&w, &["wave-partition"], "w-a\nw-b\nw-c\n");
    assert_eq!(
        (r.code, r.out.as_str()),
        (
            0,
            "group\t2\tw-a,w-b\ngroup\t1\tw-c\napart\tw-a\tw-c\tlib/a/z.sh\n"
        )
    );
}

#[test]
fn wave_partition_makes_a_task_with_no_plan_paths_a_closed_group_of_1_and_names_it() {
    let w = W::new();
    w.planned("w a", &["lib/a.sh"]);
    w.planned("w b", &[]);
    w.planned("w c", &["lib/c.sh"]);
    let r = ids(&w, &["wave-partition"], "w-a\nw-b\nw-c\n");
    assert_eq!(
        (r.code, r.out.as_str()),
        (0, "group\t2\tw-a,w-c\ngroup\t1\tw-b\nunplanned\tw-b\n")
    );
}

fn exclusive(w: &W, id: &str) {
    assert_eq!(w.bl(&["set-meta", id, "exclusive", "yes"], "").code, 0);
}

#[test]
fn wave_partition_gives_an_exclusive_task_a_group_of_its_own_and_keeps_its_apart_line() {
    let w = W::new();
    w.planned("w a", &["lib/a.sh"]);
    w.planned("w b", &["lib/b.sh"]);
    w.planned("w c", &["lib/c.sh"]);
    w.planned("w d", &["lib/a.sh"]);
    exclusive(&w, "w-a");
    let r = ids(
        &w,
        &["wave-partition", "--wave", "1"],
        "w-a\nw-b\nw-c\nw-d\n",
    );
    assert_eq!(
        (r.code, r.out.as_str()),
        (
            0,
            "group\t1\tw-a\ngroup\t3\tw-b,w-c,w-d\napart\tw-a\tw-d\tlib/a.sh\n"
        )
    );
    assert!(w
        .tele
        .borrow()
        .contains(&"serialized task=w-a wave=1 reason=exclusive".to_string()));
    w.tele.borrow_mut().clear();
    ids(&w, &["wave-partition"], "w-a\nw-b\n");
    assert!(w.tele.borrow().is_empty());
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
fn wave_partition_splits_a_wave_larger_than_cap_and_rejects_a_bad_cap() {
    let w = W::new();
    for n in 1..=6 {
        w.planned(&format!("w {n}"), &[&format!("lib/{n}.sh")]);
    }
    let input = "w-1\nw-2\nw-3\nw-4\nw-5\nw-6\n";
    assert_eq!(
        ids(&w, &["wave-partition"], input).out,
        "group\t4\tw-1,w-2,w-3,w-4\ngroup\t2\tw-5,w-6\n"
    );
    assert_eq!(
        ids(&w, &["wave-partition", "--cap", "3"], input).out,
        "group\t3\tw-1,w-2,w-3\ngroup\t3\tw-4,w-5,w-6\n"
    );
    for bad in ["0", "x", "-1"] {
        assert_eq!(
            ids(&w, &["wave-partition", "--cap", bad], input).code,
            1,
            "{bad}"
        );
    }
}

#[test]
fn wave_partition_exits_1_on_empty_input_reads_the_first_tab_field_and_counts_a_repeated_id_once() {
    let w = W::new();
    let r = ids(&w, &["wave-partition"], "");
    assert_eq!((r.code, r.out.as_str()), (1, ""));
    w.planned("w a", &["lib/a.sh"]);
    w.planned("w b", &["lib/b.sh"]);
    let r = ids(&w, &["wave-partition"], "w-a\t1\nw-b\t2\nw-a\t1\n");
    assert_eq!((r.code, r.out.as_str()), (0, "group\t2\tw-a,w-b\n"));
}

#[test]
fn wave_into_wave_partition_wave_puts_three_independent_planned_tasks_in_one_group_and_records_no_serialization(
) {
    let w = W::new();
    w.planned("w a", &["lib/a.sh"]);
    w.planned("w b", &["lib/b.sh"]);
    w.planned("w c", &["docs/c.md"]);
    w.steps_init("w-a\t1\t\tpending\nw-b\t2\t\tpending\nw-c\t3\t\tpending\n");
    let r = w.wave_wp(&["--wave", "1"]);
    assert_eq!((r.code, r.out.as_str()), (0, "group\t3\tw-a,w-b,w-c\n"));
    assert!(w.tele.borrow().is_empty());
}

#[test]
fn wave_partition_wave_records_one_serialized_event_per_shared_path_pair() {
    let w = W::new();
    w.planned("w a", &["lib/x.sh"]);
    w.planned("w b", &["lib/"]);
    let r = ids(&w, &["wave-partition", "--wave", "2"], "w-a\nw-b\n");
    assert_eq!(r.code, 0);
    assert_eq!(
        *w.tele.borrow(),
        vec!["serialized task=w-b with=w-a wave=2 reason=shared-paths paths=lib/x.sh"]
    );
}

#[test]
fn wave_partition_wave_records_a_no_plan_event_and_none_without_wave() {
    let w = W::new();
    w.planned("w a", &["lib/a.sh"]);
    w.planned("w b", &[]);
    ids(&w, &["wave-partition"], "w-a\nw-b\n");
    assert!(w.tele.borrow().is_empty());
    ids(&w, &["wave-partition", "--wave", "1"], "w-a\nw-b\n");
    assert_eq!(
        *w.tele.borrow(),
        vec!["serialized task=w-b wave=1 reason=no-plan"]
    );
}

#[test]
fn wave_leaves_a_task_with_an_unmet_dependency_out_of_the_partition() {
    let w = W::new();
    w.planned("w a", &["lib/a.sh"]);
    w.planned("w b", &["lib/b.sh"]);
    w.steps_init("w-a\t1\t\tpending\nw-b\t2\tw-a\tpending\n");
    assert_eq!(w.wave_wp(&["--wave", "1"]).out, "group\t1\tw-a\n");
}

#[test]
fn wave_partition_reads_radin_wave_cap_cap_beats_it_and_each_cap_split_task_records_a_cap_event() {
    let w = W::new();
    for n in 1..=6 {
        w.planned(&format!("w {n}"), &[&format!("lib/{n}.sh")]);
    }
    let input = "w-1\nw-2\nw-3\nw-4\nw-5\nw-6\n";
    let r = w.state_cap(&["wave-partition", "--wave", "1"], input, Some("3"));
    assert_eq!(r.out, "group\t3\tw-1,w-2,w-3\ngroup\t3\tw-4,w-5,w-6\n");
    let tele = w.tele.borrow().clone();
    assert_eq!(tele.iter().filter(|l| l.contains("reason=cap")).count(), 3);
    assert!(
        tele[0].contains("task=w-4") && tele[0].contains("cap=3"),
        "{}",
        tele[0]
    );
    let r = w.state_cap(&["wave-partition", "--cap", "2"], input, Some("3"));
    assert_eq!(
        r.out,
        "group\t2\tw-1,w-2\ngroup\t2\tw-3,w-4\ngroup\t2\tw-5,w-6\n"
    );
    assert_eq!(w.state_cap(&["wave-partition"], input, Some("0")).code, 1);
}

#[test]
fn wave_partition_rejects_a_bad_wave() {
    let w = W::new();
    w.planned("w a", &["lib/a.sh"]);
    assert_eq!(ids(&w, &["wave-partition", "--wave", "0"], "w-a\n").code, 1);
}

#[test]
fn group_set_wave_records_a_dispatched_event_without_wave_the_event_has_no_wave_key() {
    let w = W::new();
    w.state(&["group-set", "--wave", "2", "t-one", "t-two"]);
    assert_eq!(
        *w.tele.borrow(),
        vec!["dispatched ids=t-one,t-two size=2 wave=2"]
    );
    w.tele.borrow_mut().clear();
    w.state(&["group-set", "t-one"]);
    assert_eq!(*w.tele.borrow(), vec!["dispatched ids=t-one size=1"]);
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
fn plan_discard_drops_the_plan_flags_planning_needed_and_records_the_planning_tokens() {
    let w = W::new();
    w.plan_with(&["lib/a.sh"]);
    w.state(&[
        "task-report",
        "t-one",
        PLANNED,
        "--usage",
        "planning 1234 5 6",
    ]);
    let r = w.state(&["plan-discard", "t-one", "1", "lib/a.sh"]);
    assert_eq!(
        (r.code, r.out.as_str()),
        (0, "plan-discarded\tt-one\t1\t1234\n")
    );
    let meta = w.bl(&["meta", "t-one"], "").out;
    assert!(meta.contains("planning\tneeded"), "{meta}");
    assert!(!meta.contains("plan\t"), "{meta}");
    let run = w.run_id();
    assert_eq!(
        *w.tele.borrow(),
        vec![format!(
            "plan-discarded task=t-one wave=1 paths=lib/a.sh tokens=1234 run={run}"
        )]
    );
    assert!(w.state(&["task-next"]).out.contains("kind\tplanning"));
}

#[test]
fn plan_discard_deletes_the_discarded_plan_file_so_no_planner_reuses_it() {
    let w = W::new();
    w.plan_with(&["lib/a.sh"]);
    w.state(&["task-report", "t-one", PLANNED]);
    let r = w.state(&["plan-discard", "t-one", "1", "lib/a.sh"]);
    assert_eq!(r.code, 0, "{}", r.all());
    assert!(!w.exists(".radin/plans/t-one.md"), "{}", r.all());
}

#[test]
fn plan_discard_keeps_a_plan_file_outside_the_radin_plans_dir() {
    let w = W::new();
    w.write(
        "docs/t-one.md",
        "# Plan\n\n## Changes\n\n- `lib/a.sh` — x\n",
    );
    let plan = w.p.join("docs/t-one.md");
    assert_eq!(
        w.bl(&["set-meta", "t-one", "plan", plan.to_str().unwrap()], "")
            .code,
        0
    );
    w.steps_init("t-one\t1\t\tpending\n");
    w.state(&["task-report", "t-one", PLANNED]);
    let r = w.state(&["plan-discard", "t-one", "1", "lib/a.sh"]);
    assert_eq!(r.code, 0, "{}", r.all());
    assert!(w.exists("docs/t-one.md"), "{}", r.all());
}

#[test]
fn plan_discard_records_tokens_unknown_when_no_planning_usage_was_reported() {
    let w = W::new();
    w.plan_with(&["lib/a.sh"]);
    w.state(&["task-report", "t-one", PLANNED]);
    let r = w.state(&["plan-discard", "t-one", "1", "lib/a.sh"]);
    assert_eq!(
        (r.code, r.out.as_str()),
        (0, "plan-discarded\tt-one\t1\tunknown\n")
    );
    assert!(w.tele.borrow()[0].contains("tokens=unknown"));
}

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
    let r = w.state(&["plan-discard", "t-one", "1", "lib/a.sh"]);
    assert_eq!(
        (r.code, r.out.as_str()),
        (0, "plan-discarded\tt-one\t1\tunknown\n")
    );
}

#[test]
fn plan_discard_refuses_a_task_that_is_not_pending_or_has_no_plan_and_writes_nothing() {
    let w = W::new();
    w.plan_with(&["lib/a.sh"]);
    w.state(&["set-status", "t-one", "in_progress", "running"]);
    let r = w.state(&["plan-discard", "t-one", "1", "lib/a.sh"]);
    assert_eq!(r.code, 1);
    assert!(
        r.all().contains("plan-discard: t-one is not pending"),
        "{}",
        r.all()
    );
    assert!(w.tele.borrow().is_empty());
    assert!(w.bl(&["meta", "t-one"], "").out.contains("plan\t"));
    w.state(&["set-status", "t-one", "pending", ""]);
    w.bl(&["set-meta", "t-one", "plan", "--none"], "");
    let r = w.state(&["plan-discard", "t-one", "1", "lib/a.sh"]);
    assert_eq!(r.code, 1);
    assert!(
        r.all().contains("plan-discard: t-one has no plan"),
        "{}",
        r.all()
    );
    assert!(w.tele.borrow().is_empty());
}

#[test]
fn plan_discard_rejects_a_wave_that_is_not_a_positive_integer_and_an_empty_path_list() {
    let w = W::new();
    w.plan_with(&["lib/a.sh"]);
    for args in [
        ["plan-discard", "t-one", "0", "lib/a.sh"],
        ["plan-discard", "t-one", "x", "lib/a.sh"],
        ["plan-discard", "t-one", "1", ""],
    ] {
        let r = w.state(&args);
        assert_eq!(r.code, 1, "{args:?}");
        assert!(r.all().contains("plan-discard: "), "{}", r.all());
    }
    assert!(w.tele.borrow().is_empty());
}

#[test]
fn plan_discard_counts_only_planning_tokens_since_the_previous_discard() {
    let w = W::new();
    w.plan_with(&["lib/a.sh"]);
    w.state(&[
        "task-report",
        "t-one",
        PLANNED,
        "--usage",
        "planning 100 5 6",
    ]);
    w.state(&["plan-discard", "t-one", "1", "lib/a.sh"]);
    let plan = w.p.join(".radin/plans/t-one.md");
    w.bl(&["set-meta", "t-one", "plan", plan.to_str().unwrap()], "");
    w.state(&[
        "task-report",
        "t-one",
        PLANNED,
        "--usage",
        "planning 50 5 6",
        "--usage",
        "execution 9 1 1",
    ]);
    let r = w.state(&["plan-discard", "t-one", "2", "lib/a.sh"]);
    assert_eq!(
        (r.code, r.out.as_str()),
        (0, "plan-discarded\tt-one\t2\t50\n")
    );
}

fn leftover_setup(w: &W) -> std::path::PathBuf {
    w.plan_with(&["a.txt", "dir/b c.txt"]);
    w.git(&["add", ".gitignore"]);
    w.git(&["commit", "-q", "-m", "ignore"]);
    w.steps_init("t-one\t1\t\tpending\n");
    assert_eq!(w.state(&["session-set", "yes", "yes"]).code, 0);
    std::path::PathBuf::from(w.prep_dir("t-one"))
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

mod common;
use common::W;

fn id_of(line: &str) -> String {
    line.split('\t').next().unwrap().to_string()
}

#[test]
fn steps_init_rejects_a_bad_order_a_bad_status_and_empty_input_and_writes_nothing() {
    let w = W::new();
    let r = w.state_in(&["steps-init"], "t-one\tx\t\tpending\n");
    assert_eq!(
        (r.code, r.err.as_str()),
        (1, "radin-state: bad order for 't-one': x\n")
    );
    let r = w.state_in(&["steps-init"], "t-one\t\t\tpending\n");
    assert_eq!(r.err, "radin-state: bad order for 't-one': <empty>\n");
    let r = w.state_in(&["steps-init"], "t-one\t1\t\tdone\n");
    assert_eq!(
        r.err,
        "radin-state: bad status for 't-one': done (pending|deferred)\n"
    );
    assert_eq!(
        w.state_in(&["steps-init"], "").err,
        "radin-state: no entries on stdin\n"
    );
    assert!(!w.exists(".radin/state/BACKLOG_STEPS.json"));
}

#[test]
fn steps_init_takes_depends_on_from_the_index_and_writes_the_baseline_and_journal() {
    let w = W::new();
    w.bl(&["add", "fix", "t two", "--deps", "t-one"], "body\n");
    w.steps_init("t-one\t1\t\tpending\nt-two\t2\tignored\tdeferred\n");
    assert_eq!(
        w.read(".radin/state/BACKLOG_STEPS.json"),
        "{\"id\":\"t-one\",\"order\":1,\"status\":\"pending\",\"depends_on\":[],\"attempts\":0,\"debugged\":0,\"note\":\"\"}\n{\"id\":\"t-two\",\"order\":2,\"status\":\"deferred\",\"depends_on\":[\"t-one\"],\"attempts\":0,\"debugged\":0,\"note\":\"\"}\n"
    );
    assert_eq!(
        w.read(".radin/state/baseline.json"),
        format!(
            "{{\"backlog_count\":2,\"completed_count\":0,\"base_branch\":\"{}\"}}\n",
            w.base()
        )
    );
    assert!(w
        .read(".radin/state/journal.jsonl")
        .contains("\"event\":\"steps-init\",\"id\":\"\",\"detail\":\"2 entries\""));
}

#[test]
fn answered_resets_attempts_and_keeps_debugged_while_retry_clears_both() {
    let w = W::new();
    w.write(
        ".radin/state/BACKLOG_STEPS.json",
        "{\"id\":\"t-one\",\"order\":1,\"status\":\"blocked\",\"depends_on\":[],\"attempts\":3,\"debugged\":1,\"note\":\"deferred: q\"}\n",
    );
    assert_eq!(w.state(&["answered", "t-one"]).code, 0);
    assert_eq!(w.read(".radin/state/BACKLOG_STEPS.json"), "{\"id\":\"t-one\",\"order\":1,\"status\":\"pending\",\"depends_on\":[],\"attempts\":0,\"debugged\":1,\"note\":\"\"}\n");
    w.state(&["set-status", "t-one", "failed", "x"]);
    assert_eq!(w.state(&["retry", "t-one"]).code, 0);
    assert!(w
        .read(".radin/state/BACKLOG_STEPS.json")
        .contains("\"debugged\":0"));
    assert_eq!(
        w.state(&["answered", "nope"]).err,
        "radin-state: no entry with id: nope\n"
    );
}

#[test]
fn task_done_writes_the_completed_line_and_copies_facts_before_the_task_file_goes() {
    let w = W::new();
    w.plan_with(&["lib/a.sh"]);
    w.state(&["task-fact", "t-one", "STATUS: FOUND — [measured] a"]);
    w.commit_files(&["lib/a.sh"]);
    let h = w.hash.borrow().clone();
    let r = w.state(&["task-done", "t-one", &h]);
    assert_eq!(
        r.out,
        format!("task-done: t-one recorded at {h}; backlog and steps entries removed\n")
    );
    let line = w.read(".radin/state/completed.json");
    assert!(line.starts_with(&format!("{{\"id\":\"t-one\",\"commit\":\"{h}\",\"title\":\"t one\",\"branch\":\"\",\"worktree\":\"\",\"plan\":\"")), "{line}");
    assert!(
        line.contains("\"ts\":\"20") && line.contains("\"created\":\""),
        "{line}"
    );
    assert_eq!(
        w.read(".radin/state/facts/t-one.md"),
        "**Fact:** [measured] a\n"
    );
    assert_ne!(w.bl(&["find", "t-one"], "").code, 0);
    assert!(!w.read(".radin/state/BACKLOG_STEPS.json").contains("t-one"));
    let again = w.state(&["task-done", "t-one", &h]);
    assert_eq!(again.code, 0);
    assert_eq!(w.read(".radin/state/completed.json").lines().count(), 1);
    assert_eq!(w.state(&["task-done", "t-one", "zzzzzzz"]).code, 3);
}

#[test]
fn task_report_success_journals_the_summary_and_each_unproven_criterion() {
    let w = W::new();
    w.bl(
        &[
            "add",
            "fix",
            "t two",
            "--acceptance",
            "crit one",
            "--acceptance",
            "crit two",
        ],
        "body\n",
    );
    w.steps_init("t-two\t1\t\tpending\n");
    w.write(
        ".radin/backlog/tasks/t-two.md",
        &format!(
            "{}**Fact:** [measured] crit one: ran\n",
            w.read(".radin/backlog/tasks/t-two.md")
        ),
    );
    w.commit_files(&["lib/p.sh"]);
    let h = w.hash.borrow().clone();
    let r = w.state(&[
        "task-report",
        "t-two",
        &format!("STATUS: SUCCESS — {h}; built: p; chose: none"),
    ]);
    assert!(r.out.ends_with("next\tcontinue\n"), "{}", r.out);
    let j = w.read(".radin/state/journal.jsonl");
    assert!(
        j.contains("\"event\":\"summary\",\"id\":\"t-two\",\"detail\":\"built: p; chose: none\""),
        "{j}"
    );
    assert!(
        j.contains("\"event\":\"unproven\",\"id\":\"t-two\",\"detail\":\"crit two\""),
        "{j}"
    );
    assert!(!j.contains("\"detail\":\"crit one\""), "{j}");
    let rep = w.state(&["report"]).out;
    assert!(
        rep.contains("✅ Session complete: 1 succeeded, 0 failed, 0 awaiting your decision."),
        "{rep}"
    );
    assert!(
        rep.contains(&format!(
            "\nSucceeded:\n- t two — {h}\n  built: p; chose: none\n"
        )),
        "{rep}"
    );
    assert!(rep.contains("Acceptance criteria with no measured Fact line (SUCCESS recorded anyway):\n- t-two — crit two\n"), "{rep}");
}

#[test]
fn task_report_routes_a_missing_status_line_by_cause() {
    let w = W::new();
    w.clean();
    w.steps_init("t-one\t1\t\tpending\n");
    let r = w.state(&[
        "task-report",
        "t-one",
        "--no-status",
        "API error 529 overloaded",
    ]);
    assert!(r.out.contains("died on an infra error"), "{}", r.out);
    assert!(r.out.ends_with("next\tcontinue\n"));
    assert!(w
        .read(".radin/state/BACKLOG_STEPS.json")
        .contains("\"note\":\"infra error, retrying: API error 529 overloaded\""));
    let r = w.state(&["task-report", "t-one", "--no-status", "whatever"]);
    assert!(
        r.out
            .contains("⚠️ Task 1 't one': sub-agent returned no STATUS line (attempt 0 of 3)."),
        "{}",
        r.out
    );
    assert!(w
        .read(".radin/state/BACKLOG_STEPS.json")
        .contains("retrying: sub-agent returned no STATUS line; last words: whatever"));
}

#[test]
fn task_report_commits_a_dirty_tree_as_wip_whatever_the_leaf_claimed() {
    let w = W::new();
    w.steps_init("t-one\t1\t\tpending\n");
    w.write("a.txt", "draft\n");
    let r = w.state(&["task-report", "t-one", "STATUS: FAILED — boom"]);
    assert!(
        r.out
            .contains("sub-agent reported FAILED but left a dirty tree. Committed as wip "),
        "{}",
        r.out
    );
    assert!(r.out.ends_with("next\tcontinue\n"));
    assert_eq!(
        w.git(&["log", "-1", "--format=%s"]),
        "wip(t-one): unfinished work, task not complete"
    );
    assert!(w
        .read(".radin/state/BACKLOG_STEPS.json")
        .contains("\"status\":\"pending\""));
}

#[test]
fn task_report_blocked_and_inconclusive_and_unknown_lines() {
    let w = W::new();
    w.clean();
    w.steps_init("t-one\t1\t\tpending\n");
    assert_eq!(
        w.state(&[
            "task-report",
            "t-one",
            "STATUS: BLOCKED (DECISION) — which?"
        ])
        .out,
        "next\tclarify DECISION\n"
    );
    assert_eq!(
        w.state(&["task-report", "t-one", "STATUS: BLOCKED (FACT) — ?"])
            .out,
        "next\tclarify FACT\n"
    );
    let r = w.state(&["task-report", "t-one", "STATUS: INCONCLUSIVE — maybe"]);
    assert_eq!(r.out, "⚠️ Task 1 't one' inconclusive: maybe. Not counted as a pass. Kept on the backlog with a note, moving on.\nnext\tcontinue\n");
    assert_eq!(
        w.state(&["steps-waiting"]).out,
        "t-one\tinconclusive: maybe\n"
    );
    let r = w.state(&["task-report", "t-one", "no marker"]);
    assert_eq!(r.code, 1);
    assert!(
        r.err.starts_with(
            "radin-state: no SUCCESS/FAILED/INCONCLUSIVE/BLOCKED in that line: no marker"
        ),
        "{}",
        r.err
    );
    let r = w.state(&["task-report", "t-one", "SUCCESS but no hash"]);
    assert_eq!(r.out, "next\tdebug\n");
    let r = w.state(&[
        "task-report",
        "t-one",
        "STATUS: SUCCESS — built: a leaf now reports BLOCKED (DECISION) here",
    ]);
    assert!(!r.out.contains("clarify"), "{}", r.out);
}

#[test]
fn trace_answers_one_reading_and_names_an_ambiguous_one() {
    let w = W::new();
    w.plan_with(&["lib/a.sh"]);
    w.commit_files(&["lib/a.sh"]);
    let h = w.hash.borrow().clone();
    w.report_success();
    let by_id = w.state(&["trace", "t-one"]).out;
    assert!(
        by_id.starts_with(&format!("task\tt-one\ncommit\t{h}\nbranch\t\n")),
        "{by_id}"
    );
    assert!(by_id.ends_with("status\tdone\n"), "{by_id}");
    assert_eq!(w.state(&["trace", &h]).out, by_id);
    let none = w.state(&["trace", "bogus"]);
    assert_eq!(none.code, 1);
    assert!(
        none.err
            .starts_with("radin-state: \"bogus\" is not a traced task, commit or branch in "),
        "{}",
        none.err
    );
    w.write(
        ".radin/state/prepared/t-one.json",
        "{\"branch\":\"t-onebr\",\"worktree\":\"\"}\n",
    );
    w.write(
        ".radin/state/completed.json",
        &format!(
            "{}{{\"id\":\"other\",\"commit\":\"{h}aaaa\",\"branch\":\"t-one\"}}\n",
            w.read(".radin/state/completed.json")
        ),
    );
    let amb = w.state(&["trace", "t-one"]);
    assert_eq!(amb.code, 2, "{}", amb.err);
    assert!(
        amb.err.contains("is ambiguous, 2 candidate readings:"),
        "{}",
        amb.err
    );
}

#[test]
fn review_findings_validates_every_line_before_journaling_then_rolls_up() {
    let w = W::new();
    let bad = w.state_in(
        &["review-findings"],
        "t-one\tplan\tp.md\tchanges\nt-one\tplan\tp.md\tbogus\n",
    );
    assert_eq!(bad.code, 1);
    assert!(
        bad.err.contains("bad line") && bad.err.ends_with("t-one\tplan\tp.md\tbogus\n"),
        "{}",
        bad.err
    );
    assert!(!w
        .read(".radin/state/journal.jsonl")
        .contains("review-finding"));
    let ok = w.state_in(&["review-findings"], "t-one\tplan\tp.md\tchanges\nt-two\texecutor\tp.md\n\tnone\tp.md\nt-one\tplan\tp.md\ttesting\n");
    assert_eq!(ok.out, "4 findings: 2 plan (1 tasks), 1 executor (1 tasks), 1 none\n- t-one: 2 plan\n- t-two: 1 executor\n");
    assert!(w.read(".radin/state/journal.jsonl").contains(
        "\"event\":\"review-finding\",\"id\":\"t-one\",\"detail\":\"plan p.md changes\""
    ));
    let fc = w.state(&["finding-classes", "--min", "1"]).out;
    assert!(
        fc.ends_with("changes\t1\t1\ntesting\t1\t1\nrecurring (>= 1 tasks): changes, testing\n"),
        "{fc}"
    );
    assert_eq!(
        w.state(&["finding-classes"]).out.lines().last().unwrap(),
        "recurring: none"
    );
    assert_eq!(
        w.state(&["finding-classes", "--min", "x"]).err,
        "radin-state: finding-classes: --min takes a whole number\n"
    );
}

#[test]
fn gate_filed_appends_pending_entries_once_per_session_and_gate_fix_stores_short_hashes() {
    let w = W::new();
    w.steps_init("t-one\t1\t\tpending\n");
    w.bl(&["add", "fix", "t two"], "body\n");
    assert_eq!(w.state(&["gate-filed", "t-two"]).code, 0);
    assert!(w.read(".radin/state/BACKLOG_STEPS.json").ends_with("{\"id\":\"t-two\",\"order\":2,\"status\":\"pending\",\"depends_on\":[],\"attempts\":0,\"debugged\":0,\"note\":\"\"}\n"));
    assert_eq!(
        w.state(&["gate-filed", "t-two"]).err,
        "radin-state: the gate's review round is already used\n"
    );
    assert_eq!(
        w.state(&["gate-fix", "zzz"]).err,
        "radin-state: not a commit: zzz\n"
    );
    assert_eq!(w.state(&["gate-fix", "HEAD", "HEAD"]).code, 0);
    let head = w.git(&["rev-parse", "--short=12", "HEAD"]);
    assert_eq!(w.state(&["session-commits"]).out, format!("{head}\n"));
}

#[test]
fn recover_sends_a_clean_task_back_to_pending_and_wip_commits_a_dirty_one() {
    let w = W::new();
    w.steps_init("t-one\t1\t\tpending\n");
    w.state(&["set-status", "t-one", "in_progress", "x"]);
    assert_eq!(
        w.state(&["recover", "t-one"])
            .out
            .lines()
            .next()
            .map(id_of)
            .as_deref(),
        Some("recovered")
    );
    assert!(w
        .read(".radin/state/BACKLOG_STEPS.json")
        .contains("\"status\":\"pending\""));
    w.write("a.txt", "x\n");
    let r = w.state(&["recover", "t-one"]);
    assert!(r.out.contains("committed wip "), "{}", r.out);
    assert_eq!(
        w.git(&["log", "-1", "--format=%s"]),
        "wip(t-one): unfinished work, task not complete"
    );
    assert_eq!(
        w.state(&["recover-reject", "t-one"])
            .out
            .lines()
            .next()
            .unwrap()
            .split('\t')
            .next(),
        Some("blocked")
    );
}

#[test]
fn an_id_verb_prints_its_usage_for_help_and_rejects_a_flag_as_its_id_without_a_branch() {
    let w = W::new();
    w.state(&["session-set", "no", "yes"]);
    let help = w.state(&["prepare", "--help"]);
    assert_eq!(help.code, 0, "{}", help.all());
    assert!(help.out.contains("prepare <id>"), "{}", help.all());
    let bad = w.state(&["prepare", "--bogus"]);
    assert_ne!(bad.code, 0, "{}", bad.all());
    assert!(bad.err.contains("prepare <id>"), "{}", bad.all());
    assert_eq!(w.git(&["branch", "--list", "radin/--*"]), "");
}

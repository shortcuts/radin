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
        "radin-state: bad status for 't-one': done (pending|excluded)\n"
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
    w.steps_init("t-one\t1\t\tpending\nt-two\t2\tignored\texcluded\n");
    assert_eq!(
        w.read(".radin/state/BACKLOG_STEPS.json"),
        "{\"id\":\"t-one\",\"order\":1,\"status\":\"pending\",\"reason\":\"\",\"depends_on\":[],\"attempts\":0,\"debugged\":0,\"note\":\"\"}\n{\"id\":\"t-two\",\"order\":2,\"status\":\"excluded\",\"reason\":\"\",\"depends_on\":[\"t-one\"],\"attempts\":0,\"debugged\":0,\"note\":\"\"}\n"
    );
    assert_eq!(
        w.read(".radin/state/baseline.json"),
        format!(
            "{{\"backlog_count\":2,\"completed_count\":0,\"base_branch\":\"{}\",\"run_id\":\"{}\"}}\n",
            w.base(),
            w.run_id()
        )
    );
    assert!(w
        .read(".radin/state/journal.jsonl")
        .contains("\"event\":\"steps-init\",\"id\":\"\",\"detail\":\"2 entries\""));
    w.write(".radin/state/gate-done", "");
    w.write(".radin/state/teardown", "");
    w.steps_init("t-one\t1\t\tpending\n");
    w.state(&["preflight"]);
    let j = w.read(".radin/state/journal.jsonl");
    for d in ["gate-done", "teardown"] {
        assert!(
            j.contains(&format!(
                "\"event\":\"marker-clear\",\"id\":\"\",\"detail\":\"{d}\""
            )),
            "{d} in {j}"
        );
    }
}

#[test]
fn answered_resets_attempts_and_keeps_debugged_while_retry_clears_both() {
    let w = W::new();
    w.write(
        ".radin/state/BACKLOG_STEPS.json",
        "{\"id\":\"t-one\",\"order\":1,\"status\":\"blocked\",\"reason\":\"deferred\",\"depends_on\":[],\"attempts\":3,\"debugged\":1,\"note\":\"q\"}\n",
    );
    assert_eq!(w.state(&["answered", "t-one"]).code, 0);
    assert_eq!(w.read(".radin/state/BACKLOG_STEPS.json"), "{\"id\":\"t-one\",\"order\":1,\"status\":\"pending\",\"reason\":\"\",\"depends_on\":[],\"attempts\":0,\"debugged\":1,\"note\":\"\"}\n");
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
    assert_eq!(
        w.state_in(&["base-failing", "t-one", "--set"], "t::red\n")
            .code,
        0
    );
    assert!(w.p.join(".radin/state/base-failing/t-one.txt").exists());
    let h = w.hash.borrow().clone();
    let r = w.state(&["task-done", "t-one", &h]);
    assert_eq!(
        r.out,
        format!("task-done: t-one recorded at {h}; backlog and steps entries removed\n")
    );
    assert!(!w.p.join(".radin/state/base-failing/t-one.txt").exists());
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
        &format!("STATUS: SUCCESS — {h}; built: p; chose: none; checks: test=pass, lint=pass, review=pass"),
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
        rep.contains("✅ Session complete: 1 succeeded, 0 landed with a follow-up, 0 failed, 0 awaiting your decision."),
        "{rep}"
    );
    assert!(!rep.contains("Landed, follow-up filed:"), "{rep}");
    assert!(
        rep.contains(&format!(
            "\nSucceeded:\n- t two — {h}\n  built: p; chose: none\n"
        )),
        "{rep}"
    );
    assert!(rep.contains("Acceptance criteria with no measured Fact line (SUCCESS recorded anyway):\n- t-two — crit two\n"), "{rep}");
}

#[test]
fn report_brief_drops_the_succeeded_list_and_keeps_the_rest() {
    let w = W::new();
    w.clean();
    w.steps_init("t-one\t1\t\tpending\nt-two\t2\t\tpending\n");
    let fid = w
        .bl(&["add", "fix", "Finish: t two"], "body\n")
        .out
        .trim()
        .to_string();
    w.write(
        ".radin/state/completed.json",
        "{\"id\":\"t-one\",\"commit\":\"aaaa1111\",\"title\":\"t one\"}\n{\"id\":\"t-two\",\"commit\":\"bbbb2222\",\"title\":\"t two\"}\n",
    );
    let j = w.read(".radin/state/journal.jsonl");
    w.write(
        ".radin/state/journal.jsonl",
        &format!("{j}{{\"ts\":\"20260101T000000Z\",\"event\":\"follow-up\",\"id\":\"t-two\",\"detail\":\"{fid}\"}}\n"),
    );
    let rep = w.state(&["report", "--brief"]).out;
    assert!(
        rep.contains("✅ Session complete: 1 succeeded, 1 landed with a follow-up, 0 failed, 0 awaiting your decision."),
        "{rep}"
    );
    assert!(!rep.contains("Succeeded:"), "{rep}");
    assert!(
        rep.contains("\nLanded, follow-up filed:\n- t two — bbbb2222"),
        "{rep}"
    );
}

#[test]
fn report_lists_a_task_that_landed_with_a_follow_up_apart_from_succeeded() {
    let w = W::new();
    w.clean();
    w.steps_init("t-one\t1\t\tpending\nt-two\t2\t\tpending\n");
    let fid = w
        .bl(&["add", "fix", "Finish: t two"], "body\n")
        .out
        .trim()
        .to_string();
    w.write(
        ".radin/state/completed.json",
        "{\"id\":\"t-one\",\"commit\":\"aaaa1111\",\"title\":\"t one\"}\n{\"id\":\"t-two\",\"commit\":\"bbbb2222\",\"title\":\"t two\"}\n",
    );
    let j = w.read(".radin/state/journal.jsonl");
    w.write(
        ".radin/state/journal.jsonl",
        &format!("{j}{{\"ts\":\"20260101T000000Z\",\"event\":\"follow-up\",\"id\":\"t-two\",\"detail\":\"{fid}\"}}\n"),
    );
    let rep = w.state(&["report"]).out;
    assert!(
        rep.contains("✅ Session complete: 1 succeeded, 1 landed with a follow-up, 0 failed, 0 awaiting your decision."),
        "{rep}"
    );
    assert!(rep.contains("\nSucceeded:\n- t one — aaaa1111\n"), "{rep}");
    assert!(!rep.contains("- t two — bbbb2222\n"), "{rep}");
    assert!(
        rep.contains(&format!(
            "\nLanded, follow-up filed:\n- t two — bbbb2222 on the base. Follow-up: {fid} (Finish: t two)\n"
        )),
        "{rep}"
    );
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
fn task_report_refuses_next_in_wave_mode_and_records_nothing() {
    let w = W::new();
    w.clean();
    w.steps_init("t-one\t1\t\tpending\n");
    w.state(&["session-set", "yes", "yes"]);
    let r = w.state(&["task-report", "t-one", "STATUS: FAILED — boom", "--next"]);
    assert_eq!(r.code, 1, "{}", r.out);
    assert!(
        r.err.contains("--next is refused in wave mode"),
        "{}",
        r.err
    );
    assert_eq!(r.out, "");
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
        "t-one\tinconclusive\tinconclusive: maybe\n"
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
    let r = w.state(&[
        "task-report",
        "t-one",
        "SUCCESS but no hash; checks: test=pass, lint=pass, review=pass",
    ]);
    assert_eq!(
        r.out,
        "⚠️ Task 1 't one' failed: reported SUCCESS with no commit hash in the line. Its one debug pass is next.\nnext\tdebug\n"
    );
    let r = w.state(&[
        "task-report",
        "t-one",
        "STATUS: SUCCESS — built: a leaf now reports BLOCKED (DECISION) here; checks: test=pass, lint=pass, review=pass",
    ]);
    assert!(!r.out.contains("clarify"), "{}", r.out);
}

#[test]
fn task_report_refuses_a_different_failure_line_while_the_debug_pass_is_pending() {
    let w = W::new();
    w.clean();
    w.steps_init("t-one\t1\t\tpending\n");
    let first = w.state(&[
        "task-report",
        "t-one",
        "STATUS: FAILED — real reason; open: x",
    ]);
    assert!(
        first.out.contains("failed: real reason; open: x."),
        "{}",
        first.out
    );
    assert!(first.out.ends_with("next\tdebug\n"));
    let second = w.state(&["task-report", "t-one", "STATUS: FAILED — short"]);
    assert_eq!(second.code, 1, "{}", second.out);
    assert!(second.err.contains("already reported"), "{}", second.err);
    assert!(!w
        .read(".radin/state/BACKLOG_STEPS.json")
        .contains("\"failed\""));
    let same = w.state(&[
        "task-report",
        "t-one",
        "STATUS: FAILED — real reason; open: x",
    ]);
    assert!(same.out.contains("Kept on the backlog"), "{}", same.out);
}

#[test]
fn task_report_records_a_new_failure_line_once_the_debug_prompt_was_dispatched() {
    let w = W::new();
    w.clean();
    w.steps_init("t-one\t1\t\tpending\n");
    w.state(&["task-report", "t-one", "STATUS: FAILED — first reason"]);
    w.write(".radin/state/prompts/t-one-debug.md", "prompt\n");
    let second = w.state(&["task-report", "t-one", "STATUS: FAILED — new reason"]);
    assert_eq!(second.code, 0, "{}", second.err);
    assert!(second.out.contains("failed: new reason."), "{}", second.out);
    assert!(w
        .read(".radin/state/BACKLOG_STEPS.json")
        .contains("\"failed\""));
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
    assert!(w.read(".radin/state/BACKLOG_STEPS.json").ends_with("{\"id\":\"t-two\",\"order\":2,\"status\":\"pending\",\"reason\":\"\",\"depends_on\":[],\"attempts\":0,\"debugged\":0,\"note\":\"\"}\n"));
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

#[test]
fn task_report_deferred_planned_line_warns_nothing_and_sets_no_meta() {
    let w = W::new();
    w.clean();
    w.steps_init("t-one\t1\t\tpending\n");
    let before = w.bl(&["meta", "t-one"], "").out;
    let r = w.state(&[
        "task-report",
        "t-one",
        "STATUS: PLANNED — deferred: shares a.rs with t-two",
    ]);
    assert_eq!(
        (r.code, r.out.as_str(), r.err.as_str()),
        (0, "task-report: deferred t-one\nnext\tcontinue\n", "")
    );
    assert_eq!(w.bl(&["meta", "t-one"], "").out, before);
}

const ALL_PASS: &str = "checks: test=pass, lint=pass, review=pass";

#[test]
fn task_report_success_without_a_passing_check_is_inconclusive_and_names_the_check() {
    let w = W::new();
    w.plan_with(&["lib/a.sh"]);
    w.commit_files(&["lib/a.sh"]);
    let h = w.hash.borrow().clone();
    let report = |tail: &str| {
        w.state(&[
            "task-report",
            "t-one",
            &format!("STATUS: SUCCESS — {h}; built: p{tail}"),
        ])
    };
    let r = report("");
    assert!(
        r.out
            .contains("inconclusive: reported SUCCESS without a passing check: test, lint, review"),
        "{}",
        r.out
    );
    assert!(r.out.ends_with("next\tcontinue\n"), "{}", r.out);
    assert!(!w.exists(".radin/state/completed.json"));
    assert_eq!(
        w.state(&["steps-waiting"]).out,
        "t-one\tinconclusive\tinconclusive: reported SUCCESS without a passing check: test, lint, review\n"
    );
    let r = report("; checks: test=pass, lint=pass, review=skipped");
    assert!(r.out.contains("passing check: review. "), "{}", r.out);
    let r = report("; checks: test=na, lint=na, review=na");
    assert!(r.out.contains("passing check: review. "), "{}", r.out);
    let r = report("; checks: test=na, lint=na, review=pass");
    assert!(
        r.out.ends_with("next\tcontinue\n") && !r.out.contains("inconclusive"),
        "{}",
        r.out
    );
    assert_eq!(w.read(".radin/state/completed.json").lines().count(), 1);
    let j = w.read(".radin/state/journal.jsonl");
    assert!(j.contains("\"detail\":\"built: p\"}"), "{j}");
    assert!(!j.contains(ALL_PASS) && !j.contains("test=na"), "{j}");
}

#[test]
fn task_report_planned_needs_plan_review_unless_no_plan_was_written() {
    let w = W::new();
    w.plan_with(&["lib/a.sh"]);
    w.clean();
    let r = w.state(&[
        "task-report",
        "t-one",
        "STATUS: PLANNED — p.md; complexity low: x",
    ]);
    assert!(
        r.out
            .contains("inconclusive: reported PLANNED without a passing check: plan-review"),
        "{}",
        r.out
    );
    assert!(!w.bl(&["meta", "t-one"], "").out.contains("complexity"));
    let r = w.state(&[
        "task-report",
        "t-one",
        "STATUS: PLANNED — none needed: tiny; complexity low: x",
    ]);
    assert_eq!(r.out, "task-report: planned t-one\nnext\tcontinue\n");
    let meta = w.bl(&["meta", "t-one"], "").out;
    assert!(meta.contains("complexity\tlow"), "{meta}");
}

#[test]
fn journal_completed_and_telemetry_carry_the_run_dispatch_and_wave() {
    let w = W::new();
    w.bl(&["set-meta", "t-one", "complexity", "low"], "");
    w.bl(&["set-meta", "t-one", "acceptance", "crit a"], "");
    w.plan_with(&["lib/a.sh"]);
    w.commit_files(&["lib/a.sh"]);
    let h = w.hash.borrow().clone();
    let run = w.run_id();
    assert!(run.starts_with('r') && run.contains('-'), "{run}");
    let j = w.read(".radin/state/journal.jsonl");
    assert!(
        j.contains(&format!("\"run\":\"{run}\",\"event\":\"steps-init\"")),
        "{j}"
    );
    w.state(&["task-next"]);
    w.state(&["group-set", "--wave", "2", "t-one"]);
    assert_eq!(
        *w.tele.borrow().last().unwrap(),
        format!("dispatched ids=t-one size=1 wave=2 run={run}")
    );
    w.state(&["task-report", "t-one", "STATUS: FAILED — boom"]);
    w.state(&[
        "task-report",
        "t-one",
        "STATUS: FAILED — boom",
        "--usage",
        "debug 7 1 1",
    ]);
    let j = w.read(".radin/state/journal.jsonl");
    let has = |s: &str| j.contains(s);
    assert!(has(&format!("\"run\":\"{run}\",\"from\":\"pending\",\"dispatch\":1,\"kind\":\"execution\",\"event\":\"in_progress\",\"id\":\"t-one\"")), "{j}");
    assert!(has(&format!("\"run\":\"{run}\",\"wave\":\"2\",\"event\":\"group\",\"id\":\"\",\"detail\":\"ids=t-one; wave=2\"")), "{j}");
    assert!(
        has(&format!(
            "\"run\":\"{run}\",\"dispatch\":2,\"kind\":\"debug\",\"event\":\"debug\""
        )),
        "{j}"
    );
    assert!(has(&format!("\"run\":\"{run}\",\"dispatch\":2,\"kind\":\"debug\",\"event\":\"usage\",\"id\":\"t-one\",\"detail\":\"debug 7 1 1\"")), "{j}");
    assert!(has(&format!("\"run\":\"{run}\",\"from\":\"in_progress\",\"dispatch\":2,\"kind\":\"debug\",\"wave\":\"2\",\"event\":\"failed\"")), "{j}");
    assert_eq!(j.matches("\"event\":\"in_progress\"").count(), 1, "{j}");
    w.state(&["answered", "t-one"]);
    w.state(&["task-next"]);
    let j = w.read(".radin/state/journal.jsonl");
    assert!(
        j.contains("\"dispatch\":3,\"kind\":\"execution\",\"event\":\"in_progress\""),
        "{j}"
    );
    assert_eq!(w.state(&["task-done", "t-one", &h]).code, 0);
    let line = w.read(".radin/state/completed.json");
    let tail = format!("\"run\":\"{run}\",\"attempts\":1,\"debugged\":1,\"claimed\":\"20");
    assert!(line.contains(&tail), "{line}");
    assert!(
        line.ends_with("\",\"category\":\"fix\",\"priority\":\"\",\"epic\":\"\",\"complexity\":\"low\",\"acceptance\":\"crit a\"}\n"),
        "{line}"
    );
}

#[test]
fn a_blocked_report_is_stored_as_a_waiting_entry_and_answered_returns_it_to_pending() {
    let w = W::new();
    w.clean();
    w.steps_init("t-one\t1\t\tpending\n");
    w.state(&["set-status", "t-one", "in_progress"]);
    w.state(&[
        "task-report",
        "t-one",
        "STATUS: BLOCKED (DECISION) — which?",
    ]);
    assert_eq!(w.state(&["steps-waiting"]).out, "t-one\tdecision\twhich?\n");
    let pre = w.state(&["preflight"]).out;
    assert!(pre.contains("waiting\tt-one\tdecision\twhich?\n"), "{pre}");
    assert!(!pre.contains("stuck"), "{pre}");
    w.state(&["answered", "t-one"]);
    assert!(w
        .read(".radin/state/BACKLOG_STEPS.json")
        .contains("\"status\":\"pending\",\"reason\":\"\""));
}

#[test]
fn a_dependency_block_logs_one_event_and_lifts_when_the_dependency_lands() {
    let w = W::new();
    w.bl(&["add", "fix", "t two"], "body\n");
    w.steps_init("t-one\t1\t\tpending\nt-two\t2\tt-one\tpending\n");
    let events = |w: &W| {
        w.read(".radin/state/journal.jsonl")
            .matches("\"event\":\"blocked\",\"id\":\"t-two\"")
            .count()
    };
    w.state(&["task-next", "t-two"]);
    w.state(&["task-next", "t-two"]);
    assert_eq!(events(&w), 1);
    assert!(w
        .read(".radin/state/BACKLOG_STEPS.json")
        .contains("\"status\":\"blocked\",\"reason\":\"dependency\""));
    assert_eq!(w.state(&["resume"]).out, "");
    w.write(
        ".radin/state/completed.json",
        "{\"id\":\"t-one\",\"commit\":\"abc123def456\"}\n",
    );
    assert!(w.state(&["wave"]).out.contains("t-two\t2\n"));
    assert_eq!(events(&w), 1);
}

#[test]
fn the_dependency_gate_reads_the_backlog_deps_set_after_steps_init() {
    let w = W::new();
    w.bl(&["add", "fix", "t two"], "body\n");
    w.steps_init("t-one\t1\t\tpending\nt-two\t2\t\tpending\n");
    assert_eq!(w.state(&["deps-check", "t-two"]).code, 0);
    w.bl(&["set-deps", "t-two", "t-one"], "");
    let r = w.state(&["deps-check", "t-two"]);
    assert_eq!(
        (r.code, r.err.as_str()),
        (
            1,
            "radin-state: task 't-two' waiting on dependency 't-one', which is pending\n"
        )
    );
}

#[test]
fn set_status_reason_takes_only_deferred_with_blocked_and_task_fact_journals() {
    let w = W::new();
    w.steps_init("t-one\t1\t\tpending\n");
    w.state(&[
        "set-status",
        "t-one",
        "blocked",
        "--reason",
        "deferred",
        "which db?",
    ]);
    assert_eq!(
        w.state(&["steps-waiting"]).out,
        "t-one\tdeferred\twhich db?\n"
    );
    for bad in [
        ["pending", "--reason", "deferred"],
        ["blocked", "--reason", "fact"],
    ] {
        let r = w.state(&["set-status", "t-one", bad[0], bad[1], bad[2], "x"]);
        assert_eq!(r.code, 1, "{bad:?}");
    }
    w.state(&["task-fact", "t-one", "STATUS: FOUND — [measured] a is 1"]);
    assert!(w
        .read(".radin/state/journal.jsonl")
        .contains("\"event\":\"fact\",\"id\":\"t-one\",\"detail\":\"[measured] a is 1\""));
}

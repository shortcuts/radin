#[path = "tui_pty/harness.rs"]
#[allow(dead_code)]
mod harness;
#[path = "common/stubs.rs"]
mod stubs;

use harness::Term;
use regex::Regex;
use stubs::Sandbox;

fn term(s: &Sandbox, args: &[&str]) -> Term {
    let path = format!("{}:/usr/bin:/bin", s.bin.display());
    let (log, bin) = (s.home.display().to_string(), s.bin.display().to_string());
    let mut all = vec!["install", "--dry-run"];
    all.extend(args);
    Term::spawn_args(
        &s.work,
        (100, 40),
        &[
            ("PATH", &path),
            ("MOCK_LOG_DIR", &log),
            ("MOCK_BIN", &bin),
            ("RADIN_DETAILS", "1"),
        ],
        &all,
    )
}

fn screen_text(t: &mut Term) -> String {
    let esc = Regex::new(r"\x1b\[[0-9;?]*[A-Za-z]").unwrap();
    esc.replace_all(&t.raw(), "").replace('\r', "")
}

fn codex_box() -> Sandbox {
    let s = Sandbox::new();
    s.add("codex");
    s
}

#[test]
fn the_wizard_walks_hosts_models_and_package_manager_then_prints_the_review_box_and_installs() {
    let s = codex_box();
    let mut t = term(&s, &[]);
    t.wait_for("Install radin for");
    t.keys("\r");
    t.keys("\r");
    t.keys("\r");
    assert_eq!(t.exit_code(), 0);
    let o = screen_text(&mut t);
    for want in [
        "Step 1/3  Hosts > Models > Package manager",
        "> [x] Claude Code",
        "[ ] Codex CLI",
        "┌─ Review ",
        "Hosts            Claude Code ",
        "[1/6] Installing radin",
    ] {
        assert!(o.contains(want), "{want}\n{o}");
    }
}

#[test]
fn left_returns_to_the_previous_step_and_keeps_its_answer() {
    let s = codex_box();
    let mut t = term(&s, &[]);
    t.wait_for("Install radin for");
    t.keys("\r");
    t.keys("\x1b[D");
    t.keys("j");
    t.keys(" ");
    t.keys("\r");
    t.keys("\r");
    t.keys("\r");
    assert_eq!(t.exit_code(), 0);
    let o = screen_text(&mut t);
    assert!(o.matches("Step 1/3").count() >= 2, "{o}");
    assert!(o.contains("Hosts            Claude Code, Codex CLI"), "{o}");
}

#[test]
fn unticking_every_host_is_refused_and_the_list_stays() {
    let s = codex_box();
    let mut t = term(&s, &[]);
    t.wait_for("Install radin for");
    t.keys(" ");
    t.keys("\r");
    t.wait_for("pick at least one host");
    t.keys(" ");
    t.keys("\r");
    t.keys("\r");
    t.keys("\r");
    assert_eq!(t.exit_code(), 0);
    let o = screen_text(&mut t);
    assert!(
        o.contains("pick at least one host") && o.contains("Hosts            Claude Code "),
        "{o}"
    );
}

#[test]
fn arrow_keys_move_the_selection_and_enter_confirms_it() {
    let s = Sandbox::new();
    let mut t = term(&s, &["--only", "claude"]);
    t.wait_for("Choose radin-batch's sub-agent models?");
    t.keys("\x1b[A\r");
    t.wait_for("planning, execution, review and debug sub-agents");
    t.keys("\x1b[B\r");
    t.wait_for("fact-finding sub-agents");
    t.keys("\r");
    t.keys("\r");
    assert_eq!(t.exit_code(), 0);
    let o = screen_text(&mut t);
    assert!(
        o.contains("Models           haiku: planning, execution, review, debug"),
        "{o}"
    );
}

#[test]
fn ctrl_c_in_the_picker_aborts_with_status_130_and_installs_nothing() {
    let s = Sandbox::new();
    let mut t = term(&s, &["--only", "claude"]);
    t.wait_for("Choose radin-batch's sub-agent models?");
    t.keys("\x03");
    assert_eq!(t.exit_code(), 130);
    let o = screen_text(&mut t);
    assert!(o.contains("aborted."), "{o}");
    assert!(!o.contains("partial install"));
    assert!(s.tree().is_empty());
}

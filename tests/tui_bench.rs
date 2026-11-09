#[path = "tui_pty/harness.rs"]
#[allow(dead_code)] // the bench uses a few of the harness methods
mod harness;

use harness::Term;
use std::fs;

#[test]
#[ignore = "timing is machine dependent; run through `make bench-tui`"]
fn key_to_frame_latency() {
    let t = tempfile::tempdir().unwrap();
    let root = t.path().canonicalize().unwrap();
    let proj = root.join("proj");
    fs::create_dir_all(&proj).unwrap();
    let env = |k: &str| (k == "HOME").then(|| "/nonexistent".to_string());
    for i in 1..=42 {
        let args = [
            "backlog",
            "add",
            "feat",
            &format!("task {i} with a title long enough to wrap inside the list pane"),
        ]
        .map(String::from);
        let (code, _, err) = radin::run_in(&args, &env, false, &proj, Some("body\n"));
        assert_eq!(code, 0, "{err}");
    }
    let mut term = Term::spawn(&proj, (200, 50), &[]);
    term.wait_for("radin backlog");
    term.quiet();
    let mut ms: Vec<f64> = (0..20).map(|_| term.time_to_frame("j")).collect();
    ms.sort_by(|a, b| a.partial_cmp(b).unwrap());
    println!(
        "42 tasks, 20 keys: key-to-frame median {:.1}ms max {:.1}ms",
        ms[ms.len() / 2],
        ms[ms.len() - 1]
    );
}

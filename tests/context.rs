#[path = "common/cli.rs"]
mod cli;
mod common;

fn run(args: &[&str]) -> cli::Run {
    let t = tempfile::tempdir().unwrap();
    cli::radin(t.path(), t.path(), args)
}

#[test]
fn context_reports_every_host_and_passes_its_own_ceiling() {
    let r = run(&["context", "--check"]);
    assert_eq!(r.code, 0, "{}{}", r.out, r.err);
    for h in ["claude", "agents"] {
        assert!(
            r.out.contains(&format!("== {h}: always loaded")),
            "{}",
            r.out
        );
        assert!(r.out.contains(&format!("== {h}: routes")), "{}", r.out);
    }
    // /radin-stats carries disable-model-invocation, so only the Claude render skips it
    let always = |h: &str| {
        let from = r.out.find(&format!("== {h}: always loaded")).unwrap();
        r.out[from..].split("\n\n").next().unwrap().to_string()
    };
    assert!(
        !always("claude").contains("radin-stats"),
        "{}",
        always("claude")
    );
    assert!(
        always("agents").contains("radin-stats"),
        "{}",
        always("agents")
    );
    assert!(r.out.contains("radin-batch"), "{}", r.out);
    // radin-run.md is the biggest file and three skills name it
    assert!(
        r.out.contains("== claude: lib files")
            && r.out
                .lines()
                .any(|l| l.starts_with("radin-run.md") && l.ends_with("3 of 8")),
        "{}",
        r.out
    );
}

#[test]
fn context_rejects_an_unknown_flag() {
    let r = run(&["context", "--nope"]);
    assert_eq!(r.code, 1);
    assert!(r.err.contains("usage: radin context"), "{}", r.err);
}

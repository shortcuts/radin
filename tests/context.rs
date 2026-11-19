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
                .any(|l| l.starts_with("radin-run.md") && l.ends_with("3 of 9")),
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

fn write(root: &std::path::Path, rel: &str, body: &str) {
    let p = root.join(rel);
    std::fs::create_dir_all(p.parent().unwrap()).unwrap();
    std::fs::write(p, body).unwrap();
}

#[test]
fn repo_lists_every_file_a_session_loads_with_its_imports() {
    let t = tempfile::tempdir().unwrap();
    let (repo, home) = (t.path().join("repo"), t.path().join("home"));
    write(&repo, "CLAUDE.md", "@AGENTS.md\nSee `@not-an-import.md`.\n");
    write(&repo, "AGENTS.md", &"rule\n".repeat(100));
    write(&repo, ".claude/rules/style.md", "style\n");
    write(
        &repo,
        ".claude/skills/audit/SKILL.md",
        "---\nname: audit\ndescription: Use for audits.\n---\nBODY BODY BODY\n",
    );
    write(
        &repo,
        ".claude/skills/quiet/SKILL.md",
        "---\nname: quiet\ndescription: Hidden.\ndisable-model-invocation: true\n---\nx\n",
    );
    write(&home, ".claude/CLAUDE.md", "@RTK.md\n");
    write(&home, ".claude/RTK.md", "user rule\n");
    let r = cli::radin(&repo, &home, &["context", "--repo"]);
    assert_eq!(r.code, 0, "{}{}", r.out, r.err);
    let row = |name: &str| {
        r.out
            .lines()
            .find(|l| l.starts_with(name))
            .map(String::from)
    };
    assert!(row("CLAUDE.md").unwrap().contains("project"), "{}", r.out);
    assert!(
        row("AGENTS.md").unwrap().contains("via CLAUDE.md"),
        "{}",
        r.out
    );
    assert!(row(".claude/rules/style.md").is_some(), "{}", r.out);
    assert!(row("skill audit").is_some(), "{}", r.out);
    assert!(
        row("skill quiet").is_none(),
        "a non-model-invoked skill is not listed"
    );
    assert!(row("not-an-import.md").is_none(), "{}", r.out);
    assert!(
        row("~/.claude/CLAUDE.md").unwrap().contains("user"),
        "{}",
        r.out
    );
    assert!(
        row("~/.claude/RTK.md").unwrap().contains("via CLAUDE.md"),
        "{}",
        r.out
    );
    // the skill's listing costs its name and description, never its body
    let audit = row("skill audit").unwrap();
    assert!(!audit.contains("BODY"), "{audit}");
    assert!(
        !r.out.contains("always loaded"),
        "--repo prints no radin table:\n{}",
        r.out
    );
}

#[test]
fn repo_rejects_check() {
    let r = run(&["context", "--repo", "--check"]);
    assert_eq!(r.code, 1);
}

#[test]
fn repo_under_home_counts_the_user_config_once_as_user() {
    let t = tempfile::tempdir().unwrap();
    let (home, repo) = (t.path().join("home"), t.path().join("home/work/repo"));
    let skill = "---\nname: s\ndescription: Use it.\n---\nbody\n";
    write(&home, ".claude/CLAUDE.md", "user rule\n");
    write(&home, ".claude/skills/s/SKILL.md", skill);
    write(&home, "AGENTS.md", "home rule\n");
    write(&repo, "CLAUDE.md", "x\n");
    std::fs::create_dir_all(home.join(".agents")).unwrap();
    std::os::unix::fs::symlink(home.join(".claude/skills"), home.join(".agents/skills")).unwrap();
    let r = cli::radin(&repo, &home, &["context", "--repo"]);
    assert_eq!(r.code, 0, "{}{}", r.out, r.err);
    let rows: Vec<&str> = r
        .out
        .lines()
        .filter(|l| l.contains("CLAUDE.md") || l.starts_with("skill"))
        .collect();
    assert_eq!(
        rows.iter().filter(|l| l.starts_with("skill s")).count(),
        1,
        "{}",
        r.out
    );
    assert!(
        rows.iter()
            .any(|l| l.starts_with("~/.claude/CLAUDE.md") && l.contains("user")),
        "{}",
        r.out
    );
    assert!(
        !rows.iter().any(|l| l.contains("project")
            && l.contains(".claude/CLAUDE.md")
            && l.contains("home")),
        "{}",
        r.out
    );
    assert!(
        r.out
            .lines()
            .any(|l| l.contains("AGENTS.md") && l.contains("project")),
        "{}",
        r.out
    );
}

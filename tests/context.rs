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

#[test]
fn repo_reports_a_subtotal_per_scope() {
    let t = tempfile::tempdir().unwrap();
    let (repo, home) = (t.path().join("repo"), t.path().join("home"));
    write(&repo, "AGENTS.md", &"p\n".repeat(40));
    write(&home, ".claude/CLAUDE.md", &"u\n".repeat(40));
    let r = cli::radin(&repo, &home, &["context", "--repo"]);
    for l in ["total project", "total user", "total  "] {
        assert!(r.out.lines().any(|x| x.starts_with(l)), "{l}:\n{}", r.out);
    }
}

#[test]
fn refs_names_only_the_references_the_repo_contradicts() {
    let t = tempfile::tempdir().unwrap();
    let (repo, home) = (t.path().join("repo"), t.path().join("home"));
    write(&repo, "src/ok.rs", "");
    write(&repo, "docs/a.md", "# Real heading\n");
    write(&repo, "Makefile", ".PHONY: build\nbuild:\n\techo\n");
    write(
        &repo,
        "AGENTS.md",
        "Edit `src/ok.rs`, `src/gone.rs:12`, run `make build` and `make nope`.\n\
         See [a](docs/a.md#real-heading), [b](docs/a.md#no-such), [c](docs/zzz.md).\n\
         Skip `~/.claude/x`, `lib/<host>.txt`, `src/*.rs`, `https://x.io/a/b` and `a/b c`.\n\
         ```\n`fenced/gone.rs`\n```\n",
    );
    let r = cli::radin(&repo, &home, &["context", "--refs"]);
    assert_eq!(r.code, 0, "{}{}", r.out, r.err);
    for bad in [
        "src/gone.rs",
        "make nope",
        "docs/a.md#no-such",
        "docs/zzz.md",
    ] {
        assert!(r.out.contains(bad), "{bad}:\n{}", r.out);
    }
    for ok in [
        "src/ok.rs",
        "make build",
        "real-heading",
        "~/.claude",
        "fenced",
        "<host>",
        "https",
    ] {
        assert!(!r.out.contains(ok), "{ok}:\n{}", r.out);
    }
    assert!(r.out.contains("AGENTS.md:1"), "{}", r.out);
}

#[test]
fn signals_flag_dated_text_and_repeated_lines_with_their_commit() {
    let t = tempfile::tempdir().unwrap();
    let (repo, home) = (t.path().join("repo"), t.path().join("home"));
    let dup = "Keep every test under a second so the suite stays fast for everyone.";
    write(
        &repo,
        "AGENTS.md",
        &format!(
            "You MUST run it. Never skip. Try to be brief if possible.\n{dup}\nThink step by step.\nUse claude-3 here. Set `ALWAYS_CEILING`.\n"
        ),
    );
    write(&repo, ".claude/rules/t.md", &format!("- **{dup}**\n"));
    cli::git(&repo, &["init", "-q"]);
    cli::git(&repo, &["add", "-A"]);
    cli::git(&repo, &["commit", "-qm", "x"]);
    let sha = cli::git(&repo, &["rev-parse", "--short=7", "HEAD"]);
    let r = cli::radin(&repo, &home, &["context", "--signals"]);
    assert_eq!(r.code, 0, "{}{}", r.out, r.err);
    for id in ["P1", "P2", "P3", "P10"] {
        assert!(r.out.lines().any(|l| l.contains(id)), "{id}:\n{}", r.out);
    }
    assert!(r.out.contains(sha.trim()), "blame column:\n{}", r.out);
    let p1 = r
        .out
        .lines()
        .filter(|l| l.split_whitespace().nth(1) == Some("P1"))
        .count();
    assert_eq!(p1, 1, "lowercase never is not pressure:\n{}", r.out);
    assert!(
        r.out.contains("AGENTS.md:2") && r.out.contains(".claude/rules/t.md:1"),
        "duplicate names both sides:\n{}",
        r.out
    );
}

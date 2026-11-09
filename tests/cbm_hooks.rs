#[path = "common/cli.rs"]
mod cli;
mod common;

use std::fs;
use std::path::PathBuf;

struct W {
    _t: tempfile::TempDir,
    home: PathBuf,
    bin: PathBuf,
    proj: PathBuf,
}

fn w() -> W {
    let t = tempfile::tempdir().unwrap();
    let home = t.path().canonicalize().unwrap();
    let bin = home.join("mockbin");
    fs::create_dir_all(&bin).unwrap();
    cli::stub(&bin, "codebase-memory-mcp", "");
    let proj = home.join("proj");
    fs::create_dir_all(&proj).unwrap();
    cli::git(&proj, &["init", "-q"]);
    W {
        _t: t,
        home,
        bin,
        proj,
    }
}

impl W {
    fn run(&self, args: &[&str]) -> cli::Run {
        let path = format!("{}:/usr/bin:/bin:/usr/sbin:/sbin", self.bin.display());
        let mut a = vec!["hooks"];
        a.extend_from_slice(args);
        cli::radin_with(&self.home, &self.home, &a, "", &[("PATH", &path)])
    }
    fn mcp_json(&self) -> PathBuf {
        self.proj.join(".mcp.json")
    }
    fn repo(&self) -> String {
        self.proj.to_string_lossy().into_owned()
    }
}

#[test]
fn fails_without_the_binary_on_path_or_in_local_bin() {
    let t = w();
    fs::remove_file(t.bin.join("codebase-memory-mcp")).unwrap();
    let r = t.run(&["all", &t.repo()]);
    assert_eq!(r.code, 1);
    assert_eq!(
        r.err,
        "radin-cbm-hooks: codebase-memory-mcp not found on PATH or in ~/.local/bin -- run radin's install.sh first\n"
    );
}

#[test]
fn unknown_verb_prints_usage_exit_1() {
    let r = w().run(&["bogus"]);
    assert_eq!(r.code, 1);
    assert_eq!(
        r.err,
        "radin-cbm-hooks: usage: radin hooks <claude-md|mcp [repo-root]|all [repo-root]>\n"
    );
}

#[test]
fn falls_back_to_local_bin_when_off_path() {
    let t = w();
    fs::remove_file(t.bin.join("codebase-memory-mcp")).unwrap();
    let lb = t.home.join(".local/bin");
    fs::create_dir_all(&lb).unwrap();
    cli::stub(&lb, "codebase-memory-mcp", "");
    let r = t.run(&["mcp", &t.repo()]);
    assert_eq!(r.code, 0);
    let want = format!("{}/codebase-memory-mcp", lb.display());
    assert!(fs::read_to_string(t.mcp_json()).unwrap().contains(&want));
}

#[test]
fn claude_md_appends_once_preserving_content() {
    let t = w();
    let md = t.home.join(".claude/CLAUDE.md");
    fs::create_dir_all(md.parent().unwrap()).unwrap();
    fs::write(&md, "user content stays\n").unwrap();
    let r = t.run(&["claude-md"]);
    assert_eq!(
        (r.code, r.out.as_str()),
        (
            0,
            format!("ADDED    {} (codebase-memory-mcp section)\n", md.display()).as_str()
        )
    );
    let r = t.run(&["claude-md"]);
    assert_eq!(
        r.out,
        format!("PRESENT  {} (codebase-memory-mcp section)\n", md.display())
    );
    let text = fs::read_to_string(&md).unwrap();
    assert!(text.starts_with("user content stays\n\n<!-- codebase-memory-mcp MCP tools -->\n## MCP Tools: codebase-memory-mcp\n"));
    assert!(text.ends_with("parameters and use.\n"));
    assert_eq!(text.matches("## MCP Tools: codebase-memory-mcp").count(), 1);
}

#[test]
fn claude_md_skips_a_user_authored_section() {
    let t = w();
    let md = t.home.join(".claude/CLAUDE.md");
    fs::create_dir_all(md.parent().unwrap()).unwrap();
    fs::write(&md, "## MCP Tools: codebase-memory-mcp\n").unwrap();
    let r = t.run(&["claude-md"]);
    assert_eq!(r.code, 0);
    assert!(r.out.starts_with("PRESENT  "));
    assert_eq!(
        fs::read_to_string(&md).unwrap(),
        "## MCP Tools: codebase-memory-mcp\n"
    );
}

#[test]
fn mcp_adds_the_entry_once_and_keeps_other_servers() {
    let t = w();
    fs::write(
        t.mcp_json(),
        r#"{"mcpServers": {"other": {"command": "x"}}}"#,
    )
    .unwrap();
    let r = t.run(&["mcp", &t.repo()]);
    assert_eq!(r.code, 0);
    assert!(r.out.starts_with("ADDED"));
    let j = fs::read_to_string(t.mcp_json()).unwrap();
    assert!(j.contains("\"other\"") && j.contains("\"codebase-memory-mcp\""));
    assert!(t.run(&["mcp", &t.repo()]).out.starts_with("PRESENT"));
}

#[test]
fn mcp_never_redefines_a_users_own_entry() {
    let t = w();
    fs::write(
        t.mcp_json(),
        r#"{"mcpServers": {"codebase-memory-mcp": {"command": "custom-wrapper"}}}"#,
    )
    .unwrap();
    let r = t.run(&["mcp", &t.repo()]);
    assert_eq!(r.code, 0);
    assert!(r.out.starts_with("PRESENT"));
    assert!(fs::read_to_string(t.mcp_json())
        .unwrap()
        .contains("custom-wrapper"));
}

#[test]
fn mcp_refuses_invalid_json_and_leaves_it_alone() {
    let t = w();
    fs::write(t.mcp_json(), "not json").unwrap();
    let r = t.run(&["mcp", &t.repo()]);
    assert_eq!(r.code, 1);
    assert!(r.err.contains(&format!("{}", t.mcp_json().display())));
    assert_eq!(fs::read_to_string(t.mcp_json()).unwrap(), "not json");
}

#[test]
fn mcp_creates_the_file_and_a_rerun_is_a_no_op() {
    let t = w();
    let r = t.run(&["mcp", &t.repo()]);
    assert_eq!(r.code, 0);
    assert!(r.out.starts_with("ADDED"));
    let first = fs::read(t.mcp_json()).unwrap();
    let r = t.run(&["mcp", &t.repo()]);
    assert_eq!(r.code, 0);
    assert!(r.out.starts_with("PRESENT"));
    assert_eq!(fs::read(t.mcp_json()).unwrap(), first);
}

#[test]
fn mcp_keeps_other_keys_and_their_order() {
    let t = w();
    fs::write(
        t.mcp_json(),
        "{\n  \"zebra\": 1,\n  \"alpha\": {\"deep\": [1, 2]}\n}\n",
    )
    .unwrap();
    assert_eq!(t.run(&["mcp", &t.repo()]).code, 0);
    let j = fs::read_to_string(t.mcp_json()).unwrap();
    let at = |k: &str| j.find(k).unwrap();
    assert!(at("\"zebra\"") < at("\"alpha\"") && at("\"alpha\"") < at("\"mcpServers\""));
}

#[test]
fn mcp_without_a_repo_arg_uses_the_git_toplevel_of_the_cwd() {
    let t = w();
    let path = format!("{}:/usr/bin:/bin", t.bin.display());
    let r = cli::radin_with(&t.proj, &t.home, &["hooks", "mcp"], "", &[("PATH", &path)]);
    assert_eq!(r.code, 0);
    assert!(t.mcp_json().is_file());
    let r = t.run(&["mcp"]);
    assert_eq!(r.code, 1);
    assert_eq!(
        r.err,
        "radin-cbm-hooks: mcp: not inside a git repo and no repo-root given\n"
    );
}

#[test]
fn all_runs_both_writes_against_a_fresh_home_and_repo() {
    let t = w();
    let r = t.run(&["all", &t.repo()]);
    assert_eq!(r.code, 0);
    assert!(fs::read_to_string(t.home.join(".claude/CLAUDE.md"))
        .unwrap()
        .contains("## MCP Tools: codebase-memory-mcp"));
    assert!(fs::read_to_string(t.mcp_json())
        .unwrap()
        .contains("\"codebase-memory-mcp\""));
    assert!(!t.home.join(".claude/settings.json").exists());
}

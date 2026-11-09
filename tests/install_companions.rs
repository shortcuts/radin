#[path = "common/stubs.rs"]
mod stubs;

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use stubs::{sha, Sandbox, R};

const KINDS: [&str; 7] = [
    "planning",
    "execution",
    "review",
    "debug",
    "factfind",
    "gate",
    "merge",
];

fn with(clis: &[&str]) -> Sandbox {
    let s = Sandbox::new();
    for c in clis {
        s.add(c);
    }
    s
}

fn run(s: &Sandbox, args: &[&str], env: &[(&str, &str)]) -> R {
    let mut all = vec!["install", "--yes"];
    all.extend(args);
    s.run_env(&all, "", env)
}

fn lines(s: &Sandbox, name: &str) -> Vec<String> {
    s.log(name).lines().map(String::from).collect()
}

fn has_line(s: &Sandbox, name: &str, want: &str) -> bool {
    lines(s, name).iter().any(|l| l == want)
}

fn forbidden_words() -> Vec<String> {
    let t = fs::read_to_string(Path::new(env!("CARGO_MANIFEST_DIR")).join("lib/forbid-agents.txt"))
        .unwrap();
    t.lines()
        .filter(|w| !w.is_empty() && !w.starts_with('#') && !w.starts_with("skills/"))
        .map(String::from)
        .collect()
}

fn assert_neutral_block(md: &str) {
    let block: String = md
        .lines()
        .skip_while(|l| *l != "<!-- radin:begin -->")
        .take_while(|l| *l != "<!-- radin:end -->")
        .collect::<Vec<_>>()
        .join("\n");
    assert!(!block.is_empty());
    for w in forbidden_words() {
        assert!(!block.contains(&w), "{w}");
    }
}

fn agents_rows() -> Vec<String> {
    let t =
        fs::read_to_string(Path::new(env!("CARGO_MANIFEST_DIR")).join("lib/companion-skills.txt"))
            .unwrap();
    t.lines()
        .filter(|l| !l.starts_with('#') && !l.trim().is_empty())
        .map(|l| l.split_whitespace().next().unwrap().to_string())
        .collect()
}

fn agents_skills(s: &Sandbox) -> Vec<String> {
    s.manifest()["agents_skills"]
        .as_array()
        .unwrap()
        .iter()
        .map(|v| v.as_str().unwrap().to_string())
        .collect()
}

#[test]
fn codex_runs_the_four_companion_steps_and_prints_the_hooks_trust_step() {
    let s = with(&["codex", "rtk", "codebase-memory-mcp"]);
    let r = run(&s, &["--only", "codex"], &[]);
    assert_eq!(r.code, 0, "{}", r.all());
    assert!(has_line(
        &s,
        "codex",
        "plugin marketplace add DietrichGebert/ponytail"
    ));
    assert!(has_line(&s, "codex", "plugin add ponytail@ponytail"));
    assert!(has_line(&s, "rtk", "init -g --codex"));
    assert!(has_line(
        &s,
        "codebase-memory-mcp",
        "install -y --clients=codex"
    ));
    assert!(s.log("curl").contains("caveman/main/install.sh"));
    assert!(r.all().contains("open /hooks and trust the new hooks"));
}

#[test]
fn codex_agents_block_is_neutral_written_once_and_keeps_foreign_content() {
    let s = with(&["codex", "rtk", "codebase-memory-mcp"]);
    s.put(
        ".codex/AGENTS.md",
        "user text\n<!-- rtk:begin -->\nrtk block\n<!-- rtk:end -->\n",
    );
    run(&s, &["--only", "codex"], &[]);
    let r = run(&s, &["--only", "codex"], &[]);
    assert_eq!(r.code, 0, "{}", r.all());
    let md = s.read(".codex/AGENTS.md");
    assert_eq!(md.matches("<!-- radin:begin -->").count(), 1);
    assert_eq!(md.matches("<!-- radin:end -->").count(), 1);
    assert!(md.contains("user text") && md.contains("rtk block"));
    assert!(md.contains("`radin-record` skill") && md.contains("--host agents backlog show"));
    assert_neutral_block(&md);
    assert_eq!(s.manifest()["codex_guidance"], true);
}

#[test]
fn a_failing_codex_companion_warns_exits_zero_and_still_writes_the_block() {
    let s = with(&["codex", "rtk", "codebase-memory-mcp"]);
    let r = run(&s, &["--only", "codex"], &[("MOCK_FAIL", "codex")]);
    assert_eq!(r.code, 0, "{}", r.all());
    assert!(r.all().contains("ponytail-codex install failed"));
    assert!(s.read(".codex/AGENTS.md").contains("radin:begin"));
    let r = run(
        &s,
        &["--only", "codex", "--refresh"],
        &[("MOCK_CURL_FAIL", "caveman")],
    );
    assert_eq!(r.code, 0);
    assert!(r.all().contains("caveman-codex install failed"));
    assert!(has_line(&s, "rtk", "init -g --codex"));
}

#[test]
fn a_missing_codex_cli_skips_the_steps_warns_and_still_writes_the_block() {
    let s = with(&["rtk", "codebase-memory-mcp"]);
    let r = run(&s, &["--only", "codex"], &[]);
    assert_eq!(r.code, 0, "{}", r.all());
    assert!(r.all().contains("codex CLI not found"));
    assert!(s.log("codex").is_empty());
    assert!(!lines(&s, "rtk").contains(&"init -g --codex".to_string()));
    assert!(!r.all().contains("open /hooks"));
    assert!(s.read(".codex/AGENTS.md").contains("radin:begin"));
}

#[test]
fn codex_hooks_json_is_backed_up_and_config_and_roles_stay_untouched() {
    let s = with(&["codex", "rtk", "codebase-memory-mcp"]);
    s.put(".codex/hooks.json", "{\"hooks\":1}\n");
    s.put(".codex/config.toml", "model = \"x\"\n");
    s.put(".codex/agents/r.toml", "role\n");
    let before: Vec<String> = [
        ".codex/hooks.json",
        ".codex/config.toml",
        ".codex/agents/r.toml",
    ]
    .iter()
    .map(|f| sha(&s.p(f)))
    .collect();
    let r = run(&s, &["--only", "codex"], &[]);
    assert_eq!(r.code, 0, "{}", r.all());
    let bak = fs::read_dir(s.p(".radin/backups"))
        .unwrap()
        .flatten()
        .find(|e| e.file_name().to_string_lossy().starts_with("hooks.json."))
        .expect("hooks.json backup");
    assert_eq!(fs::read_to_string(bak.path()).unwrap(), "{\"hooks\":1}\n");
    let after: Vec<String> = [
        ".codex/hooks.json",
        ".codex/config.toml",
        ".codex/agents/r.toml",
    ]
    .iter()
    .map(|f| sha(&s.p(f)))
    .collect();
    assert_eq!(before, after);
}

#[test]
fn codex_dry_run_lists_write_and_run_lines_and_creates_nothing() {
    let s = with(&["codex", "rtk", "codebase-memory-mcp"]);
    let r = run(&s, &["--dry-run", "--only", "codex"], &[]);
    assert_eq!(r.code, 0, "{}", r.all());
    assert!(!s.p(".codex").exists() && s.log("codex").is_empty());
    let o = &r.out;
    assert!(o.contains(&format!("write {}", s.p(".codex/AGENTS.md").display())));
    assert!(o.contains("run codex plugin marketplace add DietrichGebert/ponytail && codex plugin add ponytail@ponytail"));
    assert!(o.contains("run rtk init -g --codex"));
    assert!(o.contains("--only codex --non-interactive") && o.contains("--clients=codex"));
}

#[test]
fn only_claude_leaves_codex_and_opencode_alone() {
    let s = with(&["codex", "opencode", "rtk", "codebase-memory-mcp"]);
    let r = run(&s, &["--only", "claude"], &[]);
    assert_eq!(r.code, 0, "{}", r.all());
    assert!(!s.p(".codex").exists() && !s.p(".config").exists());
    assert!(s.log("codex").is_empty() && s.log("opencode").is_empty());
    let m = s.manifest();
    assert_eq!(m["codex_guidance"], false);
    assert_eq!(m["opencode_guidance"], false);
    let md = s.read(".claude/CLAUDE.md");
    assert!(md.contains("`/radin-record`") && md.contains("invoke `/mattpocock-skills:grilling`"));
    assert_eq!(md.matches("<!-- radin:begin -->").count(), 1);
}

#[test]
fn opencode_writes_seven_agent_files_and_runs_the_four_companion_steps() {
    let s = with(&["opencode", "rtk", "codebase-memory-mcp"]);
    let r = run(&s, &["--only", "opencode"], &[]);
    assert_eq!(r.code, 0, "{}", r.all());
    for k in KINDS {
        let f = s.read(&format!(".config/opencode/agents/radin-{k}.md"));
        assert!(f.lines().any(|l| l == "mode: subagent"), "{k}");
        assert!(
            f.lines().any(|l| l == "  question: deny") && f.lines().any(|l| l == "  task: deny")
        );
        assert_eq!(
            f.lines()
                .filter(|l| l.starts_with("description: radin leaf"))
                .count(),
            1
        );
        assert!(!f
            .lines()
            .any(|l| l.starts_with("model") || l.starts_with("tools")));
        assert!(!f.contains("RADIN_AGENT_") && f.contains(&format!("radin {k} leaf")));
    }
    assert!(has_line(
        &s,
        "opencode",
        "plugin add @dietrichgebert/ponytail"
    ));
    assert!(has_line(&s, "rtk", "init -g --opencode"));
    assert!(has_line(
        &s,
        "codebase-memory-mcp",
        "install -y --clients=opencode"
    ));
    assert!(s.log("curl").contains("caveman/main/install.sh"));
}

#[test]
fn the_opencode_allow_rule_lands_once_keeps_foreign_keys_and_leaves_a_backup() {
    let s = with(&["opencode", "rtk", "codebase-memory-mcp"]);
    s.put(
        ".config/opencode/opencode.json",
        "{\"plugin\":[\"a\"],\"mcp\":{\"x\":{}}}\n",
    );
    run(&s, &["--only", "opencode"], &[]);
    let once = fs::read(s.p(".config/opencode/opencode.json")).unwrap();
    let r = run(&s, &["--only", "opencode"], &[]);
    assert_eq!(r.code, 0, "{}", r.all());
    assert_eq!(
        once,
        fs::read(s.p(".config/opencode/opencode.json")).unwrap()
    );
    let j = s.read(".config/opencode/opencode.json");
    assert!(
        j.contains(&format!("\"{}/.radin/**\": \"allow\"", s.home.display())),
        "{j}"
    );
    assert!(j.contains("\"plugin\"") && j.contains("\"mcp\""));
    let any_original = fs::read_dir(s.p(".radin/backups"))
        .unwrap()
        .flatten()
        .filter(|e| {
            e.file_name()
                .to_string_lossy()
                .starts_with("opencode.json.")
        })
        .any(|e| {
            fs::read_to_string(e.path())
                .unwrap()
                .starts_with("{\"plugin\":[\"a\"]")
        });
    assert!(any_original);
}

#[test]
fn a_jsonc_config_or_a_string_external_directory_stays_byte_identical_and_the_rule_is_printed() {
    let s = with(&["opencode", "rtk", "codebase-memory-mcp"]);
    s.put(
        ".config/opencode/opencode.jsonc",
        "{\n  // mine\n  \"plugin\": []\n}\n",
    );
    let r = run(&s, &["--only", "opencode"], &[]);
    assert_eq!(r.code, 0, "{}", r.all());
    assert!(!s.p(".config/opencode/opencode.json").exists());
    assert!(
        r.all().contains(&format!(
            "{{\"permission\":{{\"external_directory\":{{\"{}/.radin/**\":\"allow\"",
            s.home.display()
        )),
        "{}",
        r.all()
    );
    s.put(
        ".config/opencode/opencode.json",
        "{\"permission\":{\"external_directory\":\"ask\"}}\n",
    );
    let r = run(&s, &["--only", "opencode"], &[]);
    assert_eq!(r.code, 0);
    assert_eq!(
        s.read(".config/opencode/opencode.json"),
        "{\"permission\":{\"external_directory\":\"ask\"}}\n"
    );
    assert!(r.all().contains("\"external_directory\":{"));
    assert!(s.p(".config/opencode/agents/radin-merge.md").is_file());
}

#[test]
fn opencode_config_takes_the_rule_only_and_xdg_unset_falls_back_to_dot_config() {
    let s = with(&["opencode", "rtk", "codebase-memory-mcp"]);
    s.put("custom.json", "{}\n");
    let c = s.p("custom.json");
    let x = s.p("xdg");
    let r = run(
        &s,
        &["--only", "opencode"],
        &[
            ("OPENCODE_CONFIG", c.to_str().unwrap()),
            ("XDG_CONFIG_HOME", x.to_str().unwrap()),
        ],
    );
    assert_eq!(r.code, 0, "{}", r.all());
    assert!(s.read("custom.json").contains("\"allow\""));
    assert!(!s.p("xdg/opencode/opencode.json").exists());
    assert!(s.p("xdg/opencode/agents/radin-gate.md").is_file());
    let r = run(&s, &["--only", "opencode"], &[("XDG_CONFIG_HOME", "")]);
    assert_eq!(r.code, 0, "{}", r.all());
    assert!(s.p(".config/opencode/agents/radin-gate.md").is_file());
    assert!(s
        .read(".config/opencode/opencode.json")
        .contains("\"allow\""));
}

#[test]
fn the_opencode_agents_block_is_neutral_and_the_manifest_records_the_config() {
    let s = with(&["opencode", "rtk", "codebase-memory-mcp"]);
    s.put(".config/opencode/AGENTS.md", "user text\n");
    run(&s, &["--only", "opencode"], &[]);
    let r = run(&s, &["--only", "opencode"], &[]);
    assert_eq!(r.code, 0);
    let md = s.read(".config/opencode/AGENTS.md");
    assert_eq!(md.matches("<!-- radin:begin -->").count(), 1);
    assert!(md.contains("user text") && md.contains("--host agents backlog show"));
    assert_neutral_block(&md);
    let m = s.manifest();
    assert_eq!(m["opencode_guidance"], true);
    assert_eq!(
        m["opencode_allow"],
        s.p(".config/opencode/opencode.json").to_str().unwrap()
    );
}

#[test]
fn a_failing_opencode_companion_warns_exits_zero_and_still_writes_the_files() {
    let s = with(&["opencode", "rtk", "codebase-memory-mcp"]);
    let r = run(&s, &["--only", "opencode"], &[("MOCK_FAIL", "opencode")]);
    assert_eq!(r.code, 0, "{}", r.all());
    assert!(r.all().contains("ponytail-opencode install failed"));
    assert!(s.p(".config/opencode/agents/radin-planning.md").is_file());
    assert!(s.read(".config/opencode/AGENTS.md").contains("radin:begin"));
    let r = run(
        &s,
        &["--only", "opencode", "--refresh"],
        &[("MOCK_CURL_FAIL", "caveman")],
    );
    assert!(r.all().contains("caveman-opencode install failed"));
    assert!(has_line(&s, "rtk", "init -g --opencode"));
}

#[test]
fn a_missing_opencode_cli_skips_the_steps_and_still_writes_files_and_the_rule() {
    let s = with(&["rtk", "codebase-memory-mcp"]);
    let r = run(&s, &["--only", "opencode"], &[]);
    assert_eq!(r.code, 0, "{}", r.all());
    assert!(r.all().contains("opencode CLI not found"));
    assert!(s.log("opencode").is_empty());
    assert!(!lines(&s, "rtk").contains(&"init -g --opencode".to_string()));
    assert!(s.p(".config/opencode/agents/radin-debug.md").is_file());
    assert!(s.read(".config/opencode/AGENTS.md").contains("radin:begin"));
    assert!(s
        .read(".config/opencode/opencode.json")
        .contains("\"allow\""));
}

#[test]
fn an_edited_or_foreign_agent_file_is_kept_and_force_backs_it_up_and_replaces_it() {
    let s = with(&["opencode", "rtk", "codebase-memory-mcp"]);
    run(&s, &["--only", "opencode"], &[]);
    let dir = ".config/opencode/agents";
    s.put(&format!("{dir}/radin-planning.md"), "mine\n");
    fs::remove_file(s.p(&format!("{dir}/radin-gate.md"))).unwrap();
    s.put(&format!("{dir}/radin-gate.md"), "foreign\n");
    let r = run(&s, &["--only", "opencode"], &[]);
    assert_eq!(r.code, 0, "{}", r.all());
    for k in ["planning", "gate"] {
        assert!(
            r.all().contains(&format!(
                "kept {}",
                s.p(&format!("{dir}/radin-{k}.md")).display()
            )),
            "{k}"
        );
    }
    assert_eq!(s.read(&format!("{dir}/radin-planning.md")), "mine\n");
    let r = run(&s, &["--only", "opencode", "--force"], &[]);
    assert_eq!(r.code, 0, "{}", r.all());
    for k in ["planning", "gate"] {
        assert!(s
            .read(&format!("{dir}/radin-{k}.md"))
            .lines()
            .any(|l| l == "mode: subagent"));
    }
    let backups: Vec<_> = fs::read_dir(s.p(".radin/backups"))
        .unwrap()
        .flatten()
        .collect();
    assert!(!backups.is_empty());
}

#[test]
fn opencode_dry_run_lists_the_writes_and_runs_and_creates_nothing() {
    let s = with(&["opencode", "rtk", "codebase-memory-mcp"]);
    let r = run(&s, &["--dry-run", "--only", "opencode"], &[]);
    assert_eq!(r.code, 0, "{}", r.all());
    assert!(!s.p(".config").exists() && s.log("opencode").is_empty());
    for k in KINDS {
        assert!(r.out.contains(&format!(
            "write {}",
            s.p(&format!(".config/opencode/agents/radin-{k}.md"))
                .display()
        )));
    }
    assert!(r.out.contains(&format!(
        "write {}",
        s.p(".config/opencode/AGENTS.md").display()
    )));
    assert!(r.out.contains(&format!(
        "write {}",
        s.p(".config/opencode/opencode.json").display()
    )));
    assert!(r
        .out
        .contains("run opencode plugin add @dietrichgebert/ponytail"));
    assert!(
        r.out.contains("run rtk init -g --opencode")
            && r.out.contains("--only opencode --non-interactive")
    );
    assert!(r.out.contains("--clients=opencode"));
}

#[test]
fn doctor_passes_on_a_fresh_only_opencode_install() {
    let s = with(&["opencode", "rtk", "codebase-memory-mcp"]);
    let r = run(&s, &["--only", "opencode"], &[]);
    assert_eq!(r.code, 0, "{}", r.all());
    fs::remove_file(s.bin.join("opencode")).unwrap();
    fs::write(s.bin.join("opencode"), "#!/bin/sh\necho opencode v2.2.5\n").unwrap();
    fs::set_permissions(s.bin.join("opencode"), fs::Permissions::from_mode(0o755)).unwrap();
    let d = s.run_env(&["doctor"], "", &[]);
    assert_eq!(d.code, 0, "{}", d.all());
    assert!(d.out.contains("OK       opencode 2.2.5"), "{}", d.out);
    assert!(d.out.contains("OK       external_directory rule"));
    assert!(d.out.contains("file(s) match their recorded digest"));
}

#[test]
fn a_claude_only_install_fetches_no_agents_companion_skill() {
    let s = Sandbox::new();
    assert_eq!(run(&s, &[], &[]).code, 0);
    assert!(!s.p(".agents").exists());
    assert!(agents_skills(&s).is_empty());
}

#[test]
fn a_failed_companion_skill_download_warns_exits_zero_and_lets_the_other_rows_land() {
    let s = with(&["codex", "rtk", "codebase-memory-mcp"]);
    let r = run(
        &s,
        &["--only", "codex"],
        &[("MOCK_CURL_FAIL", "/lean-build/")],
    );
    assert_eq!(r.code, 0, "{}", r.all());
    assert!(r.all().contains("lean-build download failed"));
    assert!(!s.p(".agents/skills/lean-build").exists());
    assert!(s.p(".agents/skills/safe-refactor/SKILL.md").is_file());
    assert!(!agents_skills(&s).contains(&"lean-build".to_string()));
    assert_eq!(agents_skills(&s).len(), agents_rows().len() - 1);
}

#[test]
fn update_refetches_an_owned_skill_keeps_one_on_a_failed_refetch_and_leaves_a_foreign_one() {
    let s = with(&["codex", "rtk", "codebase-memory-mcp"]);
    assert_eq!(run(&s, &["--only", "codex"], &[]).code, 0);
    assert_eq!(agents_skills(&s).len(), agents_rows().len());
    s.put(".agents/skills/ponytail/SKILL.md", "stale\n");
    s.put(".agents/skills/lean-build/SKILL.md", "kept\n");
    let r = run(&s, &["--update"], &[("MOCK_CURL_FAIL", "/lean-build/")]);
    assert_eq!(r.code, 0, "{}", r.all());
    assert!(s
        .read(".agents/skills/ponytail/SKILL.md")
        .lines()
        .any(|l| l == "name: ponytail"));
    assert_eq!(s.read(".agents/skills/lean-build/SKILL.md"), "kept\n");
    assert_eq!(agents_skills(&s).len(), agents_rows().len());
    let mut m: serde_json::Value = s.manifest();
    m["agents_skills"]
        .as_array_mut()
        .unwrap()
        .retain(|v| v != "lean-build");
    s.put(
        ".radin/manifest.json",
        &serde_json::to_string_pretty(&m).unwrap(),
    );
    let r = run(&s, &["--update"], &[]);
    assert_eq!(r.code, 0, "{}", r.all());
    assert_eq!(s.read(".agents/skills/lean-build/SKILL.md"), "kept\n");
    assert!(
        r.all().contains("lean-build skipped")
            || !agents_skills(&s).contains(&"lean-build".to_string())
    );
}

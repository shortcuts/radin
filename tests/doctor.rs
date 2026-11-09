#[path = "common/cli.rs"]
mod cli;
mod common;

use sha2::{Digest, Sha256};
use std::fs;
use std::os::unix::fs::symlink;
use std::path::{Path, PathBuf};

struct W {
    _t: tempfile::TempDir,
    home: PathBuf,
    bin: PathBuf,
    work: PathBuf,
}

fn w() -> W {
    let t = tempfile::tempdir().unwrap();
    let home = t.path().canonicalize().unwrap().join("home");
    let bin = t.path().canonicalize().unwrap().join("mockbin");
    let work = t.path().canonicalize().unwrap().join("work");
    for d in [&home, &bin, &work] {
        fs::create_dir_all(d).unwrap();
    }
    W {
        _t: t,
        home,
        bin,
        work,
    }
}

fn put(p: &Path, text: &str) {
    fs::create_dir_all(p.parent().unwrap()).unwrap();
    fs::write(p, text).unwrap();
}

fn digest(p: &Path) -> String {
    format!("{:x}", Sha256::digest(fs::read(p).unwrap()))
}

impl W {
    fn p(&self, rel: &str) -> PathBuf {
        self.home.join(rel)
    }

    fn doctor(&self) -> cli::Run {
        let path = format!("{}:/usr/bin:/bin", self.bin.display());
        cli::radin_with(&self.work, &self.home, &["doctor"], "", &[("PATH", &path)])
    }

    fn mock(&self, name: &str, body: &str) {
        cli::stub(&self.bin, name, body);
    }

    fn install_all_expected(&self) {
        let s = radin::shipped::shipped();
        put(&self.p(".radin/bin/radin"), "#!/bin/sh\n");
        for n in s.skills.iter().chain(&["thermo-nuclear"]) {
            put(&self.p(&format!(".claude/skills/{n}/SKILL.md")), "");
        }
        for n in &s.lib {
            put(&self.p(&format!(".radin/lib/{n}")), "");
        }
        for n in &s.hostlib {
            put(&self.p(&format!(".radin/hosts/claude/lib/{n}")), "");
        }
    }

    fn companions(&self) {
        let lib = Path::new(env!("CARGO_MANIFEST_DIR")).join("lib");
        for f in ["companion-skills.txt", "skill-names-agents.txt"] {
            fs::copy(lib.join(f), self.p(&format!(".radin/lib/{f}"))).unwrap();
        }
    }

    fn companion_names(&self) -> Vec<String> {
        fs::read_to_string(self.p(".radin/lib/companion-skills.txt"))
            .unwrap()
            .lines()
            .filter(|l| !l.starts_with('#'))
            .filter_map(|l| l.split_whitespace().next().map(str::to_string))
            .collect()
    }

    fn agents_setup(&self, clis: &str) {
        self.install_all_expected();
        self.companions();
        self.manifest(&format!("\"agents_clis\": [{clis}]"));
        for n in self.companion_names() {
            put(&self.p(&format!(".agents/skills/{n}/SKILL.md")), "");
        }
    }

    fn manifest(&self, body: &str) {
        put(
            &self.p(".radin/manifest.json"),
            &format!("{{\n  {body}\n}}\n"),
        );
    }

    fn write_manifest(&self, hosts: &str, clis: &str) {
        self.manifest(&format!(
            "\"opencode_allow\": \"\",\n  \"hosts\": [{hosts}],\n  \"agents_clis\": [{clis}]"
        ));
    }

    fn hosts_setup(&self, hosts: &str, clis: &str) {
        self.install_all_expected();
        self.companions();
        let lib = Path::new(env!("CARGO_MANIFEST_DIR")).join("lib");
        for f in ["forbid-claude.txt", "forbid-agents.txt"] {
            fs::copy(lib.join(f), self.p(&format!(".radin/lib/{f}"))).unwrap();
        }
        let s = radin::shipped::shipped();
        for n in &s.hostlib {
            put(&self.p(&format!(".radin/hosts/agents/lib/{n}")), "");
        }
        for n in s
            .skills
            .iter()
            .map(|s| s.to_string())
            .chain(self.companion_names())
        {
            put(&self.p(&format!(".agents/skills/{n}/SKILL.md")), "");
        }
        let block = "<!-- radin:begin -->\nx\n<!-- radin:end -->\n";
        put(&self.p(".codex/AGENTS.md"), block);
        put(&self.p(".config/opencode/AGENTS.md"), block);
        put(
            &self.p(".config/opencode/agents/radin-planning.md"),
            "---\ndescription: d\nmode: subagent\n---\nbody\n",
        );
        put(
            &self.p(".config/opencode/opencode.json"),
            &format!(
                "{{\"permission\":{{\"external_directory\":{{\"{}/.radin/**\":\"allow\"}}}}}}\n",
                self.home.display()
            ),
        );
        self.write_manifest(hosts, clis);
    }
}

#[test]
fn absent_hostlib_file_is_missing() {
    let w = w();
    w.install_all_expected();
    fs::remove_file(w.p(".radin/hosts/claude/lib/radin-batch-recovery.md")).unwrap();
    let r = w.doctor();
    assert_eq!(r.code, 1, "{}", r.out);
    assert!(r.out.contains("  MISSING  radin-batch-recovery.md\n"));
    assert!(r.out.contains("1 check(s) failed"));
}

#[test]
fn absent_skill_is_missing() {
    let w = w();
    w.install_all_expected();
    fs::remove_dir_all(w.p(".claude/skills/radin-stats")).unwrap();
    let r = w.doctor();
    assert_eq!(r.code, 1);
    assert!(r.out.contains("  MISSING  radin-stats\n"));
}

#[test]
fn complete_fixture_passes_and_the_dispatcher_is_checked_by_presence() {
    let w = w();
    w.install_all_expected();
    let r = w.doctor();
    assert_eq!(r.code, 0, "{}", r.out);
    assert!(r.out.contains("  OK       radin (dispatcher)\n"));
    assert!(r.out.ends_with("\nAll expected files present.\n"));
    fs::remove_file(w.p(".radin/bin/radin")).unwrap();
    let r = w.doctor();
    assert_eq!(r.code, 1);
    assert!(r.out.contains("  MISSING  radin (dispatcher)\n"));
}

#[test]
fn path_symlink_line_follows_the_link_target() {
    let w = w();
    w.install_all_expected();
    assert!(w.doctor().out.contains(
        "radin (PATH)         not on PATH (optional; skills fall back to the full path)\n"
    ));
    fs::create_dir_all(w.p(".local/bin")).unwrap();
    symlink(w.p(".radin/bin/radin"), w.p(".local/bin/radin")).unwrap();
    assert!(w
        .doctor()
        .out
        .contains("radin (PATH)         symlinked into ~/.local/bin\n"));
}

#[test]
fn pstack_skills_are_informational() {
    let w = w();
    w.install_all_expected();
    let r = w.doctor();
    assert_eq!(r.code, 0);
    assert!(r.out.contains("\n  unslop               not found\n"));
    put(&w.p(".claude/skills/unslop/SKILL.md"), "");
    let r = w.doctor();
    assert_eq!(r.code, 0);
    assert!(r.out.contains("\n  unslop               found\n"));
}

#[test]
fn companion_tools_are_informational() {
    let w = w();
    w.install_all_expected();
    w.mock("rtk", "exit 0\n");
    let r = w.doctor();
    assert_eq!(r.code, 0);
    assert!(r.out.contains("\n  rtk                  found\n"));
    assert!(r.out.contains("\n  codebase-memory-mcp  not found\n"));
}

#[test]
fn a_plugin_is_found_only_when_enabled_at_user_scope() {
    let w = w();
    w.install_all_expected();
    w.mock(
        "claude",
        "cat <<'LIST'\n  ❯ caveman@caveman\n    Version: 2.7.0\n    Scope: project\n    Status: ✔ enabled\n\n  ❯ ponytail@ponytail\n    Version: 4.10.0\n    Scope: user\n    Status: ✘ disabled\n\n  ❯ mattpocock-skills@claude-plugins-official\n    Version: 1.2.3\n    Scope: user\n    Status: ✔ enabled\nLIST\n",
    );
    let r = w.doctor();
    assert_eq!(r.code, 0, "{}", r.out);
    assert!(r.out.contains("\n  caveman              not found\n"));
    assert!(r.out.contains("\n  ponytail             disabled (its hooks do not run: claude plugin enable --scope user ponytail@ponytail)\n"));
    assert!(r.out.contains("\n  mattpocock-skills    found\n"));
}

#[test]
fn doctor_writes_nothing() {
    let w = w();
    w.install_all_expected();
    let snap = |p: &Path| {
        let mut v: Vec<(PathBuf, std::time::SystemTime)> = Vec::new();
        let mut stack = vec![p.to_path_buf()];
        while let Some(d) = stack.pop() {
            for e in fs::read_dir(d).unwrap() {
                let e = e.unwrap();
                let m = e.metadata().unwrap();
                v.push((e.path(), m.modified().unwrap()));
                if m.is_dir() {
                    stack.push(e.path());
                }
            }
        }
        v.sort();
        v
    };
    let before = (snap(&w.home), snap(&w.work));
    assert_eq!(w.doctor().code, 0);
    assert_eq!(before, (snap(&w.home), snap(&w.work)));
}

#[test]
fn cbm_hooks_in_settings_are_reported_ok() {
    let w = w();
    w.install_all_expected();
    w.mock("codebase-memory-mcp", "exit 0\n");
    put(
        &w.p(".claude/settings.json"),
        &format!(
            "{{\"hooks\":{{\"SessionStart\":[{{\"hooks\":[{{\"type\":\"command\",\"command\":\"{}/codebase-memory-mcp\"}}]}}]}}}}\n",
            w.bin.display()
        ),
    );
    let r = w.doctor();
    assert_eq!(r.code, 0, "{}", r.out);
    assert!(r.out.contains(&format!(
        "  OK       hooks in {}/.claude/settings.json\n",
        w.home.display()
    )));
    assert!(r.out.contains("  MISSING  MCP server entry"));
}

#[test]
fn a_hook_command_off_path_fails() {
    let w = w();
    w.install_all_expected();
    put(
        &w.p(".claude/settings.json"),
        "{\"hooks\":{\"SessionStart\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"caveman-session\"}]}]}}\n",
    );
    let r = w.doctor();
    assert_eq!(r.code, 1);
    let line = r
        .out
        .lines()
        .find(|l| l.starts_with("  INVALID  hook "))
        .expect(&r.out);
    assert!(line.contains("caveman-session"));
    assert!(!line.contains("DEAD"));
    assert!(r.out.contains("1 check(s) failed"));
}

#[test]
fn bare_name_absolute_executable_and_sh_wrapper_resolve() {
    let w = w();
    w.install_all_expected();
    w.mock("rtk", "");
    put(
        &w.p(".claude/settings.json"),
        &format!(
            "{{\"hooks\":{{\"SessionStart\":[{{\"hooks\":[\n{{\"type\":\"command\",\"command\":\"rtk hook claude\"}},\n{{\"type\":\"command\",\"command\":\"{0}/rtk\",\"args\":[\"x\"]}},\n{{\"type\":\"command\",\"command\":\"/bin/sh -c 'nothing-here || true'\"}}]}}]}}}}\n",
            w.bin.display()
        ),
    );
    let r = w.doctor();
    assert_eq!(r.code, 0, "{}", r.out);
    assert!(r.out.contains("  OK       every hook command resolves\n"));
}

#[test]
fn a_non_executable_absolute_hook_fails() {
    let w = w();
    w.install_all_expected();
    put(&w.bin.join("plain"), "");
    put(
        &w.p(".claude/settings.json"),
        &format!(
            "{{\"hooks\":{{\"Stop\":[{{\"hooks\":[{{\"type\":\"command\",\"command\":\"{}/plain\"}}]}}]}}}}\n",
            w.bin.display()
        ),
    );
    let r = w.doctor();
    assert_eq!(r.code, 1);
    assert!(r.out.contains("  INVALID  hook "));
}

#[test]
fn no_settings_json_means_no_hooks_to_check() {
    let w = w();
    w.install_all_expected();
    assert!(w
        .doctor()
        .out
        .contains("  OK       no settings.json, no hooks to check\n"));
}

#[test]
fn no_agents_section_without_an_agents_cli() {
    let w = w();
    w.agents_setup("");
    fs::remove_dir_all(w.p(".agents/skills/grilling")).unwrap();
    let r = w.doctor();
    assert_eq!(r.code, 0, "{}", r.out);
    assert!(!r.out.contains("Agents companion skills"));
}

#[test]
fn an_invoked_agents_skill_that_does_not_resolve_fails() {
    let w = w();
    w.agents_setup("\"codex\"");
    fs::remove_dir_all(w.p(".agents/skills/grilling")).unwrap();
    let r = w.doctor();
    assert_eq!(r.code, 1);
    assert!(r.out.contains("  MISSING  grilling\n"));
}

#[test]
fn a_non_invoked_agents_skill_is_only_not_found() {
    let w = w();
    w.agents_setup("\"codex\"");
    fs::remove_dir_all(w.p(".agents/skills/writing-for-agents")).unwrap();
    let r = w.doctor();
    assert_eq!(r.code, 0, "{}", r.out);
    assert!(r.out.contains("  writing-for-agents   not found\n"));
}

#[test]
fn an_opencode_dir_copy_counts_only_for_opencode_alone() {
    let w = w();
    w.agents_setup("\"opencode\"");
    fs::remove_dir_all(w.p(".agents/skills/grilling")).unwrap();
    put(&w.p(".config/opencode/skills/grilling/SKILL.md"), "");
    let r = w.doctor();
    assert_eq!(r.code, 0, "{}", r.out);
    assert!(r.out.contains("  OK       grilling\n"));
    w.manifest("\"agents_clis\": [\"codex\"]");
    assert_eq!(w.doctor().code, 1);
}

#[test]
fn a_codex_only_install_needs_no_claude_files() {
    let w = w();
    w.hosts_setup("\"codex\"", "\"codex\"");
    fs::remove_dir_all(w.p(".claude")).unwrap();
    fs::remove_dir_all(w.p(".radin/hosts/claude")).unwrap();
    let r = w.doctor();
    assert_eq!(r.code, 0, "{}", r.out);
    assert!(!r.out.contains("Skills ("));
    assert!(r.out.contains("\nCodex:\n"));
    assert!(!r.out.contains("opencode:"));
}

#[test]
fn a_claude_only_manifest_prints_no_host_section() {
    let w = w();
    w.install_all_expected();
    w.write_manifest("\"claude\"", "");
    let r = w.doctor();
    assert_eq!(r.code, 0, "{}", r.out);
    for s in ["Agents render", "Codex:", "opencode:", "Digests"] {
        assert!(!r.out.contains(s), "{s}");
    }
}

#[test]
fn digests_match_changed_and_absent_files_key() {
    let w = w();
    w.hosts_setup("\"codex\"", "\"codex\"");
    let rel = ".agents/skills/radin-do/SKILL.md";
    let d = digest(&w.p(rel));
    let other = format!("{:x}", Sha256::digest(b"x"));
    let manifest = format!(
        "\"hosts\": [\"codex\"],\n  \"agents_clis\": [\"codex\"],\n  \"files\": {{\n    \"{rel}\": \"{d}\",\n    \".claude/skills/radin-do/SKILL.md\": \"{other}\"\n  }}"
    );
    w.manifest(&manifest);
    let r = w.doctor();
    assert_eq!(r.code, 0, "{}", r.out);
    assert!(r
        .out
        .contains("  OK       1 file(s) match their recorded digest\n"));
    fs::write(w.p(rel), "edit").unwrap();
    let r = w.doctor();
    assert_eq!(r.code, 1);
    assert!(r.out.contains(&format!(
        "  INVALID  {}/{rel} (changed since install; install.sh --force restores it)\n",
        w.home.display()
    )));
    fs::remove_file(w.p(rel)).unwrap();
    assert!(w
        .doctor()
        .out
        .contains(&format!("  MISSING  {}/{rel}\n", w.home.display())));
    w.write_manifest("\"codex\"", "\"codex\"");
    put(&w.p(rel), "");
    let r = w.doctor();
    assert_eq!(r.code, 0);
    assert!(!r.out.contains("Digests"));
}

#[test]
fn an_unresolved_skill_token_fails() {
    let w = w();
    w.hosts_setup("\"codex\"", "\"codex\"");
    put(
        &w.p(".radin/hosts/agents/lib/radin-run.md"),
        "use @@skill:grilling@@\n",
    );
    let r = w.doctor();
    assert_eq!(r.code, 1);
    assert!(r
        .out
        .contains("  INVALID  unsubstituted RADIN_ token -- re-run install.sh\n"));
}

#[test]
fn the_token_scan_skips_a_file_named_radin_doctor_sh() {
    let w = w();
    w.install_all_expected();
    put(
        &w.p(".radin/lib/radin-doctor.sh"),
        "RADIN_MODEL_ @@skill:\n",
    );
    let r = w.doctor();
    assert_eq!(r.code, 0, "{}", r.out);
    put(&w.p(".radin/lib/other.txt"), "RADIN_EFFORT_\n");
    assert_eq!(w.doctor().code, 1);
}

#[test]
fn a_forbidden_string_fails_agents_and_passes_claude() {
    let w = w();
    w.hosts_setup("\"codex\"", "\"codex\"");
    put(
        &w.p(".radin/hosts/agents/lib/radin-run.md"),
        "AskUserQuestion\n",
    );
    let r = w.doctor();
    assert_eq!(r.code, 1);
    assert!(r.out.contains(&format!(
        "  INVALID  {}/.radin/hosts/agents/lib/radin-run.md (forbidden string \"AskUserQuestion\" in the agents render)\n",
        w.home.display()
    )), "{}", r.out);
    let w = self::w();
    w.hosts_setup("\"claude\"", "");
    put(
        &w.p(".radin/hosts/claude/lib/radin-run.md"),
        "AskUserQuestion\n",
    );
    assert_eq!(w.doctor().code, 0);
}

#[test]
fn with_both_clis_an_opencode_dir_skill_is_missing() {
    let w = w();
    w.hosts_setup("\"codex\", \"opencode\"", "\"codex\", \"opencode\"");
    fs::remove_dir_all(w.p(".agents/skills/grilling")).unwrap();
    put(&w.p(".config/opencode/skills/grilling/SKILL.md"), "");
    let r = w.doctor();
    assert_eq!(r.code, 1);
    assert!(r.out.contains("  MISSING  grilling\n"));
    w.write_manifest("\"opencode\"", "\"opencode\"");
    let r = w.doctor();
    assert_eq!(r.code, 0, "{}", r.out);
}

#[test]
fn codex_hooks_missing_untrusted_and_trusted_are_notes() {
    let w = w();
    w.hosts_setup("\"codex\"", "\"codex\"");
    let r = w.doctor();
    assert_eq!(r.code, 0, "{}", r.out);
    assert!(r.out.contains("  NOTE     no Codex hooks found"));
    put(
        &w.p(".codex/hooks.json"),
        "{\"hooks\":[{\"command\":\"x\"}]}\n",
    );
    let r = w.doctor();
    assert_eq!(r.code, 0);
    assert!(r
        .out
        .contains("open /hooks in Codex and trust the new hooks once"));
    put(
        &w.p(".codex/config.toml"),
        "[hooks.state.\"k\"]\ntrusted_hash = \"h\"\n",
    );
    let r = w.doctor();
    assert_eq!(r.code, 0);
    assert!(r.out.contains("  OK       Codex hook trust recorded"));
}

#[test]
fn codex_skills_probe_lists_or_notes() {
    let w = w();
    w.hosts_setup("\"codex\"", "\"codex\"");
    w.mock("codex", "echo radin-batch\n");
    let r = w.doctor();
    assert_eq!(r.code, 0, "{}", r.out);
    assert!(r.out.contains("  OK       Codex lists radin skills\n"));
    w.mock("codex", "exit 1\n");
    let r = w.doctor();
    assert_eq!(r.code, 0);
    assert!(r
        .out
        .contains("  NOTE     Codex skills listing did not answer"));
}

#[test]
fn opencode_version_gate() {
    let w = w();
    w.hosts_setup("\"opencode\"", "\"opencode\"");
    for v in ["2.2.5", "1.18.29"] {
        w.mock("opencode", &format!("echo opencode v{v}\n"));
        let r = w.doctor();
        assert_eq!(r.code, 0, "{}", r.out);
        assert!(r.out.contains(&format!("  OK       opencode {v}\n")));
    }
    w.mock("opencode", "echo opencode v1.18.28\n");
    let r = w.doctor();
    assert_eq!(r.code, 1);
    assert!(r
        .out
        .contains("  INVALID  opencode 1.18.28 is below 1.18.29\n"));
    w.mock("opencode", "echo dev\n");
    let r = w.doctor();
    assert_eq!(r.code, 0);
    assert!(r.out.contains("  NOTE     opencode version not readable\n"));
}

#[test]
fn opencode_agent_files_are_validated() {
    let w = w();
    w.hosts_setup("\"opencode\"", "\"opencode\"");
    let f = w.p(".config/opencode/agents/radin-planning.md");
    fs::write(
        &f,
        "---\ndescription: d\nmode: subagent\ntools: [bash]\n---\n",
    )
    .unwrap();
    let r = w.doctor();
    assert_eq!(r.code, 1);
    assert!(r.out.contains(&format!(
        "  INVALID  {} (tools line stops opencode from booting)\n",
        f.display()
    )));
    fs::write(&f, "---\ndescription: d\nmode: subagent\n").unwrap();
    let r = w.doctor();
    assert_eq!(r.code, 1);
    assert!(r.out.contains("front matter missing or not closed"));
    fs::write(&f, "---\nmode: subagent\n---\n").unwrap();
    assert!(w.doctor().out.contains("no description line"));
    fs::write(&f, "---\ndescription: d\nmode: primary\n---\n").unwrap();
    assert!(w.doctor().out.contains("mode is not subagent"));
}

#[test]
fn the_opencode_external_directory_rule_is_required() {
    let w = w();
    w.hosts_setup("\"opencode\"", "\"opencode\"");
    let r = w.doctor();
    assert_eq!(r.code, 0, "{}", r.out);
    assert!(r.out.contains("  OK       external_directory rule"));
    put(&w.p(".config/opencode/opencode.json"), "{}\n");
    let r = w.doctor();
    assert_eq!(r.code, 1);
    assert!(r
        .out
        .contains("  MISSING  opencode external_directory rule"));
    put(
        &w.p("custom.json"),
        &format!(
            "{{\"permission\":{{\"external_directory\":{{\"{}/.radin/**\":\"allow\"}}}}}}\n",
            w.home.display()
        ),
    );
    w.manifest(&format!(
        "\"opencode_allow\": \"{}/custom.json\",\n  \"hosts\": [\"opencode\"],\n  \"agents_clis\": [\"opencode\"]",
        w.home.display()
    ));
    assert_eq!(w.doctor().code, 0);
}

#[test]
fn the_shared_skills_note_needs_both_clis() {
    let w = w();
    w.hosts_setup("\"codex\", \"opencode\"", "\"codex\", \"opencode\"");
    let note = "codex and opencode share ~/.agents/skills: one render serves both";
    assert!(w.doctor().out.contains(note));
    w.write_manifest("\"codex\"", "\"codex\"");
    assert!(!w.doctor().out.contains("share ~/.agents/skills"));
}

#[test]
fn a_cli_off_path_is_not_found_and_exits_0() {
    let w = w();
    w.hosts_setup("\"codex\", \"opencode\"", "\"codex\", \"opencode\"");
    let r = w.doctor();
    assert_eq!(r.code, 0, "{}", r.out);
    for c in ["codex", "opencode"] {
        assert!(r.out.contains(&format!(
            "  {c:<20} not found (companion steps were skipped; install it, then re-run install.sh)\n"
        )));
    }
}

#[test]
fn a_missing_agents_skills_dir_fails() {
    let w = w();
    w.hosts_setup("\"codex\"", "\"codex\"");
    fs::remove_dir_all(w.p(".agents")).unwrap();
    let r = w.doctor();
    assert_eq!(r.code, 1);
    assert!(r
        .out
        .contains(&format!("  MISSING  {}/.agents/skills\n", w.home.display())));
}

#[test]
fn an_invalid_manifest_is_one_failure_and_hosts_default_to_claude() {
    let w = w();
    w.install_all_expected();
    put(&w.p(".radin/manifest.json"), "{");
    let r = w.doctor();
    assert_eq!(r.code, 1);
    assert!(r.out.contains(&format!(
        "\nManifest:\n  INVALID  {}/.radin/manifest.json (not valid JSON)\n",
        w.home.display()
    )));
    assert!(r.out.contains("1 check(s) failed"));
    assert!(r.out.contains("\nSkills ("));
}

#[test]
fn a_missing_guidance_block_fails() {
    let w = w();
    w.hosts_setup("\"codex\"", "\"codex\"");
    put(&w.p(".codex/AGENTS.md"), "no block\n");
    let r = w.doctor();
    assert_eq!(r.code, 1);
    assert!(r.out.contains(&format!(
        "  MISSING  {}/.codex/AGENTS.md (re-run install.sh)\n",
        w.home.display()
    )));
}

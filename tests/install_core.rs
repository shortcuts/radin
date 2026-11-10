#[path = "common/stubs.rs"]
mod stubs;

use serde_json::Value;
use sha2::{Digest, Sha256};
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::sync::OnceLock;
use stubs::{sha, Sandbox};

fn tpl() -> &'static Sandbox {
    static T: OnceLock<Sandbox> = OnceLock::new();
    T.get_or_init(|| {
        let s = Sandbox::shared("install-core");
        let r = s.install(&["--yes"]);
        assert_eq!(r.code, 0, "{}", r.all());
        s
    })
}

fn files(m: &Value) -> Vec<(String, String)> {
    m["files"]
        .as_object()
        .unwrap()
        .iter()
        .map(|(k, v)| (k.clone(), v.as_str().unwrap().to_string()))
        .collect()
}

fn strs(m: &Value, key: &str) -> Vec<String> {
    m[key]
        .as_array()
        .unwrap()
        .iter()
        .map(|v| v.as_str().unwrap().to_string())
        .collect()
}

fn walk(d: &Path, out: &mut Vec<String>) {
    for e in fs::read_dir(d).into_iter().flatten().flatten() {
        let p = e.path();
        if p.is_dir() {
            walk(&p, out);
        } else {
            out.push(p.to_string_lossy().into_owned());
        }
    }
}

fn files_under(d: &Path) -> Vec<String> {
    let mut v = vec![];
    walk(d, &mut v);
    v
}

fn edit_manifest(s: &Sandbox, f: impl FnOnce(&mut serde_json::Map<String, Value>)) {
    let mut m: Value = s.manifest();
    f(m.as_object_mut().unwrap());
    s.put(
        ".radin/manifest.json",
        &serde_json::to_string_pretty(&m).unwrap(),
    );
}

fn foreign_skill(s: &Sandbox, dir: &str) {
    s.put(&format!("{dir}/SKILL.md"), "mine\n");
}

#[test]
fn fresh_install_writes_layout_manifest_and_matching_digests() {
    let s = tpl();
    let m = s.manifest();
    assert_eq!(m["manifest_version"], 2);
    assert_eq!(strs(&m, "hosts"), ["claude"]);
    assert!(strs(&m, "agents_clis").is_empty());
    assert_eq!(m["wave_cap"], 2);
    assert_eq!(m["effort_planning"], "");
    assert_eq!(m["install_root"], s.home.join(".radin").to_str().unwrap());
    assert_eq!(m["cli_on_path"], true);
    assert_eq!(m["claude_md_guidance"], true);
    assert_eq!(m["companion_tools"]["rtk"], true);
    assert_eq!(m["companion_tools"]["codebase-memory-mcp"], false);
    assert!(strs(&m, "hostlib").contains(&"radin-run.md".into()));
    assert!(strs(&m, "skills").contains(&"thermo-nuclear".into()));
    assert!(!s.read(".radin/manifest.json").contains("headroom"));
    assert_eq!(
        s.read(".radin/install_root"),
        format!("{}\n", s.home.join(".radin").display())
    );

    let f = files(&m);
    assert!(f.len() > 40, "{}", f.len());
    for (k, d) in &f {
        assert_eq!(&sha(&s.p(k)), d, "{k}");
    }
    for k in [".claude/skills/radin-batch/SKILL.md", ".radin/bin/radin"] {
        assert!(f.iter().any(|(x, _)| x == k), "{k}");
    }

    assert!(files_under(&s.p(".radin/lib"))
        .iter()
        .all(|p| !p.ends_with(".md")));
    assert!(files_under(&s.p(".radin/hosts/claude/lib"))
        .iter()
        .all(|p| p.ends_with(".md")));
    assert!(s.p(".radin/hosts/claude/lib/radin-run.md").is_file());
    assert!(!s.p(".claude/.radin").exists());
    assert_eq!(
        fs::read_link(s.p(".local/bin/radin")).unwrap(),
        s.p(".radin/bin/radin")
    );
    assert_eq!(
        fs::metadata(s.p(".radin/bin/radin"))
            .unwrap()
            .permissions()
            .mode()
            & 0o111,
        0o111
    );
    assert_eq!(s.read(".claude/.ponytail-band"), "off");
}

#[test]
fn install_run_prints_review_box_and_steps_without_questions() {
    let s = Sandbox::new();
    let r = s.install(&["--yes"]);
    let o = r.all();
    assert_eq!(r.code, 0, "{o}");
    assert!(o.contains("┌─ Review "), "{o}");
    assert!(o.contains("[1/6] Installing radin"), "{o}");
    assert!(o.contains("radin installed in "), "{o}");
    assert!(!o.contains("Pick 1-") && !o.contains("Step 1/"), "{o}");
    assert!(s.log("brew").contains("install rtk"));
    let md = s.read(".claude/CLAUDE.md");
    assert!(md.contains("<!-- radin:begin -->") && md.contains("`/radin-record`"));
    assert!(md.contains("backlog show`") && !md.contains("/radin-show"));
}

#[test]
fn tokens_resolve_to_installed_paths_and_models() {
    let s = tpl();
    let run = s.read(".radin/hosts/claude/lib/radin-run.md");
    let lib = s.p(".radin/hosts/claude/lib");
    assert!(run.contains(&format!("{}/radin-batch-clarify.md", lib.display())));
    assert!(run.contains(&format!("{}/radin-batch-gate.md", lib.display())));
    assert!(run.contains("\"$HOME/.radin/bin/radin\" backlog"));
    for p in files_under(&s.p(".claude/skills"))
        .iter()
        .chain(&files_under(&lib))
    {
        let t = fs::read_to_string(p).unwrap_or_default();
        for tok in ["RADIN_LIB", "RADIN_CLI", "RADIN_MODEL_", "RADIN_EFFORT_"] {
            assert!(!t.contains(tok), "{tok} in {p}");
        }
    }
    let gate = s.read(".radin/hosts/claude/lib/radin-prompt-gate.md");
    assert!(gate.contains("model: \"sonnet\"") && gate.contains("effort: \"\""));
    assert!(s
        .read(".radin/hosts/claude/lib/radin-prompt-factfind.md")
        .contains("model: \"haiku\""));
    assert!(!s
        .read(".radin/hosts/claude/lib/radin-prompt-execution.md")
        .contains("model-low"));
    for sk in ["radin-batch", "radin-do"] {
        assert!(s
            .read(&format!(".claude/skills/{sk}/SKILL.md"))
            .contains(&format!("{}/radin-run.md", lib.display())));
    }
}

const LIB_SUFFIX: &str = "/.radin/hosts/claude/lib";

/// Same rule as tests/golden_render.rs: a baked path is dropped up to its lib directory, so the home differs per run.
fn normalise(s: &str) -> String {
    let mut out = String::new();
    let mut run = String::new();
    let flush = |run: &mut String, out: &mut String| {
        let mut rest = run.as_str();
        while let Some(p) = rest.rfind(LIB_SUFFIX) {
            out.push_str("@RADIN_LIB@");
            rest = &rest[p + LIB_SUFFIX.len()..];
        }
        out.push_str(rest);
        run.clear();
    };
    for c in s.chars() {
        if c == '"' || c.is_whitespace() {
            flush(&mut run, &mut out);
            out.push(c);
        } else {
            run.push(c);
        }
    }
    flush(&mut run, &mut out);
    out.replace("\"$HOME/.radin/bin/radin\"", "@RADIN_CLI@")
}

#[test]
fn installed_claude_render_matches_the_golden_sums() {
    let s = tpl();
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let norm = |t: String| format!("{:x}", Sha256::digest(normalise(&t).as_bytes()));
    let golden = fs::read_to_string(root.join("tests/golden-claude-render.sha256")).unwrap();
    let mut n = 0;
    for l in golden.lines() {
        let (sum, key) = l.split_once("  ").unwrap();
        let rel = match key.split_once('/') {
            Some(("skills", r)) => format!(".claude/skills/{r}"),
            Some(("lib", r)) => format!(".radin/hosts/claude/lib/{r}"),
            _ => panic!("{key}"),
        };
        assert_eq!(norm(s.read(&rel)), sum, "{key}");
        n += 1;
    }
    assert!(n > 30);
}

#[test]
fn pstack_skills_install_without_the_invocation_block() {
    let s = tpl();
    for n in ["unslop", "technical-writing"] {
        let t = s.read(&format!(".claude/skills/{n}/SKILL.md"));
        assert!(
            t.starts_with("---") && !t.contains("disable-model-invocation"),
            "{n}"
        );
        assert_eq!(s.manifest()["companion_tools"][n], true);
    }
    assert!(!s.p(".agents").exists());
    assert!(strs(&s.manifest(), "agents_skills").is_empty());
    assert!(!s.log("curl").contains("/skills/surgical-patch"));
}

#[test]
fn doctor_passes_on_a_fresh_install() {
    let s = tpl();
    let r = s.run_env(&["doctor"], "", &[]);
    assert_eq!(r.code, 0, "{}", r.all());
    assert!(r.out.contains("All expected files present."), "{}", r.out);
    assert!(r.out.contains("no unsubstituted token left"));
    assert!(r.out.contains("file(s) match their recorded digest"));
}

#[test]
fn doctor_finds_and_uninstall_removes_exactly_what_install_ships() {
    let s = Sandbox::new();
    assert_eq!(s.install(&["--yes"]).code, 0);
    let r = s.run_env(&["uninstall"], "", &[]);
    assert_eq!(r.code, 0, "{}", r.all());
    assert!(files_under(&s.p(".radin/lib")).is_empty());
    assert!(files_under(&s.p(".radin/hosts/claude/lib")).is_empty());
    let radin_skills: Vec<_> = fs::read_dir(s.p(".claude/skills"))
        .unwrap()
        .flatten()
        .filter(|e| e.file_name().to_string_lossy().starts_with("radin-"))
        .collect();
    assert!(radin_skills.is_empty());
    assert!(s.p(".claude/skills/thermo-nuclear/SKILL.md").is_file());
    assert!(!s.p(".radin/manifest.json").exists() && !s.p(".radin/install_root").exists());
    assert!(!s.p(".radin/lib").exists());
}

#[test]
fn guidance_block_is_written_once_and_keeps_user_content() {
    let s = Sandbox::new();
    s.put(".claude/CLAUDE.md", "user content stays\n");
    assert_eq!(s.install(&["--yes"]).code, 0);
    let before = s.read(".claude/CLAUDE.md");
    assert_eq!(s.install(&["--yes"]).code, 0);
    let after = s.read(".claude/CLAUDE.md");
    assert_eq!(before, after);
    assert!(after.starts_with("user content stays\n"));
    assert_eq!(after.matches("<!-- radin:begin -->").count(), 1);
    assert_eq!(after.matches("<!-- radin:end -->").count(), 1);
    assert_eq!(s.manifest()["claude_md_guidance"], true);
}

#[test]
fn renamed_skills_are_removed_and_a_foreign_one_of_that_name_stays() {
    let s = Sandbox::new();
    for n in ["radin-execute", "radin-implement", "radin-show"] {
        s.put(
            &format!(".claude/skills/{n}/SKILL.md"),
            &format!("---\nname: {n}\n---\n"),
        );
    }
    s.put(
        ".claude/skills/radin-run/SKILL.md",
        "---\nname: mine\n---\n",
    );
    assert_eq!(s.install(&["--yes"]).code, 0);
    for n in ["radin-execute", "radin-implement", "radin-show"] {
        assert!(!s.p(&format!(".claude/skills/{n}")).exists(), "{n}");
    }
    assert!(s.p(".claude/skills/radin-run/SKILL.md").is_file());
    assert!(s.p(".claude/skills/radin-batch/SKILL.md").is_file());
}

#[test]
fn list_prints_one_row_per_host_and_writes_nothing() {
    let s = Sandbox::new();
    s.remove("claude");
    let r = s.install(&["--list"]);
    assert_eq!(r.code, 0);
    assert_eq!(
        r.out,
        "claude\tClaude Code\tno\ncodex\tCodex CLI\tno\nopencode\topencode\tno\n"
    );
    s.add("codex");
    s.put(".claude/x", "");
    let r = s.install(&["--list"]);
    assert_eq!(
        r.out,
        "claude\tClaude Code\tyes\ncodex\tCodex CLI\tyes\nopencode\topencode\tno\n"
    );
    assert!(!s.p(".radin").exists());
}

#[test]
fn bad_flags_exit_2_with_usage_before_any_write() {
    let s = Sandbox::new();
    for args in [
        &["--nope"][..],
        &["--only", "vim"],
        &["--only"],
        &["--wave-cap", "0"],
        &["--wave-cap"],
        &["--wave-cap", "x"],
    ] {
        let r = s.install(args);
        assert_eq!(r.code, 2, "{args:?}");
        assert!(r.err.starts_with("usage: radin install"), "{}", r.err);
    }
    assert!(s.tree().is_empty());
}

#[test]
fn wave_cap_is_stored_defaults_to_two_and_survives_update() {
    let s = Sandbox::new();
    assert_eq!(s.install(&["--yes", "--wave-cap", "3"]).code, 0);
    assert_eq!(s.manifest()["wave_cap"], 3);
    assert_eq!(s.install(&["--yes", "--update"]).code, 0);
    assert_eq!(s.manifest()["wave_cap"], 3);
    assert_eq!(s.install(&["--yes", "--wave-cap=5"]).code, 0);
    assert_eq!(s.manifest()["wave_cap"], 5);
}

#[test]
fn no_flag_no_terminal_installs_claude_only_even_with_codex_on_path() {
    let s = Sandbox::new();
    s.add("codex");
    let r = s.run_env(&["install"], "2\n", &[]);
    assert_eq!(r.code, 0, "{}", r.all());
    assert_eq!(strs(&s.manifest(), "hosts"), ["claude"]);
    assert!(strs(&s.manifest(), "agents_clis").is_empty());
    assert!(!s.p(".agents").exists() && !s.p(".radin/hosts/agents").exists());
}

#[test]
fn picking_mise_installs_rtk_through_mise_not_brew() {
    let s = Sandbox::new();
    s.add("mise");
    let r = s.run_env(&["install"], "2\n2\n", &[]);
    assert_eq!(r.code, 0, "{}", r.all());
    assert!(s.log("mise").contains("aqua:rtk-ai/rtk"));
    assert!(!s.log("brew").contains("install rtk"));
    assert_eq!(s.manifest()["package_manager"], "mise");
}

#[test]
fn update_asks_nothing_prints_the_recap_and_keeps_the_answers() {
    let s = Sandbox::new();
    assert_eq!(s.install(&["--yes"]).code, 0);
    edit_manifest(&s, |m| {
        m.insert("model_planning".into(), "opus".into());
        m.insert("model_factfind".into(), "fable".into());
        m.shift_remove("package_manager");
    });
    let r = s.install(&["--update"]);
    let o = r.all();
    assert_eq!(r.code, 0, "{o}");
    assert!(o.contains("┌─ Recap "), "{o}");
    assert!(
        o.contains("Models           opus: planning, execution, review, debug"),
        "{o}"
    );
    assert!(o.contains("Package manager  curl"), "{o}");
    assert!(o.contains("keeping sub-agent models: opus, fable for fact-finding"));
    assert!(!o.contains("Pick 1-") && !o.contains("Step 1/"));
    assert!(s
        .read(".radin/hosts/claude/lib/radin-prompt-planning.md")
        .contains("opus"));
    assert_eq!(s.manifest()["package_manager"], "curl");
}

#[test]
fn a_failing_companion_and_a_missing_claude_cli_warn_and_the_install_completes() {
    let s = Sandbox::new();
    s.remove("claude");
    let r = s.run_env(&["install", "--yes"], "", &[("MOCK_FAIL", "brew")]);
    let o = r.all();
    assert_eq!(r.code, 0, "{o}");
    assert!(o.contains("rtk install failed"), "{o}");
    assert!(o.contains("caveman skipped: the 'claude' CLI is not on PATH"));
    assert!(!o.contains("caveman install failed"));
    assert!(o.contains("radin installed in "));
}

#[test]
fn an_install_that_dies_mid_run_says_the_install_is_partial() {
    let s = Sandbox::new();
    let r = s.run_env(&["install", "--yes"], "", &[("MOCK_NPX", "fail")]);
    assert_ne!(r.code, 0);
    assert!(r.err.contains("partial install"), "{}", r.all());
    assert!(fs::symlink_metadata(s.p(".local/bin/radin")).is_ok());
    for p in files_under(&s.p(".claude/skills")) {
        assert!(
            !fs::read_to_string(&p)
                .unwrap_or_default()
                .contains("RADIN_"),
            "{p}"
        );
    }
    assert!(s.read(".claude/CLAUDE.md").contains("radin:begin"));
}

#[test]
fn a_disabled_plugin_gets_enabled_and_a_failed_enable_warns() {
    let s = Sandbox::new();
    s.put(
        "plugins.txt",
        "  ❯ ponytail@ponytail\n    Version: 4.10.0\n    Scope: user\n    Status: ✘ disabled\n",
    );
    let list = s.p("plugins.txt");
    let r = s.run_env(
        &["install", "--yes"],
        "",
        &[("MOCK_CLAUDE_LIST", list.to_str().unwrap())],
    );
    assert_eq!(r.code, 0, "{}", r.all());
    let log = s.log("claude");
    assert!(
        log.contains("plugin enable --scope user ponytail@ponytail"),
        "{log}"
    );
    assert!(!log.contains("plugin enable --scope user caveman@caveman"));
    assert!(r.all().contains("ponytail is installed but disabled"));
}

#[test]
fn a_failed_pstack_download_keeps_the_installed_copy_and_exits_zero() {
    let s = Sandbox::new();
    assert_eq!(s.install(&["--yes"]).code, 0);
    s.put(".claude/skills/unslop/SKILL.md", "kept\n");
    let r = s.run_env(
        &["install", "--yes", "--update"],
        "",
        &[("MOCK_CURL", "pstack-fail")],
    );
    assert_eq!(r.code, 0, "{}", r.all());
    assert_eq!(s.read(".claude/skills/unslop/SKILL.md"), "kept\n");
    assert!(r.all().contains("download failed"));
    assert_eq!(s.manifest()["companion_tools"]["unslop"], true);
}

#[test]
fn a_skill_radin_did_not_install_is_never_overwritten() {
    let s = Sandbox::new();
    foreign_skill(&s, ".claude/skills/unslop");
    let r = s.install(&["--yes"]);
    assert_eq!(r.code, 0, "{}", r.all());
    assert_eq!(s.read(".claude/skills/unslop/SKILL.md"), "mine\n");
    assert!(r.all().contains("unslop skipped"));
    let m = s.manifest();
    assert_eq!(m["companion_tools"]["unslop"], false);
    assert_eq!(m["companion_tools"]["technical-writing"], true);
}

#[test]
fn update_keeps_present_companions_and_reinstalls_only_the_missing() {
    let s = Sandbox::new();
    assert_eq!(s.install(&["--yes"]).code, 0);
    s.add("rtk");
    s.add("codebase-memory-mcp");
    let list: String = [
        "caveman@caveman",
        "ponytail@ponytail",
        "mattpocock-skills@claude-plugins-official",
    ]
    .iter()
    .map(|p| format!("  ❯ {p}\n    Scope: user\n    Status: ✔ enabled\n"))
    .collect();
    s.put("plugins.txt", &list);
    let _ = fs::remove_file(s.home.join("brew.log"));
    let _ = fs::remove_file(s.home.join("claude.log"));
    let lp = s.p("plugins.txt");
    let r = s.run_env(
        &["install", "--update"],
        "",
        &[("MOCK_CLAUDE_LIST", lp.to_str().unwrap())],
    );
    let o = r.all();
    assert_eq!(r.code, 0, "{o}");
    assert!(
        o.contains("rtk already installed.") && o.contains("caveman already installed."),
        "{o}"
    );
    assert!(!s.log("brew").contains("install rtk"));
    assert!(!s.log("claude").contains("plugin install"));
    assert!(o.contains("thermo-nuclear already installed."));
}

#[test]
fn a_foreign_cli_link_stays_and_refresh_reinstalls_present_tools() {
    let s = Sandbox::new();
    s.put(".local/bin/radin", "someone else's");
    s.add("rtk");
    s.add("codebase-memory-mcp");
    let r = s.run_env(
        &["install", "--yes", "--refresh"],
        "",
        &[("MOCK_CBM", "fail-install")],
    );
    let o = r.all();
    assert_eq!(r.code, 0, "{o}");
    assert_eq!(s.read(".local/bin/radin"), "someone else's");
    assert!(o.contains("isn't radin's"), "{o}");
    assert!(s.log("brew").contains("install rtk"));
    assert!(s.log("npx").contains("skills@latest add"));
    assert!(
        o.contains("codebase-memory-mcp configuration failed -- radin itself is unaffected."),
        "{o}"
    );
    assert!(o.contains("cbm-config.log") && !o.contains("OpenCode:"));
    assert!(s.read(".radin/cbm-config.log").contains("OpenCode:"));
    assert_eq!(s.manifest()["cli_on_path"], false);
}

#[test]
fn an_unowned_skill_stops_the_claude_host_and_writes_nothing() {
    let s = Sandbox::new();
    foreign_skill(&s, ".claude/skills/radin-batch");
    let before = s.tree();
    let r = s.install(&["--yes", "--only", "claude"]);
    assert_eq!(r.code, 1);
    assert!(
        r.all().contains("exists and radin did not install it"),
        "{}",
        r.all()
    );
    assert_eq!(before, s.tree());
    assert!(!s.p(".radin").exists());
}

#[test]
fn dry_run_reports_a_conflict_and_a_kept_edit_and_writes_nothing() {
    let s = Sandbox::new();
    foreign_skill(&s, ".claude/skills/radin-batch");
    let before = s.tree();
    let r = s.install(&["--yes", "--dry-run", "--only", "claude"]);
    assert_eq!(r.code, 1);
    assert!(
        r.out.contains(&format!(
            "conflict {}",
            s.p(".claude/skills/radin-batch").display()
        )),
        "{}",
        r.out
    );
    assert!(r.out.contains("skip host claude"));
    assert_eq!(before, s.tree());

    let s = Sandbox::new();
    assert_eq!(s.install(&["--yes", "--only", "claude"]).code, 0);
    let skill = s.p(".claude/skills/radin-do/SKILL.md");
    fs::write(
        &skill,
        format!("{}my edit\n", fs::read_to_string(&skill).unwrap()),
    )
    .unwrap();
    let before = s.tree();
    let r = s.install(&["--yes", "--dry-run", "--only", "claude"]);
    assert_eq!(r.code, 0, "{}", r.all());
    assert!(r.out.contains(&format!("keep {}", skill.display())));
    assert!(r.out.contains("write ") && r.out.contains("\nrun "));
    assert_eq!(before, s.tree());
}

#[test]
fn update_dry_run_lists_writes_and_changes_no_byte() {
    let s = Sandbox::new();
    let a = s.assets_copy();
    let env = [("RADIN_ASSETS", a.to_str().unwrap())];
    assert_eq!(
        s.run_env(&["install", "--yes", "--only", "claude"], "", &env)
            .code,
        0
    );
    let run = a.join("lib/radin-run.md");
    fs::write(
        &run,
        format!("{}\nUPDATE-MARKER\n", fs::read_to_string(&run).unwrap()),
    )
    .unwrap();
    let before = s.tree();
    let r = s.run_env(&["install", "--update", "--dry-run"], "", &env);
    assert_eq!(r.code, 0, "{}", r.all());
    assert!(r.out.contains("write "));
    assert_eq!(before, s.tree());
    assert!(!s
        .read(".radin/hosts/claude/lib/radin-run.md")
        .contains("UPDATE-MARKER"));
    let r = s.run_env(&["install", "--update", "--yes"], "", &env);
    assert_eq!(r.code, 0);
    assert!(s
        .read(".radin/hosts/claude/lib/radin-run.md")
        .contains("UPDATE-MARKER"));
}

#[test]
fn force_backs_an_unowned_skill_up_and_records_it() {
    let s = Sandbox::new();
    foreign_skill(&s, ".claude/skills/radin-batch");
    let r = s.install(&["--yes", "--only", "claude", "--force"]);
    assert_eq!(r.code, 0, "{}", r.all());
    let backed = files_under(&s.p(".radin/backups"))
        .into_iter()
        .find(|p| p.ends_with(".claude/skills/radin-batch/SKILL.md"))
        .expect("backup");
    assert_eq!(fs::read_to_string(backed).unwrap(), "mine\n");
    assert!(s
        .read(".claude/skills/radin-batch/SKILL.md")
        .starts_with("---"));
    assert_eq!(
        s.manifest()["backups"]
            .as_object()
            .unwrap()
            .values()
            .next()
            .unwrap(),
        ".claude/skills/radin-batch"
    );
    assert!(!s.p(".claude/skills/radin-batch.bak").exists());
}

#[test]
fn force_replaces_an_edited_skill_and_backs_the_edit_up() {
    let s = Sandbox::new();
    assert_eq!(s.install(&["--yes", "--only", "claude"]).code, 0);
    let f = s.p(".claude/skills/radin-do/SKILL.md");
    fs::write(&f, format!("{}my edit\n", fs::read_to_string(&f).unwrap())).unwrap();
    let r = s.install(&["--yes", "--update", "--force"]);
    assert_eq!(r.code, 0, "{}", r.all());
    assert!(!fs::read_to_string(&f)
        .unwrap()
        .lines()
        .any(|l| l == "my edit"));
    let backed = files_under(&s.p(".radin/backups"))
        .into_iter()
        .find(|p| p.ends_with(".claude/skills/radin-do/SKILL.md"))
        .expect("backup");
    assert!(fs::read_to_string(backed)
        .unwrap()
        .lines()
        .any(|l| l == "my edit"));
    assert_eq!(
        s.manifest()["files"][".claude/skills/radin-do/SKILL.md"],
        sha(&f)
    );
}

#[test]
fn a_v1_manifest_owns_its_skills_and_reads_as_claude_only() {
    let s = Sandbox::new();
    assert_eq!(s.install(&["--yes", "--only", "claude"]).code, 0);
    edit_manifest(&s, |m| {
        for k in ["manifest_version", "hosts", "agents_clis", "files"] {
            m.shift_remove(k);
        }
    });
    let f = s.p(".claude/skills/radin-do/SKILL.md");
    fs::write(&f, format!("{}my edit\n", fs::read_to_string(&f).unwrap())).unwrap();
    let r = s.install(&["--yes", "--update"]);
    assert_eq!(r.code, 0, "{}", r.all());
    assert!(!r.all().contains("did not install it"));
    assert!(!fs::read_to_string(&f)
        .unwrap()
        .lines()
        .any(|l| l == "my edit"));
    assert_eq!(strs(&s.manifest(), "hosts"), ["claude"]);
    assert_eq!(s.manifest()["manifest_version"], 2);
}

#[test]
fn an_edited_skill_is_kept_with_its_old_digest_on_every_rerun_in_each_hosts_tree() {
    let s = Sandbox::new();
    s.add("codex");
    assert_eq!(s.install(&["--yes", "--only", "claude,codex"]).code, 0);
    let rels = [
        ".claude/skills/radin-do/SKILL.md",
        ".agents/skills/radin-do/SKILL.md",
    ];
    let digests: Vec<Value> = rels
        .iter()
        .map(|r| s.manifest()["files"][r].clone())
        .collect();
    for r in rels {
        let f = s.p(r);
        fs::write(&f, format!("{}my edit\n", fs::read_to_string(&f).unwrap())).unwrap();
    }
    for _ in 0..2 {
        let r = s.install(&["--yes", "--update"]);
        assert_eq!(r.code, 0, "{}", r.all());
        for (i, rel) in rels.iter().enumerate() {
            assert!(r.all().contains(&format!("kept {}", s.p(rel).display())));
            assert!(s.read(rel).lines().any(|l| l == "my edit"));
            assert_eq!(s.manifest()["files"][rel], digests[i]);
        }
    }
}

#[test]
fn only_with_all_three_hosts_builds_both_renders_and_the_agents_step_runs_once() {
    let s = Sandbox::new();
    s.add("codex");
    s.add("opencode");
    let r = s.install(&["--yes", "--only", "opencode,claude,codex,claude"]);
    let o = r.all();
    assert_eq!(r.code, 0, "{o}");
    for f in [
        ".claude/skills/radin-batch/SKILL.md",
        ".agents/skills/radin-batch/SKILL.md",
        ".radin/hosts/claude/lib/radin-run.md",
        ".radin/hosts/agents/lib/radin-run.md",
    ] {
        assert!(s.p(f).is_file(), "{f}");
    }
    assert_eq!(o.matches("agents render installed").count(), 1);
    let m = s.manifest();
    assert_eq!(strs(&m, "hosts"), ["claude", "codex", "opencode"]);
    assert_eq!(strs(&m, "agents_clis"), ["codex", "opencode"]);
    let mut all = files_under(&s.p(".agents/skills"));
    all.extend(files_under(&s.p(".radin/hosts/agents/lib")));
    for p in all.iter().filter(|p| p.ends_with(".md")) {
        let t = fs::read_to_string(p).unwrap();
        for tok in [
            "<!-- host",
            "@@skill:",
            "RADIN_LIB",
            "RADIN_CLI",
            "RADIN_MODEL_",
            "RADIN_EFFORT_",
        ] {
            assert!(!t.contains(tok), "{tok} in {p}");
        }
    }
}

#[test]
fn only_codex_or_only_opencode_installs_the_agents_render_and_nothing_under_claude() {
    for cli in ["codex", "opencode"] {
        let s = Sandbox::new();
        s.add(cli);
        let r = s.install(&["--yes", "--only", cli]);
        assert_eq!(r.code, 0, "{cli}: {}", r.all());
        assert!(s.p(".agents/skills/radin-batch/SKILL.md").is_file());
        assert!(s.p(".radin/hosts/agents/lib/radin-run.md").is_file());
        assert!(!s.p(".claude/skills/radin-batch").exists());
        assert!(!s.p(".claude/CLAUDE.md").exists());
        assert!(!s.p(".radin/hosts/claude").exists());
        let m = s.manifest();
        assert_eq!(strs(&m, "hosts"), [cli]);
        assert_eq!(strs(&m, "agents_clis"), [cli]);
    }
}

#[test]
fn every_selected_host_installs_its_files_when_no_host_cli_exists() {
    let s = Sandbox::new();
    s.remove("claude");
    let r = s.install(&["--yes", "--only", "claude,codex,opencode"]);
    let o = r.all();
    assert_eq!(r.code, 0, "{o}");
    assert!(o.contains("codex CLI not found") && o.contains("opencode CLI not found"));
    let m = s.manifest();
    assert_eq!(strs(&m, "hosts"), ["claude", "codex", "opencode"]);
    assert_eq!(strs(&m, "agents_clis"), ["codex", "opencode"]);
    assert!(s.p(".claude/skills/radin-batch/SKILL.md").is_file());
    assert!(s.p(".agents/skills/radin-batch/SKILL.md").is_file());
    assert!(s.p(".config/opencode/agents/radin-review.md").is_file());
}

#[test]
fn a_claude_render_that_fails_leaves_claude_out_and_keeps_codex() {
    let s = Sandbox::new();
    s.add("codex");
    let a = s.assets_copy();
    fs::write(a.join("lib/skill-names-claude.txt"), "").unwrap();
    let r = s.run_env(
        &["install", "--yes", "--only", "claude,codex"],
        "",
        &[("RADIN_ASSETS", a.to_str().unwrap())],
    );
    assert_eq!(r.code, 0, "{}", r.all());
    assert!(r.all().contains("claude render failed"));
    assert_eq!(strs(&s.manifest(), "hosts"), ["codex"]);
    assert!(!s.p(".claude/skills/radin-batch").exists());
    assert!(s.p(".agents/skills/radin-batch/SKILL.md").is_file());
}

#[test]
fn update_leaves_a_host_whose_render_fails_untouched_and_retries_it_next_time() {
    let s = Sandbox::new();
    s.add("codex");
    let a = s.assets_copy();
    let env = [("RADIN_ASSETS", a.to_str().unwrap())];
    assert_eq!(
        s.run_env(&["install", "--yes", "--only", "claude,codex"], "", &env)
            .code,
        0
    );
    let agents_tree = |s: &Sandbox| -> Vec<(String, String)> {
        s.tree()
            .into_iter()
            .filter(|(k, _)| k.starts_with(".agents") || k.starts_with(".radin/hosts/agents"))
            .collect()
    };
    let digest = s.manifest()["files"][".agents/skills/radin-do/SKILL.md"].clone();
    let before = agents_tree(&s);
    let run = a.join("lib/radin-run.md");
    let orig = fs::read_to_string(&run).unwrap();
    fs::write(&run, format!("{orig}\nUPDATE-MARKER\nAskUserQuestion\n")).unwrap();
    let r = s.run_env(&["install", "--update"], "", &env);
    assert_eq!(r.code, 0, "{}", r.all());
    assert!(r.all().contains("agents render failed"));
    assert!(s
        .read(".radin/hosts/claude/lib/radin-run.md")
        .contains("UPDATE-MARKER"));
    assert_eq!(before, agents_tree(&s));
    let m = s.manifest();
    assert_eq!(strs(&m, "hosts"), ["claude", "codex"]);
    assert_eq!(strs(&m, "agents_clis"), ["codex"]);
    assert_eq!(m["files"][".agents/skills/radin-do/SKILL.md"], digest);
    assert_eq!(m["codex_guidance"], true);
    fs::write(&run, format!("{orig}\nUPDATE-MARKER\n")).unwrap();
    assert_eq!(s.run_env(&["install", "--update"], "", &env).code, 0);
    assert!(s
        .read(".radin/hosts/agents/lib/radin-run.md")
        .contains("UPDATE-MARKER"));
}

#[test]
fn update_refreshes_an_agents_only_install_and_touches_no_claude_tree() {
    let s = Sandbox::new();
    s.add("codex");
    let a = s.assets_copy();
    let env = [("RADIN_ASSETS", a.to_str().unwrap())];
    assert_eq!(
        s.run_env(&["install", "--yes", "--only", "codex"], "", &env)
            .code,
        0
    );
    let run = a.join("lib/radin-run.md");
    fs::write(
        &run,
        format!("{}\nUPDATE-MARKER\n", fs::read_to_string(&run).unwrap()),
    )
    .unwrap();
    let r = s.run_env(&["install", "--update"], "", &env);
    assert_eq!(r.code, 0, "{}", r.all());
    assert!(!r.all().contains("Pick 1-"));
    assert!(s
        .read(".radin/hosts/agents/lib/radin-run.md")
        .contains("UPDATE-MARKER"));
    assert!(!s.p(".radin/hosts/claude").exists());
    assert_eq!(strs(&s.manifest(), "hosts"), ["codex"]);
}

#[test]
fn three_host_lifecycle_keeps_foreign_content_and_leaves_no_radin_file() {
    let s = Sandbox::new();
    s.add("codex");
    s.add("opencode");
    s.put(".claude/CLAUDE.md", "mine\n");
    s.put(".codex/AGENTS.md", "mine\n");
    s.put(".config/opencode/AGENTS.md", "mine\n");
    s.put(
        ".config/opencode/opencode.json",
        "{\"permission\":{\"external_directory\":{\"/keep/**\":\"allow\"}}}\n",
    );
    foreign_skill(&s, ".claude/skills/foreign");
    foreign_skill(&s, ".agents/skills/foreign");
    let seeded: Vec<String> = s.tree().into_iter().map(|t| t.0).collect();
    let r = s.install(&["--yes", "--only", "claude,codex,opencode"]);
    assert_eq!(r.code, 0, "{}", r.all());
    let agents_run = s.read(".radin/hosts/agents/lib/radin-run.md");
    assert!(
        agents_run.contains("radin\" --host agents state set-status")
            || agents_run.contains("radin --host agents state set-status")
    );
    let src =
        fs::read_to_string(Path::new(env!("CARGO_MANIFEST_DIR")).join("lib/radin-run.md")).unwrap();
    let rules = radin::render::Rules::embedded("agents").unwrap();
    let rendered = radin::render::render(&src, "lib/radin-run.md", &rules).unwrap();
    assert_eq!(
        rendered.matches("RADIN_CLI").count(),
        agents_run.matches("--host agents").count()
    );
    assert!(!s
        .read(".claude/skills/radin-do/SKILL.md")
        .contains("radin --host claude"));
    let d = s.run_env(&["doctor"], "", &[]);
    assert_eq!(d.code, 0, "{}", d.all());

    let stable = |s: &Sandbox| -> Vec<(String, String)> {
        s.tree()
            .into_iter()
            .filter(|(k, _)| {
                k != ".radin/manifest.json"
                    && !k.ends_with(".log")
                    && !k.starts_with(".radin/backups/")
            })
            .collect()
    };
    let before = stable(&s);
    let r = s.install(&["--yes", "--update"]);
    assert_eq!(r.code, 0, "{}", r.all());
    assert!(r.all().contains("0 written"), "{}", r.all());
    assert_eq!(before, stable(&s));

    let r = s.run_env(&["uninstall"], "", &[]);
    assert_eq!(r.code, 0, "{}", r.all());
    for f in [
        ".claude/CLAUDE.md",
        ".codex/AGENTS.md",
        ".config/opencode/AGENTS.md",
    ] {
        assert_eq!(s.read(f), "mine\n", "{f}");
    }
    let oc = s.read(".config/opencode/opencode.json");
    assert!(oc.contains("/keep/**") && !oc.contains(".radin/**"));
    assert!(
        s.p(".claude/skills/foreign/SKILL.md").is_file()
            && s.p(".agents/skills/foreign/SKILL.md").is_file()
    );
    let left: Vec<String> = s
        .tree()
        .into_iter()
        .map(|t| t.0)
        .filter(|k| !seeded.contains(k))
        .filter(|k| {
            !k.ends_with(".log")
                && k != ".claude/.ponytail-band"
                && k != ".claude/settings.json"
                && !k.starts_with(".radin/backups/")
                && !k.starts_with(".agents/skills/")
                && !k.starts_with(".claude/skills/")
        })
        .collect();
    assert!(left.is_empty(), "left behind: {left:?}");
    for dir in [".claude/skills", ".agents/skills"] {
        assert!(fs::read_dir(s.p(dir))
            .unwrap()
            .flatten()
            .all(|e| !e.file_name().to_string_lossy().starts_with("radin-")));
    }
}

#[test]
fn step_total_matches_the_step_calls() {
    let src = fs::read_to_string(Path::new(env!("CARGO_MANIFEST_DIR")).join("src/install/mod.rs"))
        .unwrap();
    let calls = src.matches("self.ui.step(\"").count();
    let total: usize = src
        .lines()
        .find_map(|l| l.strip_prefix("const STEP_TOTAL: usize = "))
        .unwrap()
        .trim_end_matches(';')
        .parse()
        .unwrap();
    assert_eq!(calls, total);
}

#[test]
fn a_partial_cbm_wiring_warns_that_hooks_and_mcp_entry_are_in_place() {
    let s = Sandbox::new();
    s.add("codebase-memory-mcp");
    let r = s.run_env(
        &["install", "--yes"],
        "",
        &[("MOCK_CBM", "fail-after-wiring")],
    );
    let o = r.all();
    assert_eq!(r.code, 0, "{o}");
    assert!(
        o.contains("reported a failure while configuring Claude Code"),
        "{o}"
    );
    assert!(o.contains("cbm-config.log") && !o.contains("wired: skill"));
    assert!(s
        .read(".radin/cbm-config.log")
        .lines()
        .any(|l| l.starts_with("PARTIAL ")));
    assert_eq!(s.manifest()["cbm_agent_config"], true);
    assert!(!s.p(".radin/cbm-wired.stamp").exists());
}

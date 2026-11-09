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
    work: PathBuf,
}

fn w() -> W {
    let t = tempfile::tempdir().unwrap();
    let base = t.path().canonicalize().unwrap();
    let (home, work) = (base.join("home"), base.join("work"));
    fs::create_dir_all(&home).unwrap();
    fs::create_dir_all(&work).unwrap();
    W { _t: t, home, work }
}

fn put(p: &Path, text: &str) {
    fs::create_dir_all(p.parent().unwrap()).unwrap();
    fs::write(p, text).unwrap();
}

fn digest(p: &Path) -> String {
    format!("{:x}", Sha256::digest(fs::read(p).unwrap()))
}

fn tree(root: &Path) -> Vec<(PathBuf, String)> {
    let mut v = Vec::new();
    let mut stack = vec![root.to_path_buf()];
    while let Some(d) = stack.pop() {
        for e in fs::read_dir(d).unwrap() {
            let p = e.unwrap().path();
            if p.is_dir() {
                stack.push(p);
            } else {
                v.push((p.clone(), digest(&p)));
            }
        }
    }
    v.sort();
    v
}

impl W {
    fn p(&self, rel: &str) -> PathBuf {
        self.home.join(rel)
    }

    fn uninstall(&self, args: &[&str]) -> cli::Run {
        self.uninstall_env(args, &[])
    }

    fn uninstall_env(&self, args: &[&str], env: &[(&str, &str)]) -> cli::Run {
        let mut a = vec!["uninstall"];
        a.extend_from_slice(args);
        cli::radin_with(&self.work, &self.home, &a, "", env)
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

    fn manifest_install(&self) {
        self.install_all_expected();
        for rel in [
            ".claude/skills/radin-batch/SKILL.md",
            ".claude/skills/radin-do/SKILL.md",
            ".agents/skills/radin-batch/SKILL.md",
            ".config/opencode/agents/radin-review.md",
            ".radin/hosts/agents/lib/radin-run.md",
        ] {
            put(&self.p(rel), &format!("{rel}\n"));
        }
        let mut rels = Vec::new();
        for top in [
            ".claude/skills",
            ".agents/skills",
            ".radin",
            ".config/opencode/agents",
        ] {
            let mut stack = vec![self.p(top)];
            while let Some(d) = stack.pop() {
                for e in fs::read_dir(d).unwrap() {
                    let p = e.unwrap().path();
                    if p.is_dir() {
                        stack.push(p);
                    } else {
                        let rel = p
                            .strip_prefix(&self.home)
                            .unwrap()
                            .to_str()
                            .unwrap()
                            .to_string();
                        if !rel.starts_with(".claude/skills/thermo-nuclear/") {
                            rels.push(rel);
                        }
                    }
                }
            }
        }
        rels.sort();
        let files: Vec<String> = rels
            .iter()
            .map(|r| format!("\n    \"{r}\": \"{}\"", digest(&self.p(r))))
            .collect();
        put(
            &self.p(".radin/manifest.json"),
            &format!(
                "{{\n  \"manifest_version\": 2,\n  \"opencode_allow\": \"{}/.config/opencode/opencode.json\",\n  \"hosts\": [\"claude\", \"codex\", \"opencode\"],\n  \"agents_clis\": [\"codex\", \"opencode\"],\n  \"files\": {{{}\n  }},\n  \"backups\": {{\n  }}\n}}\n",
                self.home.display(),
                files.join(",")
            ),
        );
        put(&self.p(".radin/install_root"), "x\n");
        for f in [
            ".claude/CLAUDE.md",
            ".codex/AGENTS.md",
            ".config/opencode/AGENTS.md",
        ] {
            put(
                &self.p(f),
                "mine\n\n<!-- radin:begin -->\nradin text\n<!-- radin:end -->\n",
            );
        }
        put(
            &self.p(".config/opencode/opencode.json"),
            &format!(
                "{{\"permission\":{{\"external_directory\":{{\"{}/.radin/**\":\"allow\",\"/keep/**\":\"allow\"}}}}}}\n",
                self.home.display()
            ),
        );
    }
}

#[test]
fn leaves_thermo_nuclear_untouched() {
    let w = w();
    w.install_all_expected();
    let r = w.uninstall(&[]);
    assert_eq!(r.code, 0, "{}{}", r.out, r.err);
    assert!(w.p(".claude/skills/thermo-nuclear/SKILL.md").is_file());
    assert!(r
        .out
        .contains("  thermo-nuclear       not vendored by radin, remove manually if wanted\n"));
}

#[test]
fn leaves_the_pstack_skills_untouched() {
    let w = w();
    w.install_all_expected();
    put(&w.p(".claude/skills/unslop/SKILL.md"), "");
    let r = w.uninstall(&[]);
    assert_eq!(r.code, 0);
    assert!(w.p(".claude/skills/unslop/SKILL.md").is_file());
    assert!(r
        .out
        .contains("  unslop               fetched from cursor/plugins at install time, remove manually if wanted\n"));
}

#[test]
fn prints_removal_commands_for_advisory_tools() {
    let w = w();
    w.install_all_expected();
    let r = w.uninstall(&[]);
    assert!(r.out.contains("codebase-memory-mcp uninstall"));
    assert!(r.out.contains("claude plugin uninstall caveman@caveman"));
    assert!(r.out.contains("pipx uninstall headroom-ai"));
    assert!(r.out.contains(&format!(
        "  {}/.claude/.ponytail-band stays -- run /ponytail band on to show the band again\n",
        w.home.display()
    )));
}

#[test]
fn names_the_removal_command_of_the_recorded_package_manager() {
    let w = w();
    w.install_all_expected();
    put(
        &w.p(".radin/manifest.json"),
        "{\n  \"package_manager\": \"mise\"\n}\n",
    );
    let r = w.uninstall(&[]);
    assert_eq!(r.code, 0, "{}{}", r.out, r.err);
    assert!(r.out.contains("mise rm -g aqua:rtk-ai/rtk"));
    assert!(r.out.contains("mise rm -g pipx:headroom-ai"));
    assert!(!r.out.contains("brew uninstall rtk"));
    put(
        &w.p(".radin/manifest.json"),
        "{\n  \"package_manager\": \"brew\"\n}\n",
    );
    assert!(w
        .uninstall(&["--dry-run"])
        .out
        .contains("brew uninstall rtk"));
}

#[test]
fn a_second_run_reports_absent() {
    let w = w();
    w.install_all_expected();
    assert_eq!(w.uninstall(&[]).code, 0);
    let r = w.uninstall(&[]);
    assert_eq!(r.code, 0);
    assert!(!r.out.contains("REMOVED"));
    assert!(r.out.contains("  ABSENT   .radin/lib/companion-skills.txt\n"));
}

#[test]
fn removes_every_hosts_files_blocks_and_the_opencode_rule() {
    let w = w();
    w.manifest_install();
    let r = w.uninstall(&[]);
    assert_eq!(r.code, 0, "{}{}", r.out, r.err);
    assert!(r.out.contains("STRIPPED") && r.out.contains("radin removed."));
    assert!(!w.p(".claude/skills/radin-batch").exists());
    assert!(!w.p(".agents/skills/radin-batch").exists());
    assert!(!w.p(".config/opencode/agents/radin-review.md").exists());
    assert!(!w.p(".radin").exists());
    assert!(w.p(".claude/skills").is_dir());
    for f in [
        ".claude/CLAUDE.md",
        ".codex/AGENTS.md",
        ".config/opencode/AGENTS.md",
    ] {
        assert_eq!(fs::read_to_string(w.p(f)).unwrap(), "mine\n");
    }
    let oc = fs::read_to_string(w.p(".config/opencode/opencode.json")).unwrap();
    assert!(oc.contains("/keep/**") && !oc.contains(".radin/**"), "{oc}");
}

#[test]
fn the_permissions_step_removes_radins_read_rules_only() {
    let w = w();
    w.manifest_install();
    let rule = format!("Read(/{}/.radin/**)", w.home.display());
    put(
        &w.p(".claude/settings.json"),
        &format!("{{\"permissions\":{{\"allow\":[\"{rule}\",\"Read(/mine/**)\"]}}}}\n"),
    );
    let r = w.uninstall(&[]);
    assert_eq!(r.code, 0, "{}{}", r.out, r.err);
    let s = fs::read_to_string(w.p(".claude/settings.json")).unwrap();
    assert!(
        s.contains("Read(/mine/**)") && !s.contains(".radin/**"),
        "{s}"
    );
    put(&w.p(".claude/settings.json"), "{ not json\n");
    w.manifest_install();
    let r = w.uninstall(&[]);
    assert!(r.out.contains(
        "  SKIPPED  settings.json is not valid JSON -- remove the Read(.../.radin/**) rules by hand\n"
    ), "{}", r.out);
}

#[test]
fn keeps_an_edited_file_and_the_manifest_force_removes_them() {
    let w = w();
    w.manifest_install();
    let mut f = fs::read_to_string(w.p(".agents/skills/radin-batch/SKILL.md")).unwrap();
    f.push_str("mine\n");
    fs::write(w.p(".agents/skills/radin-batch/SKILL.md"), f).unwrap();
    let r = w.uninstall(&[]);
    assert_eq!(r.code, 0, "{}{}", r.out, r.err);
    assert!(r
        .out
        .contains("  KEPT (edited) .agents/skills/radin-batch/SKILL.md\n"));
    assert!(r.out.contains(
        "radin removed, except 1 edited file(s). Run again with --force to remove them.\n"
    ));
    assert!(w.p(".agents/skills/radin-batch/SKILL.md").is_file());
    assert!(w.p(".radin/manifest.json").is_file());
    let r = w.uninstall(&["--force"]);
    assert_eq!(r.code, 0);
    assert!(!w.p(".agents/skills/radin-batch").exists());
    assert!(!w.p(".radin").exists());
}

#[test]
fn never_removes_a_dash_digest_file_or_a_foreign_file_even_with_force() {
    let w = w();
    w.manifest_install();
    let m = fs::read_to_string(w.p(".radin/manifest.json")).unwrap();
    let key = "\".agents/skills/radin-batch/SKILL.md\": \"";
    let at = m.find(key).unwrap() + key.len();
    let end = at + m[at..].find('"').unwrap();
    fs::write(
        w.p(".radin/manifest.json"),
        format!("{}-{}", &m[..at], &m[end..]),
    )
    .unwrap();
    put(&w.p(".claude/skills/radin-batch/notes.md"), "notes\n");
    let r = w.uninstall(&["--force"]);
    assert_eq!(r.code, 0, "{}{}", r.out, r.err);
    assert!(r
        .out
        .contains("  KEPT (not radin's) .agents/skills/radin-batch/SKILL.md\n"));
    assert!(w.p(".agents/skills/radin-batch/SKILL.md").is_file());
    assert!(w.p(".claude/skills/radin-batch/notes.md").is_file());
    assert!(!w.p(".claude/skills/radin-batch/SKILL.md").exists());
    assert!(r.out.contains("  KEPT (holds other files) "));
    assert!(r.out.contains("radin-batch\n"));
}

#[test]
fn force_keeps_a_real_directory_listed_in_the_manifest() {
    let w = w();
    w.manifest_install();
    put(&w.p(".claude/skills/extra-dir/notes.md"), "n\n");
    let m = fs::read_to_string(w.p(".radin/manifest.json")).unwrap();
    fs::write(
        w.p(".radin/manifest.json"),
        m.replace(
            "\"files\": {",
            "\"files\": {\n    \".claude/skills/extra-dir\": \"abc\",",
        ),
    )
    .unwrap();
    let r = w.uninstall(&["--force"]);
    assert_eq!(r.code, 0, "{}{}", r.out, r.err);
    assert!(r.out.contains("  KEPT (edited) .claude/skills/extra-dir\n"));
    assert!(w.p(".claude/skills/extra-dir/notes.md").is_file());
}

#[test]
fn a_half_installed_host_reports_absent_and_exits_0() {
    let w = w();
    w.manifest_install();
    fs::remove_dir_all(w.p(".agents")).unwrap();
    let r = w.uninstall(&[]);
    assert_eq!(r.code, 0);
    assert!(r
        .out
        .contains("  ABSENT   .agents/skills/radin-batch/SKILL.md\n"));
}

#[test]
fn without_a_manifest_the_agents_render_stays_and_is_named() {
    let w = w();
    w.install_all_expected();
    put(&w.p(".agents/skills/radin-batch/SKILL.md"), "");
    let r = w.uninstall(&[]);
    assert_eq!(r.code, 0, "{}{}", r.out, r.err);
    assert!(w.p(".agents/skills/radin-batch/SKILL.md").is_file());
    assert!(r.out.contains(&format!(
        "  agents render, remove by hand: {}/.agents/skills/radin-batch\n",
        w.home.display()
    )));
    assert!(!w.p(".claude/skills/radin-batch").exists());
}

#[test]
fn dry_run_changes_no_byte() {
    let w = w();
    w.manifest_install();
    let before = tree(&w.home);
    let r = w.uninstall(&["--dry-run", "--force"]);
    assert_eq!(r.code, 0, "{}{}", r.out, r.err);
    assert_eq!(before, tree(&w.home));
    assert!(r.out.contains("(dry run: nothing changes)\n"));
    assert!(r
        .out
        .contains("  WOULD REMOVE .claude/skills/radin-batch/SKILL.md\n"));
    assert!(r.out.contains("  WOULD STRIP "));
    assert!(r
        .out
        .contains("  WOULD REMOVE the Read(.../.radin/**) rules\n"));
    assert!(r.out.ends_with("\nDry run done. Nothing changed.\n"));
}

#[test]
fn unbalanced_markers_leave_the_file_byte_identical() {
    let w = w();
    w.manifest_install();
    let f = w.p(".codex/AGENTS.md");
    fs::write(&f, "mine\n<!-- radin:begin -->\nno end\n").unwrap();
    let r = w.uninstall(&[]);
    assert_eq!(r.code, 0);
    assert_eq!(
        fs::read_to_string(&f).unwrap(),
        "mine\n<!-- radin:begin -->\nno end\n"
    );
    assert!(r.out.contains(&format!(
        "  KEPT (markers unbalanced) {}: delete the radin block by hand\n",
        f.display()
    )));
    w.manifest_install();
    fs::write(&f, "<!-- radin:end -->\n<!-- radin:begin -->\n").unwrap();
    assert!(w.uninstall(&[]).out.contains("KEPT (markers unbalanced)"));
}

#[test]
fn strip_keeps_interior_blank_runs_and_drops_trailing_ones() {
    let w = w();
    w.manifest_install();
    fs::write(
        w.p(".codex/AGENTS.md"),
        "a\n\n\nb\n  \t\n<!-- radin:begin -->\nx\n<!-- radin:end -->\n\n\n",
    )
    .unwrap();
    w.uninstall(&[]);
    assert_eq!(
        fs::read_to_string(w.p(".codex/AGENTS.md")).unwrap(),
        "a\n\n\nb\n"
    );
}

#[test]
fn a_symlinked_claude_md_stays_a_symlink() {
    let w = w();
    w.manifest_install();
    fs::rename(w.p(".claude/CLAUDE.md"), w.p("dotfile.md")).unwrap();
    symlink(w.p("dotfile.md"), w.p(".claude/CLAUDE.md")).unwrap();
    let r = w.uninstall(&[]);
    assert_eq!(r.code, 0);
    assert!(fs::symlink_metadata(w.p(".claude/CLAUDE.md"))
        .unwrap()
        .is_symlink());
    assert_eq!(fs::read_to_string(w.p("dotfile.md")).unwrap(), "mine\n");
}

#[test]
fn names_the_telemetry_store_and_leaves_it() {
    let w = w();
    w.install_all_expected();
    put(&w.p(".radin/telemetry/parallel.jsonl"), "");
    let r = w.uninstall(&["--dry-run"]);
    assert_eq!(r.code, 0);
    assert!(r.out.contains(&format!(
        "  {}/.radin/telemetry holds your telemetry records -- your data, your call\n",
        w.home.display()
    )));
    assert!(w.p(".radin/telemetry/parallel.jsonl").is_file());
}

#[test]
fn an_unknown_argument_exits_2() {
    let w = w();
    let r = w.uninstall(&["--nope"]);
    assert_eq!(r.code, 2);
    assert_eq!(r.err, "usage: radin uninstall [--dry-run] [--force]\n");
}

#[test]
fn an_invalid_manifest_aborts_before_any_change() {
    let w = w();
    w.install_all_expected();
    put(&w.p(".radin/manifest.json"), "{");
    let before = tree(&w.home);
    let r = w.uninstall(&[]);
    assert_eq!(r.code, 1);
    assert_eq!(
        r.err,
        "radin: ~/.radin/manifest.json is not valid JSON: fix or delete it, then re-run\n"
    );
    assert_eq!(before, tree(&w.home));
}

#[test]
fn the_symlink_in_local_bin_goes_only_when_it_points_at_radin() {
    let w = w();
    w.install_all_expected();
    fs::create_dir_all(w.p(".local/bin")).unwrap();
    symlink(w.p(".radin/bin/radin"), w.p(".local/bin/radin")).unwrap();
    let r = w.uninstall(&[]);
    assert!(r.out.contains("  REMOVED  radin (~/.local/bin symlink)\n"));
    assert!(fs::symlink_metadata(w.p(".local/bin/radin")).is_err());
    put(&w.p(".local/bin/other"), "x");
    symlink(w.p(".local/bin/other"), w.p(".local/bin/radin")).unwrap();
    w.uninstall(&[]);
    assert!(fs::symlink_metadata(w.p(".local/bin/radin")).is_ok());
}

#[test]
fn renamed_and_retired_skills_are_removed() {
    let w = w();
    w.install_all_expected();
    put(&w.p(".claude/skills/radin-execute/SKILL.md"), "");
    put(&w.p(".claude/skills/radin-show/SKILL.md"), "");
    let r = w.uninstall(&[]);
    assert!(r.out.contains("  REMOVED  .claude/skills/radin-execute\n"));
    assert!(!w.p(".claude/skills/radin-show").exists());
}

#[test]
fn pruning_stops_at_the_hosts_skills_root() {
    let w = w();
    w.manifest_install();
    fs::remove_dir_all(w.p(".claude/skills/thermo-nuclear")).unwrap();
    let r = w.uninstall(&[]);
    assert_eq!(r.code, 0, "{}{}", r.out, r.err);
    assert!(w.p(".claude/skills").is_dir());
    assert!(w.p(".agents/skills").is_dir());
    assert!(!w.p(".claude/skills/radin-batch").exists());
}

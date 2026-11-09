#[path = "common/stubs.rs"]
mod stubs;

use serde_json::Value;
use std::fs;
use std::os::unix::fs::{symlink, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::Command;
use stubs::{Sandbox, R};

const BIN: &str = env!("CARGO_BIN_EXE_radin");

fn repo() -> &'static Path {
    Path::new(env!("CARGO_MANIFEST_DIR"))
}

fn cp(from: &Path, to: &Path) {
    fs::create_dir_all(to).unwrap();
    assert!(Command::new("cp")
        .arg("-a")
        .arg(format!("{}/.", from.display()))
        .arg(to)
        .status()
        .unwrap()
        .success());
}

fn bash_era() -> Sandbox {
    let s = Sandbox::new();
    cp(&repo().join("tests/fixtures/bash-era-home"), &s.home);
    fs::create_dir_all(s.p(".local/bin")).unwrap();
    symlink(s.p(".radin/bin/radin"), s.p(".local/bin/radin")).unwrap();
    s
}

fn json(s: &Sandbox, rel: &str) -> Value {
    serde_json::from_str(&s.read(rel)).unwrap()
}

fn hook_commands(s: &Sandbox) -> Vec<String> {
    json(s, ".claude/settings.json")["hooks"]["SessionStart"][0]["hooks"]
        .as_array()
        .unwrap()
        .iter()
        .map(|h| h["command"].as_str().unwrap().to_string())
        .collect()
}

fn lib_names(s: &Sandbox) -> Vec<String> {
    let mut v: Vec<String> = fs::read_dir(s.p(".radin/lib"))
        .unwrap()
        .flatten()
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .collect();
    v.sort();
    v
}

/// Serves the repo's install.sh for the old updater's URL and a fake release installer for the new one.
fn route_curl(s: &Sandbox) {
    let body = format!(
        r#"#!/bin/sh
out=""; prev=""; url=""
for a in "$@"; do
	[ "$prev" = -o ] && out="$a"
	case "$a" in http*) url="$a" ;; esac
	prev="$a"
done
case "$url" in
*/shortcuts/radin/main/install.sh) cp "{install}" "$out"; exit 0 ;;
*/radin-installer.sh)
	cat >"$out" <<'EOS'
mkdir -p "$HOME/.cargo/bin"
if [ -n "${{RADIN_TEST_BIN:-}}" ]; then
	cp "$RADIN_TEST_BIN" "$HOME/.cargo/bin/radin"
else
	printf '#!/bin/sh\necho "$*" >>"$MOCK_LOG_DIR/fake-radin.log"\n' >"$HOME/.cargo/bin/radin"
	chmod +x "$HOME/.cargo/bin/radin"
fi
EOS
	exit 0 ;;
esac
STUB_NAME=curl exec "$MOCK_BIN/.stub" "$@"
"#,
        install = repo().join("install.sh").display()
    );
    let p = s.bin.join("curl");
    let _ = fs::remove_file(&p);
    fs::write(&p, body).unwrap();
    fs::set_permissions(&p, fs::Permissions::from_mode(0o755)).unwrap();
}

fn update_hosts(s: &Sandbox) -> R {
    s.install(&["--update", "--yes"])
}

#[test]
fn update_on_a_bash_era_install_removes_orphans_swaps_the_dispatcher_and_keeps_the_link() {
    let s = bash_era();
    assert!(fs::read(s.p(".radin/bin/radin"))
        .unwrap()
        .starts_with(b"#!"));
    let m = json(&s, ".radin/manifest.json");
    assert_eq!(m["manifest_version"], 2);
    assert!(m["lib"]
        .as_array()
        .unwrap()
        .iter()
        .any(|v| v == "radin-update.sh"));
    let r = update_hosts(&s);
    let o = r.all();
    assert_eq!(r.code, 0, "{o}");
    for n in [
        "radin-update.sh",
        "radin-backlog.sh",
        "radin-tui.c",
        "radin-cbm-json.c",
        "radin-doctor.sh",
    ] {
        assert!(
            o.contains(&format!(
                "removed {}",
                s.p(&format!(".radin/lib/{n}")).display()
            )),
            "{n}\n{o}"
        );
    }
    assert_eq!(
        lib_names(&s),
        [
            "companion-skills.txt",
            "forbid-agents.txt",
            "forbid-claude.txt",
            "skill-names-agents.txt",
            "skill-names-claude.txt"
        ]
    );
    for f in [
        "radin-tui",
        "radin-cbm-json",
        ".radin-tui.sum",
        ".radin-cbm-json.sum",
    ] {
        assert!(!s.p(&format!(".radin/bin/{f}")).exists(), "{f}");
    }
    assert!(!fs::read(s.p(".radin/bin/radin"))
        .unwrap()
        .starts_with(b"#!"));
    assert_eq!(
        fs::read_link(s.p(".local/bin/radin")).unwrap(),
        s.p(".radin/bin/radin")
    );
    let m = json(&s, ".radin/manifest.json");
    assert!(!m["lib"]
        .as_array()
        .unwrap()
        .iter()
        .any(|v| v == "radin-update.sh"));
    assert_eq!(m["install_root"], s.p(".radin").to_str().unwrap());
    assert_eq!(m["cli_on_path"], true);
}

#[test]
fn update_rewrites_a_hook_that_runs_a_removed_script_and_warns_about_an_unmapped_one() {
    let s = bash_era();
    let r = update_hosts(&s);
    let o = r.all();
    assert_eq!(r.code, 0, "{o}");
    let doctor = format!("{}/.radin/bin/radin doctor", s.home.display());
    assert_eq!(
        hook_commands(&s),
        [
            doctor.as_str(),
            "$HOME/.radin/lib/radin-nope.sh",
            "echo foreign"
        ]
    );
    assert!(
        o.contains("hook $HOME/.radin/lib/radin-nope.sh still names a removed script"),
        "{o}"
    );
}

#[test]
fn a_settings_file_with_no_matching_hook_keeps_its_hooks_byte_for_byte() {
    let s = bash_era();
    let plain = "{\n  \"hooks\": {\n    \"SessionStart\": [\n      {\n        \"hooks\": [\n          {\n            \"type\": \"command\",\n            \"command\": \"echo foreign\"\n          }\n        ]\n      }\n    ]\n  }\n}\n";
    s.put(".claude/settings.json", plain);
    let r = update_hosts(&s);
    assert_eq!(r.code, 0, "{}", r.all());
    let after = json(&s, ".claude/settings.json");
    assert_eq!(
        after["hooks"],
        serde_json::from_str::<Value>(plain).unwrap()["hooks"]
    );
    assert!(!r.all().contains("hook echo foreign"));
}

#[test]
fn doctor_is_clean_after_the_upgrade_and_a_second_update_changes_no_byte() {
    let s = bash_era();
    assert_eq!(update_hosts(&s).code, 0);
    let mut j = json(&s, ".claude/settings.json");
    j["hooks"]["SessionStart"][0]["hooks"]
        .as_array_mut()
        .unwrap()
        .retain(|h| !h["command"].as_str().unwrap().contains("nope"));
    s.put(
        ".claude/settings.json",
        &serde_json::to_string_pretty(&j).unwrap(),
    );
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
    let r = update_hosts(&s);
    assert_eq!(r.code, 0, "{}", r.all());
    assert!(!r.all().contains("removed "));
    assert_eq!(before, stable(&s));
}

fn seed_old_layout(s: &Sandbox, real: Option<&Path>) {
    let real_dir = match real {
        Some(r) => {
            fs::create_dir_all(r).unwrap();
            symlink(r, s.p(".claude")).unwrap();
            r.to_path_buf()
        }
        None => s.p(".claude"),
    };
    let old = real_dir.join(".radin");
    for d in ["lib", "bin", "backups/snap"] {
        fs::create_dir_all(old.join(d)).unwrap();
    }
    fs::create_dir_all(s.p(".local/bin")).unwrap();
    fs::write(
        old.join("manifest.json"),
        "{\"installed_at\": \"2026-01-01T00:00:00Z\", \"companion_tools\": {}}\n",
    )
    .unwrap();
    fs::write(old.join("lib/radin-run.md"), "stale\n").unwrap();
    fs::write(old.join("lib/radin-tui.sh"), "stale\n").unwrap();
    fs::write(old.join("backups/snap/settings.json"), "sentinel\n").unwrap();
    fs::write(old.join("bin/radin"), "#!/bin/sh\n").unwrap();
    fs::set_permissions(old.join("bin/radin"), fs::Permissions::from_mode(0o755)).unwrap();
    symlink(old.join("bin/radin"), s.p(".local/bin/radin")).unwrap();
    let real_s = fs::canonicalize(&real_dir).unwrap();
    let rules = format!(
        "{{\"permissions\": {{\"allow\": [\"Read(//x/**)\", \"Read(/{}/.claude/.radin/**)\", \"Read(/{}/.radin/**)\"]}}}}\n",
        s.home.display(),
        real_s.display()
    );
    fs::write(real_dir.join("settings.json"), rules).unwrap();
}

fn assert_migrated(s: &Sandbox) {
    assert!(!s.p(".claude/.radin").exists());
    assert_eq!(s.read(".radin/backups/snap/settings.json"), "sentinel\n");
    assert!(!s.p(".radin/lib/radin-run.md").exists() && !s.p(".radin/lib/radin-tui.sh").exists());
    assert!(s.p(".radin/hosts/claude/lib/radin-run.md").is_file());
    assert_eq!(
        fs::read_link(s.p(".local/bin/radin")).unwrap(),
        s.p(".radin/bin/radin")
    );
    let st = s.read(".claude/settings.json");
    assert!(st.contains(&format!("Read(/{}/.radin/**)", s.home.display())));
    assert!(st.contains("Read(//x/**)"));
    assert!(!st.contains("/.claude/.radin"), "{st}");
}

#[test]
fn migrating_from_the_old_home_moves_it_relinks_and_swaps_the_read_rules() {
    let s = Sandbox::new();
    seed_old_layout(&s, None);
    let r = s.install(&["--yes"]);
    assert_eq!(r.code, 0, "{}", r.all());
    assert!(r.all().contains("restart open Claude sessions"));
    assert_migrated(&s);
    assert_eq!(s.manifest()["cli_on_path"], true);
}

#[test]
fn migrating_works_when_dot_claude_is_a_symlink() {
    let s = Sandbox::new();
    let elsewhere = s.home.parent().unwrap().join("elsewhere");
    seed_old_layout(&s, Some(&elsewhere));
    let r = s.install(&["--yes"]);
    assert_eq!(r.code, 0, "{}", r.all());
    assert_migrated(&s);
    assert!(elsewhere.join("skills/radin-batch/SKILL.md").is_file());
}

#[test]
fn a_half_migrated_machine_keeps_the_old_directory_says_so_and_drops_the_old_read_rules() {
    let s = Sandbox::new();
    seed_old_layout(&s, None);
    fs::create_dir_all(s.p(".radin")).unwrap();
    fs::copy(
        s.p(".claude/.radin/manifest.json"),
        s.p(".radin/manifest.json"),
    )
    .unwrap();
    let r = s.install(&["--yes"]);
    let o = r.all();
    assert_eq!(r.code, 0, "{o}");
    assert!(o.contains("is still there, unused") && !o.contains("restart open Claude sessions"));
    assert_eq!(
        s.read(".claude/.radin/backups/snap/settings.json"),
        "sentinel\n"
    );
    let st = s.read(".claude/settings.json");
    assert!(!st.contains("/.claude/.radin"));
    assert!(st.contains(&format!("Read(/{}/.radin/**)", s.home.display())));
}

#[test]
fn a_foreign_radin_home_aborts_before_any_write() {
    let s = Sandbox::new();
    seed_old_layout(&s, None);
    s.put(".radin/notes.txt", "mine\n");
    let before = s.tree();
    let r = s.install(&["--yes"]);
    assert_eq!(r.code, 1);
    assert!(
        r.all()
            .contains("is not radin's: move it away, then re-run."),
        "{}",
        r.all()
    );
    assert_eq!(before, s.tree());
}

#[test]
fn a_failed_move_or_a_leftover_staging_directory_leaves_the_old_directory_intact() {
    let s = Sandbox::new();
    seed_old_layout(&s, None);
    fs::set_permissions(&s.home, fs::Permissions::from_mode(0o555)).unwrap();
    let r = s.install(&["--yes"]);
    fs::set_permissions(&s.home, fs::Permissions::from_mode(0o755)).unwrap();
    assert_ne!(r.code, 0);
    assert!(r.all().contains("mv failed"), "{}", r.all());
    assert!(s.p(".claude/.radin/manifest.json").is_file() && !s.p(".radin").exists());
    assert!(!s.p(".claude/skills/radin-batch").exists());
    fs::create_dir_all(s.p(".radin.migrating")).unwrap();
    let r = s.install(&["--yes"]);
    assert_ne!(r.code, 0);
    assert!(
        r.all().contains(&format!(
            "{} was left by an interrupted move",
            s.p(".radin.migrating").display()
        )),
        "{}",
        r.all()
    );
    assert!(s.p(".claude/.radin/manifest.json").is_file() && !s.p(".radin").exists());
}

#[test]
fn a_link_to_the_legacy_dispatcher_is_relinked() {
    let s = Sandbox::new();
    fs::create_dir_all(s.p(".local/bin")).unwrap();
    symlink(s.p(".claude/.radin/bin/radin"), s.p(".local/bin/radin")).unwrap();
    let r = s.install(&["--yes"]);
    assert_eq!(r.code, 0, "{}", r.all());
    assert_eq!(
        fs::read_link(s.p(".local/bin/radin")).unwrap(),
        s.p(".radin/bin/radin")
    );
    assert_eq!(s.manifest()["cli_on_path"], true);
}

#[test]
fn the_install_sh_stub_runs_the_release_installer_then_radin_install_with_the_same_flags() {
    let s = Sandbox::new();
    route_curl(&s);
    let r = s
        .command_of(
            "sh",
            &[
                repo().join("install.sh").to_str().unwrap(),
                "--update",
                "--yes",
            ],
            &[],
        )
        .output()
        .unwrap();
    assert!(r.status.success(), "{}", String::from_utf8_lossy(&r.stderr));
    assert_eq!(s.log("fake-radin").trim(), "install --update --yes");
}

#[test]
fn the_install_sh_stub_exits_one_with_one_line_when_the_download_fails() {
    let s = Sandbox::new();
    let r = s
        .command_of(
            "sh",
            &[repo().join("install.sh").to_str().unwrap()],
            &[("MOCK_CURL_FAIL", "radin-installer")],
        )
        .output()
        .unwrap();
    assert_eq!(r.status.code(), Some(1));
    let err = String::from_utf8_lossy(&r.stderr);
    assert_eq!(err.lines().count(), 1, "{err}");
    assert!(err.contains("could not download"));
}

#[test]
fn the_old_updater_of_a_bash_era_install_reaches_the_rust_binary_through_the_stub() {
    let s = bash_era();
    route_curl(&s);
    let upd = s.p(".radin/lib/radin-update.sh");
    let r = s
        .command_of(
            "bash",
            &[upd.to_str().unwrap(), "--yes"],
            &[("RADIN_TEST_BIN", BIN)],
        )
        .output()
        .unwrap();
    let o = format!(
        "{}{}",
        String::from_utf8_lossy(&r.stdout),
        String::from_utf8_lossy(&r.stderr)
    );
    assert!(r.status.success(), "{o}");
    assert!(!fs::read(s.p(".radin/bin/radin"))
        .unwrap()
        .starts_with(b"#!"));
    assert!(!s.p(".radin/lib/radin-update.sh").exists());
    assert_eq!(
        json(&s, ".radin/manifest.json")["install_root"],
        s.p(".radin").to_str().unwrap()
    );
    assert!(o.contains("radin updated in"), "{o}");
}

#[test]
fn a_pre_radin_home_updater_reaches_the_migrating_install_through_a_clone_and_the_stub() {
    let s = Sandbox::new();
    route_curl(&s);
    seed_old_layout(&s, None);
    fs::copy(
        repo().join("tests/fixtures/radin-update-legacy.sh"),
        s.p(".claude/.radin/lib/radin-update.sh"),
    )
    .unwrap();
    let (upstream, clone): (PathBuf, PathBuf) = (s.p("upstream"), s.p("clone"));
    let git = |dir: &Path, args: &[&str]| {
        let o = Command::new("git")
            .args(["-c", "user.name=t", "-c", "user.email=t@t"])
            .args(args)
            .current_dir(dir)
            .output()
            .unwrap();
        assert!(
            o.status.success(),
            "{args:?}: {}",
            String::from_utf8_lossy(&o.stderr)
        );
    };
    fs::create_dir_all(&upstream).unwrap();
    git(&upstream, &["init", "-q", "--bare"]);
    fs::create_dir_all(&clone).unwrap();
    git(&clone, &["init", "-q"]);
    fs::write(
        clone.join("install.sh"),
        format!(
            "#!/bin/sh\nexec sh \"{}/install.sh\" \"$@\"\n",
            repo().display()
        ),
    )
    .unwrap();
    git(&clone, &["add", "install.sh"]);
    git(&clone, &["commit", "-qm", "init"]);
    git(
        &clone,
        &["remote", "add", "origin", upstream.to_str().unwrap()],
    );
    git(&clone, &["push", "-q", "-u", "origin", "HEAD:main"]);
    fs::write(
        s.p(".claude/.radin/install_root"),
        format!("{}\n", clone.display()),
    )
    .unwrap();
    let legacy = s.p(".claude/.radin/lib/radin-update.sh");
    let r = s
        .command_of(
            "bash",
            &[legacy.to_str().unwrap(), "--yes"],
            &[("RADIN_TEST_BIN", BIN)],
        )
        .output()
        .unwrap();
    let o = format!(
        "{}{}",
        String::from_utf8_lossy(&r.stdout),
        String::from_utf8_lossy(&r.stderr)
    );
    assert!(r.status.success(), "{o}");
    assert!(!s.p(".claude/.radin").exists());
    assert!(s.read(".radin/manifest.json").contains("\"installed_at\""));
}

#[test]
fn radin_update_downloads_the_installer_then_runs_the_new_binary_in_update_mode() {
    let s = Sandbox::new();
    route_curl(&s);
    let r = s.run_env(&["update", "--yes"], "", &[]);
    assert_eq!(r.code, 0, "{}", r.all());
    assert_eq!(s.log("fake-radin").trim(), "install --update --yes");
}

#[test]
fn radin_update_exits_one_without_curl_or_when_the_download_fails() {
    let s = Sandbox::new();
    route_curl(&s);
    let empty = s.home.parent().unwrap().join("empty");
    fs::create_dir_all(&empty).unwrap();
    let r = s.run_env(&["update"], "", &[("PATH", empty.to_str().unwrap())]);
    assert_eq!(r.code, 1);
    assert!(r.err.contains("curl not found"), "{}", r.err);
    let r = s.run_env(
        &["update"],
        "",
        &[
            ("MOCK_CURL_FAIL", "fail.sh"),
            ("RADIN_INSTALLER_URL", "https://x/fail.sh"),
        ],
    );
    assert_eq!(r.code, 1);
    assert!(
        r.err.contains("could not download https://x/fail.sh"),
        "{}",
        r.err
    );
    assert!(s.log("fake-radin").is_empty());
}

#[path = "common/stubs.rs"]
mod stubs;

use std::fs;
use std::os::unix::fs::{symlink, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::Command;
use stubs::Sandbox;

const BIN: &str = env!("CARGO_BIN_EXE_radin");

fn repo() -> &'static Path {
    Path::new(env!("CARGO_MANIFEST_DIR"))
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

#[path = "common/cli.rs"]
mod cli;
mod common;

use std::fs;
use std::path::{Path, PathBuf};

const AFTER_SETTINGS: &str = r#"{"hooks": {"SessionStart": [{"matcher": "", "hooks": [{"type": "command", "command": "cbm-session-reminder"}]}]}}"#;
const AFTER_CLAUDE: &str =
    r#"{"mcpServers": {"codebase-memory-mcp": {"command": "codebase-memory-mcp"}}}"#;
const CAVEMAN: &str = r#"{"hooks": {"SessionStart": [{"matcher": "", "hooks": [{"type": "command", "command": "caveman-session"}]}]}}"#;

struct W {
    _t: tempfile::TempDir,
    home: PathBuf,
    bin: PathBuf,
}

fn w() -> W {
    let t = tempfile::tempdir().unwrap();
    let home = t.path().canonicalize().unwrap();
    let bin = home.join("mockbin");
    fs::create_dir_all(&bin).unwrap();
    fs::create_dir_all(home.join(".claude")).unwrap();
    W { _t: t, home, bin }
}

fn commands(path: &Path) -> Vec<String> {
    let t = fs::read_to_string(path).unwrap();
    t.split("\"command\": \"")
        .skip(1)
        .map(|s| s.split('"').next().unwrap().to_string())
        .collect()
}

impl W {
    fn settings(&self) -> PathBuf {
        self.home.join(".claude/settings.json")
    }
    fn claude_json(&self) -> PathBuf {
        self.home.join(".claude.json")
    }
    fn write(&self, p: &Path, text: &str) {
        fs::create_dir_all(p.parent().unwrap()).unwrap();
        fs::write(p, format!("{text}\n")).unwrap();
    }
    fn after(&self, settings: &str, claude: &str) {
        self.write(&self.bin.join("after-settings.json"), settings);
        self.write(&self.bin.join("after-claude.json"), claude);
    }
    /// Upstream's #1200 write: replaces both files wholesale.
    fn stub_cbm(&self, settings: &str, claude: &str) {
        self.after(settings, claude);
        cli::stub(
            &self.bin,
            "codebase-memory-mcp",
            r#"[ "$1" = "install" ] || exit 0
cp "$MOCK_AFTER/after-settings.json" "$HOME/.claude/settings.json"
cp "$MOCK_AFTER/after-claude.json" "$HOME/.claude.json"
"#,
        );
    }
    fn stub_default(&self) {
        self.stub_cbm(AFTER_SETTINGS, AFTER_CLAUDE);
    }
    fn radin(&self, args: &[&str], env: &[(&str, &str)]) -> cli::Run {
        let path = format!("{}:/usr/bin:/bin:/usr/sbin:/sbin", self.bin.display());
        let mock = self.bin.to_string_lossy().into_owned();
        let mut e = vec![("PATH", path.as_str()), ("MOCK_AFTER", mock.as_str())];
        e.extend_from_slice(env);
        cli::radin_with(&self.home, &self.home, args, "", &e)
    }
    fn wire(&self) -> cli::Run {
        self.radin(&["wire"], &[])
    }
    fn backups(&self, prefix: &str) -> Vec<PathBuf> {
        let mut v: Vec<_> = fs::read_dir(self.home.join(".radin/backups"))
            .unwrap()
            .flatten()
            .map(|e| e.path())
            .filter(|p| p.file_name().unwrap().to_string_lossy().starts_with(prefix))
            .collect();
        v.sort();
        v
    }
}

fn read(p: &Path) -> String {
    fs::read_to_string(p).unwrap()
}

#[test]
fn wire_passes_shell_bin_sh_so_upstreams_path_step_does_not_fail() {
    let t = w();
    t.after(AFTER_SETTINGS, AFTER_CLAUDE);
    cli::stub(
        &t.bin,
        "codebase-memory-mcp",
        r#"[ "$1" = "install" ] || exit 0
cp "$MOCK_AFTER/after-settings.json" "$HOME/.claude/settings.json"
cp "$MOCK_AFTER/after-claude.json" "$HOME/.claude.json"
[ "$SHELL" = "/bin/sh" ] || exit 1
"#,
    );
    t.write(&t.settings(), CAVEMAN);
    let r = t.radin(&["wire"], &[("SHELL", "/opt/homebrew/bin/fish")]);
    assert_eq!(r.code, 0, "{}", r.err);
    assert!(r
        .out
        .contains("CONFIGURED codebase-memory-mcp install -y\n"));
    assert!(!r.err.contains("PARTIAL"));
}

#[test]
fn wire_fails_without_the_binary() {
    let t = w();
    let r = t.wire();
    assert_eq!(r.code, 1);
    assert_eq!(
        r.err,
        "radin-cbm-config: codebase-memory-mcp not found on PATH or in ~/.local/bin -- run radin's install.sh first\n"
    );
}

#[test]
fn wire_restores_replaced_session_start_hooks_keeping_upstreams() {
    let t = w();
    t.stub_cbm(
        r#"{"hooks": {"SessionStart": [{"matcher": "", "hooks": [{"type": "command", "command": "cbm-session-reminder"}]}], "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "mine"}]}, {"matcher": "Grep|Glob", "hooks": [{"type": "command", "command": "cbm-hook-augment"}]}]}}"#,
        AFTER_CLAUDE,
    );
    t.write(
        &t.settings(),
        r#"{"model": "opus",
 "hooks": {"SessionStart": [{"matcher": "", "hooks": [{"type": "command", "command": "caveman-session"}]},
                            {"matcher": "compact", "hooks": [{"type": "command", "command": "ponytail-session"}]}],
           "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "mine"}]}]}}"#,
    );
    let r = t.wire();
    assert_eq!(r.code, 0, "{}", r.err);
    assert!(r.out.contains("RESTORED") && r.out.contains("SessionStart"));
    assert_eq!(
        commands(&t.settings()),
        [
            "caveman-session",
            "ponytail-session",
            "cbm-session-reminder",
            "mine",
            "cbm-hook-augment"
        ]
    );
}

#[test]
fn wire_does_not_resurrect_upstreams_stale_hook_entries() {
    let t = w();
    t.stub_default();
    t.write(
        &t.settings(),
        r#"{"hooks": {"SessionStart": [{"matcher": "startup", "hooks": [{"type": "command", "command": "'/gone/.config/.claude/hooks/cbm-session-reminder'"}]},
                            {"matcher": "startup", "hooks": [{"type": "command", "command": "cbm-hook-augment --old-spelling"}]},
                            {"matcher": "", "hooks": [{"type": "command", "command": "caveman-session"}]}]}}"#,
    );
    assert_eq!(t.wire().code, 0);
    assert_eq!(
        commands(&t.settings()),
        ["caveman-session", "cbm-session-reminder"]
    );
}

#[test]
fn wire_prunes_hook_entries_whose_command_path_does_not_exist() {
    let t = w();
    let live = t.home.join("live-hook");
    cli::stub(&t.home, "live-hook", "");
    let hooks = format!(
        r#"{{"hooks": {{"PreToolUse": [{{"matcher": "Grep|Glob", "hooks": [{{"type": "command", "command": "'/gone/.config/.claude/hooks/cbm-code-discovery-gate'"}}]}},
                          {{"matcher": "Bash", "hooks": [{{"type": "command", "command": "/gone/other-tool-hook"}}]}},
                          {{"matcher": "Bash", "hooks": [{{"type": "command", "command": "{live}"}}]}},
                          {{"matcher": "Write", "hooks": [{{"type": "command", "command": "bare-shim-not-on-path"}}]}}"#,
        live = live.display()
    );
    t.stub_cbm(
        &format!(
            r#"{hooks},
                          {{"matcher": "Grep|Glob", "hooks": [{{"type": "command", "command": "cbm-hook-augment"}}]}}],
           "SessionStart": [{{"matcher": "", "hooks": [{{"type": "command", "command": "cbm-session-reminder"}}]}}]}}}}"#
        ),
        AFTER_CLAUDE,
    );
    t.write(&t.settings(), &format!("{hooks}]}}}}"));
    let r = t.wire();
    assert_eq!(r.code, 0, "{}", r.err);
    assert!(r.out.contains("PRUNED") && r.out.contains("cbm-code-discovery-gate"));
    assert!(r.out.contains("other-tool-hook"));
    assert_eq!(
        commands(&t.settings()),
        [
            live.to_str().unwrap(),
            "bare-shim-not-on-path",
            "cbm-hook-augment",
            "cbm-session-reminder"
        ]
    );
}

#[test]
fn wire_prunes_a_dead_hook_wrapped_in_sh() {
    let t = w();
    t.stub_cbm(
        r#"{"hooks": {"SessionStart": [{"matcher": "startup", "hooks": [{"type": "command", "command": "sh /Users/someone-else/.claude/hooks/cbm-session-reminder"}]},
                            {"matcher": "startup", "hooks": [{"type": "command", "command": "cbm-session-reminder"}]}]}}"#,
        AFTER_CLAUDE,
    );
    t.write(&t.settings(), "{}");
    let r = t.wire();
    assert_eq!(r.code, 0);
    assert!(r.out.contains("PRUNED") && r.out.contains("someone-else"));
    assert_eq!(commands(&t.settings()), ["cbm-session-reminder"]);
}

#[test]
fn wire_stashes_upstreams_hook_scripts_and_keeps_the_users() {
    let t = w();
    t.stub_default();
    let hooks = t.home.join(".claude/hooks");
    fs::create_dir_all(&hooks).unwrap();
    fs::write(
        hooks.join("cbm-session-reminder"),
        "BIN='/Users/someone-else/.local/bin/codebase-memory-mcp'\n",
    )
    .unwrap();
    fs::write(hooks.join("my-own-hook.sh"), "mine\n").unwrap();
    t.write(&t.settings(), "{}");
    let r = t.wire();
    assert_eq!(r.code, 0, "{}", r.err);
    let stash = t.backups("hooks.");
    assert_eq!(stash.len(), 1);
    assert!(r.out.contains(&format!(
        "STASHED  {}/cbm-session-reminder -> {}/ (upstream rewrites it for this machine)\n",
        hooks.display(),
        stash[0].display()
    )));
    assert!(!hooks.join("cbm-session-reminder").exists());
    assert!(hooks.join("my-own-hook.sh").is_file());
    assert!(read(&stash[0].join("cbm-session-reminder")).contains("someone-else"));
}

#[test]
fn wire_keeps_unrelated_keys_and_reports_the_graph_is_wired() {
    let t = w();
    t.stub_default();
    t.write(&t.settings(), r#"{"model": "opus", "env": {"A": "1"}}"#);
    let r = t.wire();
    assert_eq!(r.code, 0);
    let s = read(&t.settings());
    assert!(s.contains("\"model\": \"opus\"") && s.contains("\"A\": \"1\""));
    assert!(r
        .out
        .contains("CBM      hooks: present, user-scope MCP entry: present\n"));
}

#[test]
fn wire_raises_cbm_hook_timeouts_and_sets_a_deadline_keeping_the_users() {
    let t = w();
    t.stub_cbm(
        r#"{"hooks": {"SessionStart": [{"matcher": "", "hooks": [{"type": "command", "command": "cbm-session-reminder", "timeout": 5}]}], "PostToolUse": [{"matcher": "Read", "hooks": [{"type": "command", "command": "cbm-hook-augment", "timeout": 20}, {"type": "command", "command": "other-tool", "timeout": 5}]}]}}"#,
        AFTER_CLAUDE,
    );
    t.write(&t.settings(), r#"{"env": {"A": "1"}}"#);
    assert_eq!(t.wire().code, 0);
    let s = read(&t.settings());
    assert_eq!(s.matches("\"timeout\": 10").count(), 1);
    assert_eq!(s.matches("\"timeout\": 20").count(), 1);
    assert_eq!(s.matches("\"timeout\": 5").count(), 1);
    assert!(s.contains("\"CBM_HOOK_DEADLINE_MS\": \"8000\"") && s.contains("\"A\": \"1\""));
    t.write(
        &t.settings(),
        r#"{"env": {"CBM_HOOK_DEADLINE_MS": "3000"}}"#,
    );
    assert_eq!(t.wire().code, 0);
    let s = read(&t.settings());
    assert!(s.contains("\"CBM_HOOK_DEADLINE_MS\": \"3000\""));
    assert_eq!(s.matches("CBM_HOOK_DEADLINE_MS").count(), 1);
}

#[test]
fn wire_restores_an_mcp_servers_entry_upstream_dropped() {
    let t = w();
    t.stub_default();
    t.write(
        &t.claude_json(),
        r#"{"mcpServers": {"other": {"command": "x"}}}"#,
    );
    let r = t.wire();
    assert_eq!(r.code, 0);
    assert!(r.out.contains("RESTORED") && r.out.contains("mcpServers.other"));
    let j = read(&t.claude_json());
    assert!(j.contains("\"other\"") && j.contains("\"codebase-memory-mcp\""));
}

#[test]
fn wire_twice_reports_intact_and_changes_nothing() {
    let t = w();
    t.stub_default();
    t.write(&t.settings(), CAVEMAN);
    assert_eq!(t.wire().code, 0);
    let before = read(&t.settings());
    let r = t.wire();
    assert_eq!(r.code, 0);
    assert!(r.out.contains("INTACT"));
    assert_eq!(read(&t.settings()), before);
}

#[test]
fn snapshots_land_in_radin_backups_and_are_never_removed() {
    let t = w();
    t.stub_default();
    t.write(&t.settings(), r#"{"model": "opus"}"#);
    let r = t.wire();
    assert_eq!(r.code, 0);
    let snaps = t.backups("settings.json.");
    assert_eq!(snaps.len(), 1);
    assert!(read(&snaps[0]).contains("\"model\": \"opus\""));
    assert!(r
        .out
        .contains(&format!("SNAPSHOT {}\n", snaps[0].display())));
    assert!(r.out.contains(&format!(
        "ABSENT   {} (nothing to snapshot)\n",
        t.claude_json().display()
    )));
    assert_eq!(t.wire().code, 0);
    assert!(!t.backups("settings.json.").is_empty());
}

#[test]
fn a_failed_upstream_install_still_restores_from_the_snapshot() {
    let t = w();
    cli::stub(
        &t.bin,
        "codebase-memory-mcp",
        r#"[ "$1" = "install" ] || exit 0
printf '%s\n' '{"hooks": {"SessionStart": []}}' > "$HOME/.claude/settings.json"
echo "boom" >&2
exit 1
"#,
    );
    t.write(&t.settings(), CAVEMAN);
    let r = t.wire();
    assert_eq!(r.code, 1);
    assert!(r.err.starts_with(
        "boom\nFAILED   codebase-memory-mcp install -- restoring from the snapshot anyway\n"
    ));
    assert!(read(&t.settings()).contains("caveman-session"));
}

#[test]
fn repair_works_off_the_newest_snapshot_after_an_update() {
    let t = w();
    t.stub_default();
    t.write(&t.settings(), CAVEMAN);
    assert_eq!(t.wire().code, 0);
    t.write(&t.settings(), AFTER_SETTINGS);
    let r = t.radin(&["repair"], &[]);
    assert_eq!(r.code, 0);
    assert!(r.out.contains("FROM     "));
    assert!(r.out.contains("RESTORED"));
    assert!(read(&t.settings()).contains("caveman-session"));
}

#[test]
fn repair_without_a_snapshot_fails_instead_of_guessing() {
    let t = w();
    let r = t.radin(&["repair"], &[]);
    assert_eq!(r.code, 1);
    assert_eq!(
        r.err,
        format!(
            "radin-cbm-config: no snapshot in {}/.radin/backups -- nothing to repair from\n",
            t.home.display()
        )
    );
}

#[test]
fn repair_refuses_invalid_json_leaving_the_snapshot_in_place() {
    let t = w();
    t.stub_default();
    t.write(&t.settings(), r#"{"model": "opus"}"#);
    assert_eq!(t.wire().code, 0);
    fs::write(t.settings(), "not json").unwrap();
    let r = t.radin(&["repair"], &[]);
    assert_ne!(r.code, 0);
    assert_eq!(read(&t.settings()), "not json");
    assert!(read(&t.backups("settings.json.")[0]).contains("\"model\": \"opus\""));
}

#[test]
fn wire_passes_the_resolved_path_for_a_symlinked_claude_and_adopts_the_staged_entry() {
    let t = w();
    t.after(
        r#"{"hooks": {"SessionStart": [{"matcher": "", "hooks": [{"type": "command", "command": "caveman-session"}]}], "PreToolUse": [{"matcher": "Grep|Glob", "hooks": [{"type": "command", "command": "cbm-hook-augment"}]}]}}"#,
        AFTER_CLAUDE,
    );
    cli::stub(
        &t.bin,
        "codebase-memory-mcp",
        r#"[ "$1" = "install" ] || exit 0
cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
if [ -L "$cfg" ]; then printf 'Detected agents: Shell\n'; exit 0; fi
cp "$MOCK_AFTER/after-settings.json" "$cfg/settings.json"
if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then cp "$MOCK_AFTER/after-claude.json" "$cfg/.claude.json"
else cp "$MOCK_AFTER/after-claude.json" "$HOME/.claude.json"; fi
"#,
    );
    fs::remove_dir_all(t.home.join(".claude")).unwrap();
    let real = t.home.join(".config/.claude");
    fs::create_dir_all(&real).unwrap();
    std::os::unix::fs::symlink(&real, t.home.join(".claude")).unwrap();
    t.write(&real.join("settings.json"), CAVEMAN);
    t.write(
        &t.claude_json(),
        r#"{"mcpServers": {"fff": {"command": "fff"}}}"#,
    );
    let r = t.wire();
    assert_eq!(r.code, 0, "{}", r.err);
    assert!(r.out.contains(&format!(
        "SYMLINK  {} resolves to {} -- passing it as CLAUDE_CONFIG_DIR (#1722)\n",
        t.home.join(".claude").display(),
        real.display()
    )));
    assert!(r.out.contains("ADOPTED"));
    assert!(r.out.contains("hooks: present") && r.out.contains("MCP entry: present"));
    let j = read(&t.claude_json());
    assert!(j.contains("\"fff\"") && j.contains("\"codebase-memory-mcp\""));
    assert_eq!(
        commands(&real.join("settings.json")),
        ["caveman-session", "cbm-hook-augment"]
    );
}

#[test]
fn wire_succeeds_when_upstream_fails_after_configuring_claude_code() {
    let t = w();
    t.stub_cbm(
        r#"{"hooks": {"SessionStart": [{"matcher": "", "hooks": [{"type": "command", "command": "caveman-session"}]}, {"matcher": "", "hooks": [{"type": "command", "command": "cbm-session-reminder"}]}]}}"#,
        AFTER_CLAUDE,
    );
    let p = t.bin.join("codebase-memory-mcp");
    let mut s = read(&p);
    s.push_str("printf 'error: activation could not reserve exclusive access\\n' >&2\nexit 1\n");
    fs::write(&p, s).unwrap();
    t.write(&t.settings(), CAVEMAN);
    t.write(&t.claude_json(), r#"{"mcpServers": {}}"#);
    let r = t.wire();
    assert_eq!(r.code, 0, "{}", r.err);
    assert!(r.err.contains("FAILED   codebase-memory-mcp install"));
    assert!(r.err.contains("PARTIAL  codebase-memory-mcp reported a failure after configuring Claude Code -- hooks and MCP entry are in place\n"));
    assert!(r.out.contains("hooks: present"));
}

#[test]
fn wire_fails_when_upstream_exits_0_having_configured_nothing() {
    let t = w();
    cli::stub(&t.bin, "codebase-memory-mcp", "exit 0\n");
    t.write(&t.settings(), r#"{"hooks": {}}"#);
    let r = t.wire();
    assert_eq!(r.code, 1);
    assert!(r.out.contains("hooks: absent"));
    assert!(r.err.contains("radin hooks all"));
}

#[test]
fn wire_fails_when_upstream_fails_and_configured_nothing() {
    let t = w();
    cli::stub(&t.bin, "codebase-memory-mcp", "exit 1\n");
    t.write(&t.settings(), r#"{"hooks": {}}"#);
    let r = t.wire();
    assert_eq!(r.code, 1);
    assert!(!r.err.contains("PARTIAL"));
}

#[test]
fn wire_rewrites_tilde_hook_paths_to_absolute_leaving_another_tools_alone() {
    let t = w();
    let home = t.home.display().to_string();
    let hooks = t.home.join(".claude/hooks");
    fs::create_dir_all(&hooks).unwrap();
    fs::create_dir_all(t.home.join(".local/bin")).unwrap();
    for p in [
        hooks.join("cbm-session-reminder"),
        t.home.join("other-tool-hook"),
        t.home.join(".local/bin/codebase-memory-mcp"),
    ] {
        fs::write(p, "").unwrap();
    }
    t.stub_cbm(
        &format!(
            r#"{{"hooks": {{"SessionStart": [{{"matcher": "startup", "hooks": [{{"type": "command", "command": "'{home}/.claude/hooks/cbm-session-reminder'"}}]}},
                            {{"matcher": "", "hooks": [{{"type": "command", "command": "{home}/other-tool-hook"}}]}},
                            {{"matcher": "startup", "hooks": [{{"type": "command", "command": "~/.local/bin/codebase-memory-mcp"}}]}}]}}}}"#
        ),
        &format!(
            r#"{{"mcpServers": {{"codebase-memory-mcp": {{"command": "{home}/.local/bin/codebase-memory-mcp"}}}}}}"#
        ),
    );
    let p = t.bin.join("codebase-memory-mcp");
    let mut s = read(&p);
    s.push_str(
        "mkdir -p \"$HOME/.claude/hooks\"\n: > \"$HOME/.claude/hooks/cbm-session-reminder\"\n",
    );
    fs::write(&p, s).unwrap();
    let r = t.wire();
    assert_eq!(r.code, 0, "{}", r.err);
    assert!(r.out.contains("ABSOLUTE"));
    assert_eq!(
        commands(&t.settings()),
        [
            format!("{home}/.claude/hooks/cbm-session-reminder"),
            format!("{home}/other-tool-hook"),
            format!("{home}/.local/bin/codebase-memory-mcp")
        ]
    );
    assert!(read(&t.claude_json()).contains(&format!(
        "\"command\": \"{home}/.local/bin/codebase-memory-mcp\""
    )));
}

#[path = "tui_pty/harness.rs"]
mod harness;

use harness::Term;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

struct Fx {
    _t: tempfile::TempDir,
    root: PathBuf,
    proj: PathBuf,
}

fn env(k: &str) -> Option<String> {
    (k == "HOME").then(|| "/nonexistent".to_string())
}

impl Fx {
    fn new() -> Fx {
        let t = tempfile::tempdir().unwrap();
        let root = t.path().canonicalize().unwrap();
        let proj = root.join("proj");
        fs::create_dir_all(&proj).unwrap();
        Fx { _t: t, root, proj }
    }

    fn bl(&self, args: &[&str], stdin: &str) -> radin::Out {
        let mut v = vec!["backlog".to_string()];
        v.extend(args.iter().map(|s| s.to_string()));
        radin::run_in(&v, &env, false, &self.proj, Some(stdin))
    }

    fn add(&self, cat: &str, title: &str) -> String {
        let (code, out, err) = self.bl(&["add", cat, title], "body\n");
        assert_eq!(code, 0, "{err}");
        out.trim().to_string()
    }

    fn seed(&self) {
        self.add("feat", "dark mode");
        self.add("fix", "broken auth");
    }

    fn ns(&self) -> PathBuf {
        self.proj.join(".radin")
    }

    fn index(&self) -> String {
        fs::read_to_string(self.ns().join("backlog/index.jsonl")).unwrap_or_default()
    }

    fn script(&self, name: &str, body: &str) -> String {
        let p = self.root.join(name);
        fs::write(&p, format!("#!/bin/sh\n{body}\n")).unwrap();
        fs::set_permissions(&p, fs::Permissions::from_mode(0o755)).unwrap();
        p.to_string_lossy().into_owned()
    }

    fn typist(&self) -> String {
        self.script("editor.sh", "printf 'typed body\\n' >\"$1\"")
    }

    fn open(&self, size: (u16, u16), env: &[(&str, &str)]) -> Term {
        let mut t = Term::spawn(&self.proj, size, env);
        t.wait_for("radin backlog");
        t.quiet();
        t
    }

    fn tui(&self, env: &[(&str, &str)]) -> Term {
        self.open((80, 24), env)
    }

    /// An editor that adds a task from outside while the TUI is parked on it.
    fn outside(&self, args: &str) -> String {
        let bin = env!("CARGO_BIN_EXE_radin");
        self.script(
            "outside.sh",
            &format!(
                "printf 'typed body\\n' >\"$1\"\ncd '{}' && printf 'x\\n' | HOME='{}' '{bin}' backlog {args} >/dev/null 2>&1",
                self.proj.display(),
                self.root.join("home").display()
            ),
        )
    }
}

fn read(p: &Path) -> String {
    fs::read_to_string(p).unwrap_or_default()
}

#[test]
fn refuses_to_draw_when_stdout_is_not_a_terminal() {
    let fx = Fx::new();
    let o = Command::new(env!("CARGO_BIN_EXE_radin"))
        .current_dir(&fx.proj)
        .stdin(Stdio::null())
        .output()
        .unwrap();
    assert_eq!(o.status.code(), Some(1));
    assert!(!String::from_utf8_lossy(&o.stdout).contains("\x1b[?1049h"));
    assert!(String::from_utf8_lossy(&o.stderr).contains("usage: radin"));
}

#[test]
fn refuses_to_draw_when_stdin_is_not_a_terminal() {
    let fx = Fx::new();
    let sh = format!("'{}' </dev/null", env!("CARGO_BIN_EXE_radin"));
    let mut t = Term::spawn_cmd(&fx.proj, &sh);
    t.wait_for("interactive terminal");
    assert_eq!(t.exit_code(), 1);
}

#[test]
fn q_exits_0_restores_the_terminal_and_wraps_each_frame_in_mode_2026() {
    let fx = Fx::new();
    let mut t = fx.tui(&[]);
    t.send("q");
    assert_eq!(t.exit_code(), 0);
    let raw = t.raw();
    assert!(raw.contains("\x1b[?1049h") && raw.contains("\x1b[?1049l"));
    let first = raw.split("\x1b[?2026l").next().unwrap();
    assert_eq!(first.matches("\x1b[?2026h").count(), 1);
    assert!(first.contains("radin backlog"));
}

#[test]
fn ctrl_c_exits_130_after_restoring_the_terminal() {
    let fx = Fx::new();
    let mut t = fx.tui(&[]);
    t.send("\x03");
    assert_eq!(t.exit_code(), 130);
    assert!(t.raw().contains("\x1b[?1049l"));
}

#[test]
fn a_creates_a_task_from_the_category_key_title_and_editor_body() {
    let fx = Fx::new();
    let mut t = fx.tui(&[("EDITOR", &fx.typist())]);
    t.keys("ax");
    t.keys("from tui\r");
    t.wait_for("[1/1]");
    t.keys("q");
    assert!(
        fx.index().contains("\"id\":\"from-tui\"") && fx.index().contains("\"category\":\"fix\"")
    );
    assert_eq!(
        read(&fx.ns().join("backlog/tasks/from-tui.md")).trim_end(),
        "typed body"
    );
    assert_eq!(t.exit_code(), 0);
}

#[test]
fn e_opens_the_task_body_in_the_editor() {
    let fx = Fx::new();
    fx.seed();
    let mut t = fx.tui(&[("EDITOR", &fx.typist())]);
    t.keys("e");
    t.wait_for("edited dark-mode");
    assert_eq!(
        read(&fx.ns().join("backlog/tasks/dark-mode.md")).trim_end(),
        "typed body"
    );
}

#[test]
fn e_on_an_epic_header_edits_that_epics_description() {
    let fx = Fx::new();
    for e in ["aaa-epic", "bbb-epic"] {
        fx.bl(&["epic-add", e], "ctx\n");
    }
    let id = fx.add("feat", "aaa child");
    fx.bl(&["epic-move", &id, "aaa-epic"], "");
    let mut t = fx.tui(&[("EDITOR", &fx.typist())]);
    t.keys("e");
    t.wait_for("edited aaa-epic description");
    assert_eq!(
        read(&fx.ns().join("backlog/tasks/aaa-epic/DESCRIPTION.md")).trim_end(),
        "typed body"
    );
    assert_eq!(
        read(&fx.ns().join("backlog/tasks/bbb-epic/DESCRIPTION.md")).trim_end(),
        "ctx"
    );
}

#[test]
fn capital_e_creates_the_epic_and_keeps_it_when_the_editor_writes_nothing() {
    let fx = Fx::new();
    fx.seed();
    let mut t = fx.tui(&[("EDITOR", &fx.typist())]);
    t.keys("Eui-polish\r");
    t.wait_for("created epic ui-polish");
    assert_eq!(
        read(&fx.ns().join("backlog/tasks/ui-polish/DESCRIPTION.md")).trim_end(),
        "typed body"
    );
    drop(t);
    let mut t = fx.tui(&[("EDITOR", "true")]);
    t.keys("Eempty-one\r");
    t.wait_for("description left empty");
    let d = fx.ns().join("backlog/tasks/empty-one/DESCRIPTION.md");
    assert_eq!(fs::metadata(d).unwrap().len(), 0);
}

#[test]
fn v_composes_the_detail_in_the_pager() {
    let fx = Fx::new();
    fx.seed();
    let mut t = fx.tui(&[("PAGER", "cat")]);
    t.keys("v");
    t.wait_for("radin backlog");
    let raw = t.raw();
    assert!(raw.contains("## Depends on") && raw.contains("Add dark") || raw.contains("body"));
    assert!(raw.contains("id: dark-mode"));
    assert!(fs::read_dir(fx.ns()).unwrap().all(|e| !e
        .unwrap()
        .file_name()
        .to_string_lossy()
        .starts_with("tui-detail")));
}

#[test]
fn o_pages_the_order_and_reports_an_empty_backlog() {
    let fx = Fx::new();
    let mut t = fx.tui(&[("PAGER", "cat")]);
    t.keys("o");
    assert!(t.screen().contains("order failed"));
    assert!(!t.raw().contains("dependency override:"));
    drop(t);
    fx.add("feat", "first dep");
    fx.bl(&["set-priority", "first-dep", "1"], "");
    fx.add("feat", "later blocked");
    fx.bl(&["set-priority", "later-blocked", "8"], "");
    fx.bl(&["set-deps", "later-blocked", "first-dep"], "");
    let mut t = fx.tui(&[("PAGER", "cat")]);
    t.keys("o");
    assert!(t.raw().contains("dependency override:"));
}

#[test]
fn polling_picks_up_a_task_another_shell_added_with_no_keypress() {
    let fx = Fx::new();
    fx.seed();
    let mut t = fx.tui(&[
        ("EDITOR", &fx.outside("add feat \"from elsewhere\"")),
        ("RADIN_TUI_POLL_MS", "10"),
    ]);
    t.send("e");
    t.wait_for("from elsewhere");
    assert!(t.screen().contains("3 task(s)"));
}

#[test]
fn polling_drops_a_task_another_shell_removed() {
    let fx = Fx::new();
    fx.seed();
    let mut t = fx.tui(&[
        ("EDITOR", &fx.outside("remove broken-auth")),
        ("RADIN_TUI_POLL_MS", "10"),
    ]);
    t.send("e");
    t.wait_for("1 task(s)");
    assert!(!t.screen().contains("broken auth"));
}

#[test]
fn a_refresh_keeps_the_selected_task_selected_when_a_row_above_it_goes() {
    let fx = Fx::new();
    fx.seed();
    fx.add("feat", "third task");
    let mut t = fx.tui(&[
        ("EDITOR", &fx.outside("remove dark-mode")),
        ("RADIN_TUI_POLL_MS", "10"),
    ]);
    t.keys("j");
    t.send("e");
    t.wait_for("[1/2]");
    assert!(t.screen().contains("broken auth"));
}

#[test]
fn an_unchanged_index_neither_redraws_nor_clears_the_footer_message() {
    let fx = Fx::new();
    fx.seed();
    let mut t = fx.tui(&[("RADIN_TUI_POLL_MS", "10")]);
    t.keys("R");
    assert!(t.screen().contains("reloaded"));
    let before = t.raw().len();
    t.quiet();
    t.quiet();
    assert!(t.screen().contains("reloaded"));
    assert_eq!(t.raw().len(), before);
}

#[test]
fn a_keypress_burst_applies_every_motion_and_keeps_the_key_after_them() {
    let fx = Fx::new();
    fx.seed();
    fx.add("chore", "third thing");
    let mut t = fx.tui(&[]);
    t.keys("jjd");
    t.keys("y\r");
    t.keys("q");
    assert!(!fx.ns().join("backlog/tasks/third-thing.md").exists());
    assert!(fx.ns().join("backlog/tasks/dark-mode.md").exists());
    assert!(fx.ns().join("backlog/tasks/broken-auth.md").exists());
}

#[test]
fn escape_cancels_an_overlay() {
    let fx = Fx::new();
    fx.seed();
    let mut t = fx.tui(&[]);
    t.keys("p");
    assert!(t.screen().contains("priority for dark-mode"));
    t.keys("\x1b");
    t.wait_for("priority cancelled");
    assert!(!fx.index().contains("\"priority\""));
}

#[test]
fn arrow_keys_move_and_switch_the_detail_view() {
    let fx = Fx::new();
    fx.seed();
    let mut t = fx.open((120, 24), &[]);
    t.keys("\x1b[B");
    assert!(t.screen().contains("[2/2]"));
    t.keys("\x1b[C");
    assert!(t.screen().contains("(no plan yet -- run /radin-plan)"));
}

#[test]
fn no_color_drops_the_priority_colours_and_colour_keeps_them() {
    let fx = Fx::new();
    fx.add("feat", "low one");
    fx.bl(&["set-priority", "low-one", "1"], "");
    fx.add("feat", "high one");
    fx.bl(&["set-priority", "high-one", "13"], "");
    let mut t = fx.tui(&[("NO_COLOR", "1")]);
    assert!(t.cells().iter().all(|c| *c == vt100::Color::Default));
    drop(t);
    let mut t = fx.tui(&[]);
    let cells = t.cells();
    assert!(cells.contains(&vt100::Color::Idx(1)) && cells.contains(&vt100::Color::Idx(2)));
}

#[test]
fn w_and_b_persist_the_worktree_and_branch_answers() {
    let fx = Fx::new();
    fx.seed();
    let session = || {
        read(&fx.ns().join("state/session.json"))
            .trim_end()
            .to_string()
    };
    let mut t = fx.tui(&[]);
    t.keys("w");
    t.keys("q");
    drop(t);
    assert_eq!(session(), r#"{"worktree":"yes","branch":"no"}"#);
    let mut t = fx.tui(&[]);
    t.keys("bw");
    t.keys("q");
    assert_eq!(t.exit_code(), 0);
    assert_eq!(session(), r#"{"worktree":"no","branch":"yes"}"#);
}

/// Writes the raw byte stream of the README demo to `$RADIN_SCREENSHOT_RAW`; `make screenshot` renders it.
#[test]
#[ignore]
fn screenshot_dump() {
    let out = std::env::var("RADIN_SCREENSHOT_RAW").expect("RADIN_SCREENSHOT_RAW");
    let fx = Fx::new();
    fx.bl(
        &["epic-add", "auth-rework"],
        "Move the API from session cookies to short-lived JWTs without logging anyone out.\n",
    );
    fx.bl(
        &["epic-add", "import-speed"],
        "Make the nightly import finish in minutes instead of hours.\n",
    );
    let add = |cat: &str, title: &str, deps: &str, body: &str| {
        let mut a = vec!["add", cat, title];
        if !deps.is_empty() {
            a.extend(["--deps", deps]);
        }
        fx.bl(&a, &format!("{body}\n")).1.trim().to_string()
    };
    let a = add(
        "feat",
        "Issue JWT access and refresh tokens",
        "",
        "Add /auth/token. Access token 15 min, refresh 7 days.",
    );
    let b = add(
        "refactor",
        "Replace session middleware with a token check",
        &a,
        "Swap the cookie lookup for a verified JWT claim.",
    );
    let c = add(
        "fix",
        "Reject expired refresh tokens with 401",
        &a,
        "An expired refresh token returns 500 today.",
    );
    let d = add(
        "chore",
        "Document the new login flow",
        &b,
        "Update docs/auth.md.",
    );
    let e = add(
        "refactor",
        "Batch inserts in the CSV importer",
        "",
        "One INSERT per row takes 40 min on 1M rows.",
    );
    let f = add(
        "fix",
        "Stream the import instead of loading it in memory",
        &e,
        "The importer runs out of memory on files over 2 GB.",
    );
    let g = add(
        "feat",
        "Resume an interrupted import from its last row",
        &f,
        "Store the row offset after each batch.",
    );
    let h = add(
        "fix",
        "Trim trailing whitespace in exported CSV headers",
        "",
        "Headers carry a trailing space.",
    );
    let i = add(
        "chore",
        "Bump the HTTP client to the latest minor",
        "",
        "No API change expected.",
    );
    for t in [&a, &b, &c, &d] {
        fx.bl(&["epic-move", t, "auth-rework"], "");
    }
    for t in [&e, &f, &g] {
        fx.bl(&["epic-move", t, "import-speed"], "");
    }
    for (t, p) in [
        (&a, "13"),
        (&b, "8"),
        (&c, "8"),
        (&d, "2"),
        (&e, "13"),
        (&f, "8"),
        (&g, "5"),
        (&h, "5"),
        (&i, "1"),
    ] {
        fx.bl(&["set-priority", t, p], "");
    }
    let mut t = fx.open((150, 26), &[]);
    t.keys("jjj");
    fs::write(out, t.raw()).unwrap();
}

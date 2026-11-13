use crossterm::event::{KeyCode, KeyEvent, KeyEventKind, KeyModifiers};
use radin::state::Ctx;
use radin::tui::{App, Effect, Palette, Then};
use ratatui::buffer::Buffer;
use ratatui::layout::Rect;
use ratatui::style::Color;
use std::fs;
use std::path::{Path, PathBuf};

struct Fx {
    _t: tempfile::TempDir,
    proj: PathBuf,
    home: PathBuf,
}

fn key(code: KeyCode, mods: KeyModifiers) -> KeyEvent {
    KeyEvent::new(code, mods)
}

fn press(app: &mut App, keys: &str) -> Vec<Effect> {
    let mut out = Vec::new();
    for c in keys.chars() {
        let ev = match c {
            '\r' => key(KeyCode::Enter, KeyModifiers::NONE),
            '\t' => key(KeyCode::Tab, KeyModifiers::NONE),
            '\u{1b}' => key(KeyCode::Esc, KeyModifiers::NONE),
            '\u{7f}' => key(KeyCode::Backspace, KeyModifiers::NONE),
            '\u{4}' => key(KeyCode::Char('d'), KeyModifiers::CONTROL),
            '\u{15}' => key(KeyCode::Char('u'), KeyModifiers::CONTROL),
            c => key(KeyCode::Char(c), KeyModifiers::NONE),
        };
        let e = app.key(ev);
        if e != Effect::None {
            out.push(e);
        }
    }
    out
}

/// The one external program a key string asked for.
fn run_of(mut effects: Vec<Effect>) -> (String, PathBuf, Then) {
    assert_eq!(effects.len(), 1, "{effects:?}");
    match effects.remove(0) {
        Effect::Run {
            program,
            path,
            then,
        } => (program, path, then),
        e => panic!("{e:?}"),
    }
}

/// Plays an editor: writes `body` (or leaves the file as it is), then reports the program done.
fn edit(app: &mut App, effects: Vec<Effect>, body: Option<&str>) -> PathBuf {
    let (_, path, then) = run_of(effects);
    if let Some(b) = body {
        fs::write(&path, b).unwrap();
    }
    app.finished(then);
    path
}

struct Screen {
    rows: Vec<String>,
    buf: Buffer,
    cursor: Option<(u16, u16)>,
}

impl Screen {
    fn text(&self) -> String {
        self.rows.join("\n")
    }

    fn has(&self, s: &str) -> bool {
        self.text().contains(s)
    }

    fn count(&self, s: &str) -> usize {
        self.rows.iter().filter(|r| r.contains(s)).count()
    }
}

fn render(app: &mut App, w: u16, h: u16) -> Screen {
    let area = Rect::new(0, 0, w, h);
    let mut buf = Buffer::empty(area);
    let cursor = app.draw_buf(&mut buf, area);
    let rows = (0..h)
        .map(|y| {
            let mut row = String::new();
            let mut skip = 0;
            for x in 0..w {
                if skip > 0 {
                    skip -= 1;
                    continue;
                }
                let s = buf[(x, y)].symbol();
                skip = unicode_width_of(s).saturating_sub(1);
                row.push_str(s);
            }
            row.trim_end().to_string()
        })
        .collect();
    Screen { rows, buf, cursor }
}

fn unicode_width_of(s: &str) -> usize {
    unicode_width::UnicodeWidthStr::width(s)
}

impl Fx {
    fn new() -> Fx {
        let t = tempfile::tempdir().unwrap();
        let root = t.path().canonicalize().unwrap();
        let proj = root.join("proj");
        fs::create_dir_all(&proj).unwrap();
        Fx {
            home: root.join("home"),
            proj,
            _t: t,
        }
    }

    fn env(&self) -> impl Fn(&str) -> Option<String> {
        let home = self.home.to_string_lossy().into_owned();
        move |k: &str| match k {
            "HOME" => Some(home.clone()),
            "EDITOR" => Some("ed-test".into()),
            "PAGER" => Some("pg-test".into()),
            _ => None,
        }
    }

    fn bl(&self, args: &[&str], stdin: &str) -> radin::Out {
        let mut v = vec!["backlog".to_string()];
        v.extend(args.iter().map(|s| s.to_string()));
        radin::run_in(&v, &self.env(), false, &self.proj, Some(stdin))
    }

    fn add(&self, cat: &str, title: &str, body: &str) -> String {
        let (code, out, err) = self.bl(&["add", cat, title], &format!("{body}\n"));
        assert_eq!(code, 0, "{err}");
        out.trim().to_string()
    }

    fn seed(&self) {
        self.add("feat", "dark mode", "Add dark mode.");
        self.add("fix", "broken auth", "Auth times out.");
    }

    fn two_epics(&self) {
        for (e, ctx) in [("aaa-epic", "aaa ctx"), ("bbb-epic", "bbb ctx")] {
            assert_eq!(self.bl(&["epic-add", e], &format!("{ctx}\n")).0, 0);
        }
        for p in ["aaa", "bbb"] {
            let id = self.add("feat", &format!("{p} child"), &format!("{p} body"));
            assert_eq!(self.bl(&["epic-move", &id, &format!("{p}-epic")], "").0, 0);
        }
    }

    fn ns(&self) -> PathBuf {
        self.proj.join(".radin")
    }

    fn index(&self) -> String {
        fs::read_to_string(self.ns().join("backlog/index.jsonl")).unwrap_or_default()
    }

    fn entry(&self, id: &str) -> String {
        let needle = format!("\"id\":\"{id}\"");
        self.index()
            .lines()
            .find(|l| l.contains(&needle))
            .unwrap_or("")
            .to_string()
    }

    fn task(&self, rel: &str) -> PathBuf {
        self.ns().join("backlog/tasks").join(rel)
    }

    fn read(&self, rel: &str) -> String {
        fs::read_to_string(self.task(rel)).unwrap_or_default()
    }

    fn write(&self, rel: &str, text: &str) {
        let p = self.task(rel);
        fs::create_dir_all(p.parent().unwrap()).unwrap();
        fs::write(p, text).unwrap();
    }

    fn plan(&self, id: &str, outcome: &str) -> PathBuf {
        let path = self.ns().join(format!("plans/{id}.md"));
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        let mut s = format!("## Outcome\n{outcome}\n");
        for h in ["Decisions", "Alternatives rejected"] {
            s += &format!("## {h}\nn/a: test\n");
        }
        s += "## Changes\n- `a.txt` - edit\n  You see: a\n";
        for h in [
            "Reach and reuse",
            "Rubrics triggered",
            "Modes and states",
            "Order",
        ] {
            s += &format!("## {h}\nn/a: test\n");
        }
        s += "## Testing\n- [ ] run it\n";
        for h in ["Risks", "Out of scope"] {
            s += &format!("## {h}\nn/a: test\n");
        }
        fs::write(&path, s).unwrap();
        assert_eq!(self.bl(&["add-plan", id, path.to_str().unwrap()], "").0, 0);
        path
    }

    fn with<R>(&self, f: impl FnOnce(&mut App) -> R) -> R {
        self.with_pal(Palette::p16(), f)
    }

    fn with_pal<R>(&self, pal: Palette, f: impl FnOnce(&mut App) -> R) -> R {
        let env = self.env();
        let cli = |d: &Path, a: &[&str], i: &str| {
            let v: Vec<String> = a.iter().map(|s| s.to_string()).collect();
            radin::run_in(&v, &env, false, d, Some(i))
        };
        let cx = Ctx {
            cwd: self.proj.clone(),
            home: self.home.clone(),
            stdin: String::new(),
            env: &env,
            cli: &cli,
        };
        let mut app = App::new(&cx, pal, 1_800_000_000);
        f(&mut app)
    }
}

fn wide(app: &mut App) -> Screen {
    render(app, 120, 24)
}

#[test]
fn runs_with_an_empty_backlog() {
    let fx = Fx::new();
    fx.with(|a| assert!(render(a, 80, 24).has("(no tasks) press a to create one")));
}

#[test]
fn a_cancels_on_an_unknown_category_key() {
    let fx = Fx::new();
    fx.with(|a| {
        assert!(press(a, "az").is_empty());
        assert!(render(a, 80, 24).has("new: cancelled"));
    });
    assert_eq!(fx.index(), "");
}

#[test]
fn a_creates_a_task_from_category_title_and_editor_body() {
    let fx = Fx::new();
    fx.with(|a| {
        let e = press(a, "ax");
        assert!(e.is_empty());
        let s = render(a, 80, 24);
        assert!(s.has("title:"));
        assert_eq!(s.cursor, Some((7, 23)));
        let e = press(a, "from tui\r");
        let path = edit(a, e, Some("typed body\n"));
        assert!(path
            .file_name()
            .unwrap()
            .to_string_lossy()
            .starts_with("tui-body."));
        assert!(!path.exists());
        assert!(fx.entry("from-tui").contains("\"category\":\"fix\""));
        assert_eq!(fx.read("from-tui.md").trim_end(), "typed body");
    });
}

#[test]
fn a_cancels_on_an_empty_title_or_an_untouched_body() {
    let fx = Fx::new();
    fx.with(|a| {
        press(a, "af\r");
        assert!(render(a, 80, 24).has("new: empty title, cancelled"));
        let e = press(a, "afhi\r");
        let (program, _, _) = run_of(e);
        assert_eq!(program, "ed-test");
    });
    fx.with(|a| {
        let e = press(a, "afhi\r");
        edit(a, e, None);
        assert!(render(a, 80, 24).has("new: empty body, cancelled"));
    });
    assert_eq!(fx.index(), "");
}

#[test]
fn slash_marks_matching_rows_and_hides_nothing() {
    let fx = Fx::new();
    fx.seed();
    fx.with(|a| {
        press(a, "/auth\r");
        let s = render(a, 80, 24);
        assert!(s.has("2 task(s)"));
        assert!(s.has("search:\"auth\""));
        assert!(s.has("dark mode") && s.has("broken auth"));
        let marked: Vec<_> = s.rows.iter().filter(|r| r.contains(" * ")).collect();
        assert_eq!(marked.len(), 1);
        assert!(marked[0].contains("broken auth"));
    });
}

#[test]
fn an_epics_children_render_as_a_tree() {
    let fx = Fx::new();
    assert_eq!(fx.bl(&["epic-add", "ui-polish"], "ctx\n").0, 0);
    for t in ["first child", "second child", "third child"] {
        let id = fx.add("feat", t, "body");
        fx.bl(&["epic-move", &id, "ui-polish"], "");
    }
    fx.add("feat", "loose task", "body");
    fx.with(|a| {
        let s = render(a, 80, 24);
        assert_eq!(s.count("\u{251c}\u{2500}\u{2500} "), 2);
        assert_eq!(s.count("\u{2514}\u{2500}\u{2500} "), 1);
        let loose = s.rows.iter().find(|r| r.contains("loose task")).unwrap();
        assert!(!loose.contains('\u{251c}') && !loose.contains('\u{2514}'));
        assert!(s.has("epic: ui-polish") && s.has("first child"));
    });
}

#[test]
fn a_task_key_on_an_epic_header_reports_no_task() {
    let fx = Fx::new();
    fx.two_epics();
    let before = fx.index();
    fx.with(|a| {
        assert!(press(a, "dcrpDm").is_empty());
        assert!(render(a, 80, 24).has("epic header selected -- no task here"));
    });
    assert_eq!(fx.index(), before);
}

#[test]
fn tab_shows_the_done_view() {
    let fx = Fx::new();
    fx.seed();
    fs::write(
        fx.ns().join("state/completed.json"),
        "{\"id\":\"shipped-thing\",\"commit\":\"abc1234\",\"title\":\"\"}\n",
    )
    .unwrap();
    let before = fx.index();
    fx.with(|a| {
        press(a, "\t");
        let s = render(a, 80, 24);
        assert!(s.has("radin done  1 completed") && s.has("shipped-thing") && s.has("abc1234"));
        assert!(s.has("(read-only)"));
        press(a, "\t");
        assert!(render(a, 80, 24).has("radin backlog"));
    });
    assert_eq!(fx.index(), before);
}

#[test]
fn the_done_view_ignores_mutating_keys() {
    let fx = Fx::new();
    fx.seed();
    let before = fx.index();
    fx.with(|a| {
        assert!(press(a, "\td").is_empty());
        for k in [
            "y\r", "a", "x", "nope\r", "p", "9\r", "D", " \r", "m", "\r", "E", "nope\r",
        ] {
            assert!(press(a, k).is_empty());
        }
        assert!(render(a, 80, 24).has("radin done"));
    });
    assert_eq!(fx.index(), before);
    assert!(fx.task("dark-mode.md").exists());
    assert!(!fx.task("nope").exists());
}

#[test]
fn g_scrolls_the_done_view_past_one_window() {
    let fx = Fx::new();
    fx.seed();
    let rows: String = (1..=25)
        .map(|i| format!("{{\"id\":\"done-{i}\",\"commit\":\"hash{i}\",\"title\":\"\"}}\n"))
        .collect();
    fs::write(fx.ns().join("state/completed.json"), rows).unwrap();
    fx.with(|a| {
        press(a, "\tG");
        let s = render(a, 80, 24);
        assert!(s.has("done-25"));
        assert!(!s.has("done-1 "));
    });
}

#[test]
fn shift_p_sorts_by_priority_and_shift_a_returns() {
    let fx = Fx::new();
    fx.seed();
    fx.bl(&["set-priority", "broken-auth", "21"], "");
    let order = |s: &Screen| {
        let t = s.text();
        (t.find("dark mode").unwrap(), t.find("broken auth").unwrap())
    };
    fx.with(|a| {
        press(a, "P");
        let s = render(a, 80, 24);
        assert!(s.has("sort:priority") && s.has("sort:priority"));
        let (d, b) = order(&s);
        assert!(b < d);
        press(a, "A");
        let s = render(a, 80, 24);
        let (d, b) = order(&s);
        assert!(s.has("sort:created") && d < b);
        press(a, "P");
    });
    fx.with(|a| {
        let s = render(a, 80, 24);
        let (d, b) = order(&s);
        assert!(s.has("sort:created") && d < b);
    });
}

#[test]
fn shift_c_and_shift_t_sort_by_category_and_title() {
    let fx = Fx::new();
    fx.add("fix", "zeta", "b");
    fx.add("feat", "Alpha", "b");
    fx.add("chore", "mid", "b");
    let titles = |a: &App| {
        a.m.rows
            .iter()
            .map(|r| match r {
                radin::tui::Row::Task(i) => a.m.tasks[*i].title.clone(),
                radin::tui::Row::Epic(e) => e.clone(),
            })
            .collect::<Vec<_>>()
    };
    fx.with(|a| {
        press(a, "C");
        assert_eq!(titles(a), ["Alpha", "zeta", "mid"]);
        press(a, "T");
        assert_eq!(titles(a), ["Alpha", "mid", "zeta"]);
    });
}

#[test]
fn e_creates_the_epic_and_writes_its_description() {
    let fx = Fx::new();
    fx.seed();
    fx.with(|a| {
        let e = press(a, "Eui-polish\r");
        let path = edit(a, e, Some("typed body\n"));
        assert_eq!(path, fx.task("ui-polish/DESCRIPTION.md"));
        assert_eq!(fs::read_to_string(path).unwrap(), "typed body\n");
        assert!(render(a, 80, 24).has("created epic ui-polish"));
    });
}

#[test]
fn e_keeps_the_epic_when_the_editor_writes_nothing() {
    let fx = Fx::new();
    fx.seed();
    fx.with(|a| {
        let e = press(a, "Eui-polish\r");
        let path = edit(a, e, None);
        assert_eq!(fs::metadata(path).unwrap().len(), 0);
        assert!(render(a, 80, 24).has("created epic ui-polish -- description left empty"));
    });
}

#[test]
fn a_rejected_epic_add_opens_no_editor() {
    let fx = Fx::new();
    fx.with(|a| {
        assert!(press(a, "EBad Slug!\r").is_empty());
        assert!(render(a, 80, 24).has("epic-add failed:"));
        assert!(press(a, "E\r").is_empty());
        assert!(render(a, 80, 24).has("new epic: cancelled"));
    });
}

#[test]
fn d_offers_a_task_a_collapsed_epic_is_hiding() {
    let fx = Fx::new();
    fx.bl(&["epic-add", "ui-polish"], "ctx\n");
    let id = fx.add("feat", "nested task", "body");
    fx.bl(&["epic-move", &id, "ui-polish"], "");
    fx.add("chore", "loose task", "body");
    fx.with(|a| {
        press(a, "j\rgD \r");
    });
    assert!(
        fx.entry("loose-task")
            .contains("\"depends_on\":[\"nested-task\"]"),
        "{}",
        fx.index()
    );
}

#[test]
fn a_detail_document_builds_at_most_once_per_row_view_and_width() {
    let fx = Fx::new();
    fx.seed();
    fx.plan("dark-mode", "plan step one");
    fx.with(|a| {
        wide(a);
        assert_eq!(a.m.det_builds, 1);
        wide(a);
        assert_eq!(a.m.det_builds, 1);
        for k in ["\u{4}", "\u{15}"] {
            press(a, k);
            wide(a);
            assert_eq!(a.m.det_builds, 1, "{k:?}");
        }
        for (k, builds) in [("j", 2), ("k", 3), ("G", 4), ("g", 5), ("l", 6), ("h", 7)] {
            press(a, k);
            wide(a);
            wide(a);
            assert_eq!(a.m.det_builds, builds, "{k}");
        }
    });
}

#[test]
fn h_and_l_on_an_epic_header_change_nothing() {
    let fx = Fx::new();
    fx.two_epics();
    fx.with(|a| {
        wide(a);
        press(a, "lj");
        assert!(wide(a).has("aaa body"));
    });
    fx.with(|a| {
        wide(a);
        press(a, "jlkhj");
        assert!(wide(a).has("no plan yet"));
    });
}

#[test]
fn a_tab_in_the_detail_does_not_widen_the_row() {
    let fx = Fx::new();
    fx.seed();
    fx.write("dark-mode.md", "X\tY\n");
    fx.with(|a| {
        let s = wide(a);
        assert!(s.has("X Y") && !s.has("X\tY"));
    });
}

#[test]
fn enter_on_a_task_row_does_nothing_at_120_columns() {
    let fx = Fx::new();
    fx.seed();
    fx.write("dark-mode.md", "# Heading\n");
    fx.with(|a| {
        wide(a);
        assert!(press(a, "\r").is_empty());
        let s = wide(a);
        assert!(s.has("[1/2]") && !s.has("q/esc close"));
    });
    assert_eq!(fx.read("dark-mode.md"), "# Heading\n");
}

#[test]
fn an_unchanged_index_neither_reloads_nor_clears_the_footer_message() {
    let fx = Fx::new();
    fx.seed();
    fx.with(|a| {
        press(a, "R");
        assert!(!a.tick());
        assert!(render(a, 80, 24).has("reloaded"));
        assert!(!a.tick());
    });
}

#[test]
fn d_deletes_only_after_a_y_confirmation() {
    let fx = Fx::new();
    fx.seed();
    fx.with(|a| {
        press(a, "dn\r");
        assert!(render(a, 80, 24).has("delete cancelled"));
        assert!(fx.task("dark-mode.md").exists());
        press(a, "d\u{1b}");
        assert!(fx.task("dark-mode.md").exists());
        let s = {
            press(a, "d");
            render(a, 80, 24)
        };
        assert!(s.has("delete \"dark mode\"? [y/N]"));
        press(a, "y\r");
    });
    assert!(!fx.task("dark-mode.md").exists());
    assert!(!fx.index().contains("\"id\":\"dark-mode\""));
}

#[test]
fn n_and_capital_n_walk_the_matches_and_wrap() {
    let fx = Fx::new();
    fx.seed();
    fx.add("chore", "dark chore", "body");
    fx.with(|a| {
        press(a, "/dark\rn");
        assert_eq!(a.m.sel, 2);
        press(a, "n");
        assert_eq!(a.m.sel, 0);
        press(a, "N");
        assert_eq!(a.m.sel, 2);
    });
}

#[test]
fn n_and_capital_n_do_nothing_without_a_search() {
    let fx = Fx::new();
    fx.seed();
    let before = fx.index();
    fx.with(|a| {
        assert!(a.is_motion(key(KeyCode::Char('n'), KeyModifiers::NONE)));
        press(a, "nN");
        assert_eq!(a.m.sel, 0);
        assert!(render(a, 80, 24).has("[1/2]"));
    });
    assert_eq!(fx.index(), before);
}

#[test]
fn a_collapsed_epic_hides_its_children_and_keeps_its_marker() {
    let fx = Fx::new();
    fx.bl(&["epic-add", "ui-polish"], "ctx\n");
    let id = fx.add("feat", "nested task", "body");
    fx.bl(&["epic-move", &id, "ui-polish"], "");
    fx.with(|a| {
        press(a, "g\r");
        let s = render(a, 80, 24);
        assert!(!s.has("\u{2514}\u{2500}\u{2500} ") && s.has("+ epic: ui-polish  (1)"));
        press(a, "\r");
        assert!(render(a, 80, 24).has("- epic: ui-polish"));
    });
}

#[test]
fn enter_collapses_an_epic_and_navigation_skips_its_children() {
    let fx = Fx::new();
    fx.two_epics();
    fx.with(|a| {
        let e = press(a, "\rjje");
        assert_eq!(
            edit(a, e, Some("typed body\n")),
            fx.task("bbb-epic/bbb-child.md")
        );
    });
    assert_eq!(fx.read("aaa-epic/aaa-child.md").trim_end(), "aaa body");
}

#[test]
fn e_opens_the_task_body_in_the_editor() {
    let fx = Fx::new();
    fx.seed();
    fx.with(|a| {
        let (program, path, then) = run_of(press(a, "e"));
        assert_eq!(
            (program.as_str(), path, then),
            (
                "ed-test",
                fx.task("dark-mode.md"),
                Then::EditBody("dark-mode".into())
            )
        );
        a.finished(Then::EditBody("dark-mode".into()));
        assert!(render(a, 80, 24).has("edited dark-mode"));
    });
}

#[test]
fn e_on_an_epic_header_edits_that_epics_description() {
    let fx = Fx::new();
    fx.two_epics();
    fx.with(|a| {
        let e = press(a, "e");
        edit(a, e, Some("typed body\n"));
        assert!(render(a, 80, 24).has("edited aaa-epic description"));
    });
    assert_eq!(fx.read("aaa-epic/DESCRIPTION.md"), "typed body\n");
    assert_eq!(fx.read("bbb-epic/DESCRIPTION.md").trim_end(), "bbb ctx");
}

#[test]
fn c_moves_the_selected_task_to_the_next_category() {
    let fx = Fx::new();
    fx.seed();
    fx.with(|a| press(a, "c"));
    assert!(fx.entry("dark-mode").contains("\"category\":\"fix\""));
}

#[test]
fn o_pages_the_execution_order_with_its_dependency_overrides() {
    let fx = Fx::new();
    fx.add("feat", "first dep", "a");
    fx.bl(&["set-priority", "first-dep", "1"], "");
    fx.add("feat", "later blocked", "b");
    fx.bl(&["set-priority", "later-blocked", "8"], "");
    fx.bl(&["set-deps", "later-blocked", "first-dep"], "");
    fx.with(|a| {
        let (program, path, then) = run_of(press(a, "o"));
        assert_eq!((program.as_str(), then), ("pg-test", Then::Page));
        assert!(fs::read_to_string(&path)
            .unwrap()
            .contains("dependency override:"));
        a.finished(Then::Page);
        assert!(!path.exists());
    });
}

#[test]
fn o_on_an_empty_backlog_reports_and_does_not_page() {
    let fx = Fx::new();
    fx.with(|a| {
        assert!(press(a, "o").is_empty());
        assert!(render(a, 80, 24).has("order failed"));
    });
}

#[test]
fn v_composes_body_epic_plan_and_dependency_title() {
    let fx = Fx::new();
    fx.add("feat", "dep target", "target body");
    fx.bl(&["epic-add", "ctx-epic"], "epic ctx line\n");
    let id = fx.add("feat", "needs dep", "needs body");
    fx.bl(&["epic-move", &id, "ctx-epic"], "");
    fx.bl(&["set-deps", &id, "dep-target"], "");
    fx.bl(&["set-priority", &id, "8"], "");
    fx.plan(&id, "plan body line");
    let before = fx.index();
    fx.with(|a| {
        let (_, path, _) = run_of(press(a, "jjv"));
        let doc = fs::read_to_string(&path).unwrap();
        for want in [
            "# needs dep\n",
            "priority: 8",
            "needs body",
            "epic ctx line",
            "plan body line",
            "- dep-target -- dep target\n",
        ] {
            assert!(doc.contains(want), "{want}\n{doc}");
        }
        a.finished(Then::Page);
    });
    assert_eq!(fx.index(), before);
}

#[test]
fn p_picks_a_priority_and_then_clears_it() {
    let fx = Fx::new();
    fx.seed();
    fx.with(|a| {
        press(a, "p\r");
    });
    assert!(fx.entry("dark-mode").contains("\"priority\":21"));
    fx.with(|a| {
        press(a, "pj\r");
    });
    assert!(fx.entry("dark-mode").contains("\"priority\":13"));
    fx.with(|a| {
        press(a, "pG\r");
    });
    assert!(!fx.entry("dark-mode").contains("\"priority\""));
}

#[test]
fn the_picker_cancels_on_q_and_escape() {
    let fx = Fx::new();
    fx.seed();
    let before = fx.index();
    fx.with(|a| {
        let s = {
            press(a, "p");
            render(a, 80, 24)
        };
        assert!(s.has("priority for dark-mode (higher wins)") && s.has("enter select  q cancel"));
        assert!(s.has("(none) -- clear the priority"));
        press(a, "q");
        assert!(render(a, 80, 24).has("priority cancelled"));
        press(a, "p\u{1b}");
        assert!(render(a, 80, 24).has("priority cancelled"));
        press(a, "m");
        assert!(render(a, 80, 24).has("no epics yet -- press E to create one"));
    });
    assert_eq!(fx.index(), before);
}

#[test]
fn a_rejected_set_deps_cycle_shows_a_message_and_changes_nothing() {
    let fx = Fx::new();
    fx.seed();
    fx.bl(&["set-deps", "dark-mode", "broken-auth"], "");
    let before = fx.index();
    fx.with(|a| {
        press(a, "jD \r");
        assert!(render(a, 80, 24).has("cycle"));
    });
    assert_eq!(fx.index(), before);
}

#[test]
fn no_color_drops_every_priority_colour() {
    let fx = Fx::new();
    fx.add("feat", "low one", "b");
    fx.bl(&["set-priority", "low-one", "1"], "");
    fx.add("feat", "high one", "b");
    fx.bl(&["set-priority", "high-one", "13"], "");
    let colours = |pal: Palette| {
        fx.with_pal(pal, |a| {
            let s = render(a, 80, 24);
            (0..80)
                .flat_map(|x| (0..24).map(move |y| (x, y)))
                .map(|p| s.buf[p].fg)
                .collect::<Vec<_>>()
        })
    };
    let none = colours(Palette::none());
    assert!(none.iter().all(|c| *c == Color::Reset));
    let p16 = colours(Palette::p16());
    assert!(p16.contains(&Color::Red) && p16.contains(&Color::Green));
}

#[test]
fn l_or_arrow_right_shows_the_plan_and_h_or_arrow_left_the_body() {
    let fx = Fx::new();
    fx.seed();
    fx.plan("dark-mode", "plan step one");
    fx.with(|a| {
        wide(a);
        press(a, "l");
        let s = wide(a);
        assert!(s.has("plan step one") && s.has("plans/dark-mode.md") && !s.has("Add dark mode."));
        press(a, "h");
        let s = wide(a);
        assert!(s.has("Add dark mode.") && !s.has("plan step one"));
        a.key(key(KeyCode::Right, KeyModifiers::NONE));
        assert!(wide(a).has("plan step one"));
        a.key(key(KeyCode::Left, KeyModifiers::NONE));
        let s = wide(a);
        assert!(s.has("Add dark mode.") && !s.has("plan step one"));
    });
}

#[test]
fn a_plan_pointer_whose_file_is_gone_reads_as_missing() {
    let fx = Fx::new();
    fx.seed();
    let plan = fx.plan("dark-mode", "plan step one");
    fs::remove_file(plan).unwrap();
    fx.with(|a| {
        wide(a);
        press(a, "l");
        assert!(wide(a).has("plan file missing"));
    });
}

#[test]
fn the_plan_view_of_an_unplanned_task_says_so() {
    let fx = Fx::new();
    fx.seed();
    fx.with(|a| {
        wide(a);
        press(a, "l");
        assert!(wide(a).has("(no plan yet -- run /radin-plan)"));
    });
}

#[test]
fn no_detail_pane_below_100_columns() {
    let fx = Fx::new();
    fx.seed();
    fx.write("dark-mode.md", "> quoted\n");
    fx.with(|a| {
        let s = render(a, 99, 24);
        assert!(!s.has("quoted") && s.has("\u{2500} tasks ") && !s.has("\u{2500} detail "));
        let s = render(a, 120, 30);
        assert!(s.has("quoted") && s.has("\u{2500} tasks ") && s.has("\u{2500} detail "));
    });
}

#[test]
fn ctrl_d_scrolls_the_detail_and_leaves_the_selection_alone() {
    let fx = Fx::new();
    fx.seed();
    fx.write(
        "dark-mode.md",
        &(1..=60)
            .map(|i| format!("line {i:02}\n"))
            .collect::<String>(),
    );
    fx.with(|a| {
        wide(a);
        press(a, "\u{4}");
        let s = wide(a);
        assert!(s.has("line 20") && !s.has("planned ") && s.has("[1/2]"));
        press(a, "\u{15}");
        assert!(wide(a).has("planned "));
    });
}

#[test]
fn j_moves_the_selection_and_does_not_scroll_the_detail() {
    let fx = Fx::new();
    fx.seed();
    fx.write(
        "dark-mode.md",
        &(1..=60)
            .map(|i| format!("line {i:02}\n"))
            .collect::<String>(),
    );
    fx.write(
        "broken-auth.md",
        &(1..=60)
            .map(|i| format!("auth {i:02}\n"))
            .collect::<String>(),
    );
    fx.with(|a| {
        wide(a);
        press(a, "\u{4}j");
        let s = wide(a);
        assert!(s.has("[2/2]") && s.has("auth 01"));
    });
}

#[test]
fn the_detail_view_sticks_as_the_selection_moves() {
    let fx = Fx::new();
    fx.seed();
    fx.plan("dark-mode", "first plan text");
    fx.plan("broken-auth", "second plan text");
    fx.with(|a| {
        wide(a);
        press(a, "lj");
        let s = wide(a);
        assert!(s.has("second plan text") && s.has("[2/2]"));
    });
}

#[test]
fn a_wide_glyph_in_a_title_does_not_overflow_the_list_row() {
    let fx = Fx::new();
    fx.seed();
    fx.add("fix", &format!("cjk {}", "\u{3042}".repeat(60)), "body");
    fx.with(|a| {
        let s = render(a, 80, 24);
        let run = "\u{3042}".repeat(41);
        assert!(!s.has(&run));
        assert!(s.has(&"\u{3042}".repeat(20)));
    });
}

#[test]
fn an_over_wide_token_is_cut_at_the_panes_edge_and_continues() {
    let fx = Fx::new();
    fx.seed();
    fx.write(
        "dark-mode.md",
        &format!("{}{}\n", "A".repeat(200), "\u{e9}".repeat(5)),
    );
    fx.with(|a| {
        let s = wide(a);
        assert!(s.has(&"A".repeat(70)) && !s.has(&"A".repeat(71)));
        assert!(s.has(&"\u{e9}".repeat(5)));
    });
}

#[test]
fn enter_opens_the_detail_overlay_below_100_columns_and_q_dismisses_it() {
    let fx = Fx::new();
    fx.seed();
    fx.write("dark-mode.md", "# Heading\n> quoted\n");
    fx.with(|a| {
        press(a, "\r");
        let s = render(a, 80, 24);
        assert!(s.has("q/esc close") && s.has("quoted"));
        press(a, "q");
        assert!(!a.quit());
        assert!(render(a, 80, 24).has("2 task(s)"));
        press(a, "\r\u{1b}");
        assert!(render(a, 80, 24).has("2 task(s)"));
    });
    assert_eq!(fx.read("dark-mode.md"), "# Heading\n> quoted\n");
}

#[test]
fn the_narrow_overlay_switches_views_with_the_same_keys() {
    let fx = Fx::new();
    fx.seed();
    fx.plan("dark-mode", "plan step one");
    fx.with(|a| {
        press(a, "\rl");
        let s = render(a, 80, 24);
        assert!(s.has("plan step one") && s.has("q/esc close"));
        press(a, "h");
        assert!(render(a, 80, 24).has("Add dark mode."));
    });
}

#[test]
fn r_retitles_the_selected_task_without_changing_its_id() {
    let fx = Fx::new();
    fx.seed();
    fx.with(|a| {
        press(a, "r");
        assert!(render(a, 80, 24).has("new title (was \"dark mode\"):"));
        press(a, "night mode\r");
    });
    let e = fx.entry("dark-mode");
    assert!(e.contains("\"title\":\"night mode\""), "{e}");
    fx.with(|a| {
        press(a, "rx\u{7f}\r");
        assert!(render(a, 80, 24).has("retitle cancelled"));
    });
}

#[test]
fn a_mutation_leaves_the_row_where_it_was_and_a_creates_at_the_bottom() {
    let fx = Fx::new();
    fx.seed();
    let titles = |a: &mut App| {
        let t = render(a, 80, 24).text();
        ["dark mode", "broken auth", "later thing"]
            .iter()
            .filter_map(|n| t.find(n).map(|i| (i, *n)))
            .fold(Vec::new(), |mut v, p| {
                v.push(p);
                v.sort();
                v
            })
            .into_iter()
            .map(|(_, n)| n)
            .collect::<Vec<_>>()
    };
    fx.with(|a| {
        press(a, "jp\r");
        assert_eq!(a.m.sel, 1);
        press(a, "q");
    });
    assert!(fx.entry("broken-auth").contains("\"priority\":21"));
    fx.with(|a| {
        assert_eq!(titles(a), ["dark mode", "broken auth"]);
        press(a, "cj");
        assert_eq!(a.m.sel, 1);
        let e = press(a, "af");
        assert!(e.is_empty());
        let e = press(a, "later thing\r");
        edit(a, e, Some("body\n"));
        press(a, "j");
        assert_eq!(titles(a), ["dark mode", "broken auth", "later thing"]);
    });
}

#[test]
fn m_moves_a_task_into_another_epic() {
    let fx = Fx::new();
    fx.two_epics();
    fx.with(|a| {
        press(a, "jmjj\r");
    });
    assert!(fx.task("bbb-epic/aaa-child.md").exists());
    assert!(!fx.task("aaa-epic/aaa-child.md").exists());
    assert!(fx
        .entry("aaa-child")
        .contains("\"file\":\"tasks/bbb-epic/aaa-child.md\""));
}

#[test]
fn capital_d_marks_two_candidates_and_writes_both_in_order() {
    let fx = Fx::new();
    fx.seed();
    fx.add("chore", "slow tests", "tests are slow");
    fx.with(|a| {
        press(a, "GD j \r");
    });
    assert!(
        fx.entry("slow-tests")
            .contains("\"depends_on\":[\"dark-mode\",\"broken-auth\"]"),
        "{}",
        fx.index()
    );
}

#[test]
fn capital_d_clears_depends_on_when_nothing_stays_marked() {
    let fx = Fx::new();
    fx.seed();
    fx.bl(&["set-deps", "dark-mode", "broken-auth"], "");
    fx.with(|a| {
        let s = {
            press(a, "D");
            render(a, 80, 24)
        };
        assert!(
            s.has("[x] broken-auth -- broken auth") && s.has("space mark  enter confirm  q cancel")
        );
        press(a, " \r");
    });
    assert!(!fx.entry("dark-mode").contains("depends_on"));
}

#[test]
fn polling_picks_up_a_task_another_shell_added() {
    let fx = Fx::new();
    fx.seed();
    fx.with(|a| {
        assert!(!a.tick());
        fx.add("feat", "from elsewhere", "x");
        assert!(a.tick());
        let s = render(a, 80, 24);
        assert!(s.has("from elsewhere") && s.has("3 task(s)"));
    });
}

#[test]
fn polling_drops_a_task_another_shell_removed() {
    let fx = Fx::new();
    fx.seed();
    fx.with(|a| {
        fx.bl(&["remove", "broken-auth"], "");
        assert!(a.tick());
        let s = render(a, 80, 24);
        assert!(!s.has("broken auth") && s.has("1 task(s)"));
    });
}

#[test]
fn a_refresh_keeps_the_selected_task_selected_when_a_row_above_it_goes() {
    let fx = Fx::new();
    fx.seed();
    fx.add("feat", "third task", "b");
    fx.with(|a| {
        press(a, "j");
        fx.bl(&["remove", "dark-mode"], "");
        assert!(a.tick());
        let s = render(a, 80, 24);
        assert!(s.has("[1/2]"));
        assert_eq!(a.m.tasks[a.m.cur_task().unwrap()].id, "broken-auth");
    });
}

#[test]
fn w_and_b_persist_the_worktree_and_branch_answers() {
    let fx = Fx::new();
    fx.seed();
    let session = || {
        fs::read_to_string(fx.ns().join("state/session.json"))
            .unwrap()
            .trim_end()
            .to_string()
    };
    fx.with(|a| {
        press(a, "w");
        assert!(render(a, 80, 24).has("worktree: yes"));
    });
    assert_eq!(session(), r#"{"worktree":"yes","branch":"no"}"#);
    fx.with(|a| {
        assert!(render(a, 80, 24).has("wt:yes br:no"));
        press(a, "bw");
    });
    assert_eq!(session(), r#"{"worktree":"no","branch":"yes"}"#);
}

#[test]
fn help_shows_the_key_list_and_any_key_closes_it() {
    let fx = Fx::new();
    fx.with(|a| {
        press(a, "?");
        let s = render(a, 80, 60);
        assert_eq!(s.rows[0], "radin tui keys");
        assert!(s.has("command palette"));
        press(a, "j");
        assert_ne!(render(a, 80, 60).rows[0], "radin tui keys");
        press(a, "x");
        assert!(render(a, 80, 24).has("radin backlog"));
    });
}

#[test]
fn quit_and_ctrl_c_end_the_app() {
    let fx = Fx::new();
    fx.with(|a| {
        assert_eq!(press(a, "q"), [Effect::Quit]);
        assert!(a.quit() && !a.interrupted);
    });
    fx.with(|a| {
        a.key(key(KeyCode::Char('c'), KeyModifiers::CONTROL));
        assert!(a.quit() && a.interrupted);
    });
}

#[test]
fn key_release_events_are_ignored() {
    let fx = Fx::new();
    fx.seed();
    fx.with(|a| {
        let mut up = key(KeyCode::Char('j'), KeyModifiers::NONE);
        up.kind = KeyEventKind::Release;
        a.key(up);
        assert_eq!(a.m.sel, 0);
    });
}

#[test]
fn a_terminal_smaller_than_the_old_clamp_still_draws() {
    let fx = Fx::new();
    fx.seed();
    fx.with(|a| {
        for (w, h) in [(20, 6), (1, 1), (99, 3), (100, 2)] {
            render(a, w, h);
        }
        assert!(render(a, 30, 8).has("radin backlog"));
    });
}

#[test]
fn the_palette_filters_actions_and_enter_runs_the_highlighted_one() {
    let fx = Fx::new();
    fx.seed();
    fx.with(|a| {
        press(a, ":");
        let s = render(a, 120, 24);
        assert!(s.has("\u{256d}\u{2500} commands ") && s.has("set priority") && s.has("quit"));
        press(a, "set pri");
        let s = render(a, 120, 24);
        assert!(s.has("set priority") && !s.has("retitle task"));
        assert_eq!(s.cursor, Some((39, 2)));
        press(a, "\r");
        assert!(render(a, 120, 24).has("priority for"));
        press(a, "\r");
    });
    assert!(fx.index().contains("\"priority\":21"));
}

#[test]
fn the_palette_closes_on_escape_and_shows_no_match() {
    let fx = Fx::new();
    fx.with(|a| {
        press(a, ":zzzz");
        assert!(render(a, 80, 24).has("no matching command"));
        assert!(press(a, "\r").is_empty());
        press(a, ":q\u{1b}");
        assert!(!a.quit());
        assert!(!render(a, 80, 24).has("\u{256d}\u{2500} commands "));
    });
}

#[test]
fn an_arrow_key_in_a_text_prompt_types_nothing() {
    let fx = Fx::new();
    fx.with(|a| {
        press(a, "/ab");
        a.key(key(KeyCode::Up, KeyModifiers::NONE));
        assert!(render(a, 80, 24).has("search: ab"));
        assert!(!render(a, 80, 24).has("search: abk"));
    });
}

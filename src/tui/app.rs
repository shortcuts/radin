use super::actions::{self, map, Key, Scope};
use super::detail;
use super::model::{
    DetView, InputThen, Mode, Model, Overlay, PickThen, Row, Sort, CATEGORIES, SPLIT_MIN,
};
use super::palette::Palette;
use super::task::parse_list;
use crate::paths::Namespace;
use crate::state::Ctx;
use crate::Out;
use crossterm::event::KeyEvent;
use std::path::PathBuf;
use std::time::UNIX_EPOCH;

const BODY_HINT: &str = "# describe the task: what changes, why, which files, how to verify";
const PRIORITIES: [&str; 7] = ["21", "13", "8", "5", "3", "2", "1"];

/// What the event loop owes the terminal after a key.
#[derive(Debug, PartialEq)]
pub enum Effect {
    None,
    Quit,
    /// Run `program path` on the normal screen, then call `App::finished`.
    Run {
        program: String,
        path: PathBuf,
        then: Then,
    },
}

#[derive(Debug, PartialEq)]
pub enum Then {
    EditBody(String),
    EditEpic(String),
    NewTask { cat: String, title: String },
    NewEpic(String),
    Page,
}

pub struct App<'a> {
    pub m: Model,
    pub pal: Palette,
    pub size: (u16, u16),
    pub dirty: bool,
    pub interrupted: bool,
    quit: bool,
    cx: &'a Ctx<'a>,
    stamp: Option<(u64, u64)>,
}

impl<'a> App<'a> {
    pub fn new(cx: &'a Ctx<'a>, pal: Palette, now: i64) -> App<'a> {
        let n = Namespace::locate(&cx.cwd);
        let _ = n.ensure_dirs();
        let mut app = App {
            m: Model::new(n.namespace_dir, now),
            pal,
            size: (80, 24),
            dirty: true,
            interrupted: false,
            quit: false,
            cx,
            stamp: None,
        };
        app.load();
        app
    }

    pub fn quit(&self) -> bool {
        self.quit
    }

    pub fn resize(&mut self, w: u16, h: u16) {
        self.size = (w, h);
        self.dirty = true;
    }

    pub fn split_on(&self) -> bool {
        self.size.0 as usize >= SPLIT_MIN
    }

    pub fn list_h(&self) -> usize {
        (self.size.1 as usize).saturating_sub(4).max(1)
    }

    fn call(&self, args: &[&str], stdin: &str) -> Out {
        (self.cx.cli)(&self.cx.cwd, args, stdin)
    }

    fn bl(&self, args: &[&str], stdin: &str) -> Out {
        let mut v = vec!["backlog"];
        v.extend_from_slice(args);
        self.call(&v, stdin)
    }

    fn env(&self, k: &str, default: &str) -> String {
        (self.cx.env)(k)
            .filter(|v| !v.is_empty())
            .unwrap_or_else(|| default.to_string())
    }

    fn index_stamp(&self) -> Option<(u64, u64)> {
        let md = std::fs::metadata(self.m.backlog_dir().join("index.jsonl")).ok()?;
        let secs = md
            .modified()
            .ok()?
            .duration_since(UNIX_EPOCH)
            .ok()?
            .as_secs();
        Some((secs, md.len()))
    }

    /// Stamps the index before the read, so a write racing it is seen on the next poll.
    fn load(&mut self) {
        self.stamp = self.index_stamp();
        let (code, out, _) = self.call(&["state", "session-get"], "");
        self.m.session = if code == 0 {
            (
                Some(out.contains("worktree\tyes")),
                Some(out.contains("branch\tyes")),
            )
        } else {
            (None, None)
        };
        let (_, out, _) = self.bl(
            &[
                "list",
                "--order",
                "created",
                "--planned",
                "--meta",
                "--created",
            ],
            "",
        );
        self.m.set_tasks(parse_list(&out));
    }

    fn load_done(&mut self) {
        let (code, out, _) = self.call(&["state", "completed-list"], "");
        self.m.done = if code == 0 {
            out.lines()
                .filter(|l| !l.is_empty())
                .map(|l| match l.split_once('\t') {
                    Some((id, commit)) => format!(" {id:<52} {commit}"),
                    None => format!(" {l}"),
                })
                .collect()
        } else {
            Vec::new()
        };
        self.m.done_sel = self.m.done_sel.min(self.m.done.len().saturating_sub(1));
    }

    /// Reloads when another shell wrote the index, keeping the selected row by identity; true when it did.
    pub fn tick(&mut self) -> bool {
        match self.index_stamp() {
            Some(s) if Some(s) != self.stamp => {}
            _ => return false,
        }
        let id = self.m.ident();
        self.load();
        self.m.reselect(id);
        self.dirty = true;
        true
    }

    fn msg(&mut self, s: impl Into<String>) {
        self.m.msg = Some(s.into());
    }

    /// Message text of a CLI call: stdout then stderr, trailing newlines trimmed, inner newlines shown as spaces.
    fn text(out: &Out) -> String {
        format!("{}{}", out.1, out.2)
            .trim_end_matches(['\n', '\r'])
            .replace('\n', " ")
    }

    /// A rejected change keeps `sel`, `top` and the collapse set and reads as a rejection, not a no-op.
    fn mutate(&mut self, verb: &str, args: &[&str], stdin: &str) {
        let mut v = vec![verb];
        v.extend_from_slice(args);
        let out = self.bl(&v, stdin);
        if out.0 == 0 {
            let shown = if verb == "add" {
                let from = if out.2.is_empty() { &out.1 } else { &out.2 };
                from.lines().next().unwrap_or("").to_string()
            } else {
                Self::text(&out)
            };
            self.msg(shown);
            self.load();
        } else {
            self.msg(format!("{verb} failed: {}", Self::text(&out)));
        }
    }

    fn toggle_session(&mut self, branch: bool) {
        let (mut wt, mut br) = (
            self.m.session.0 == Some(true),
            self.m.session.1 == Some(true),
        );
        if branch {
            br = !br;
        } else {
            wt = !wt;
        }
        let yn = |b: bool| if b { "yes" } else { "no" };
        let out = self.call(&["state", "session-set", yn(wt), yn(br)], "");
        if out.0 == 0 {
            self.m.session = (Some(wt), Some(br));
            let (name, v) = if branch {
                ("branch", br)
            } else {
                ("worktree", wt)
            };
            self.msg(format!("{name}: {}", yn(v)));
        } else {
            self.msg(Self::text(&out));
        }
    }

    fn editor_run(&self, path: PathBuf, then: Then) -> Effect {
        Effect::Run {
            program: self.env("EDITOR", "vi"),
            path,
            then,
        }
    }

    fn pager_run(&self, text: &str) -> Effect {
        let path = self.m.ns.join(format!("tui-detail.{}", std::process::id()));
        if std::fs::write(&path, text).is_err() {
            return Effect::None;
        }
        Effect::Run {
            program: self.env("PAGER", "less"),
            path,
            then: Then::Page,
        }
    }

    /// Called after the external program returns.
    pub fn finished(&mut self, then: Then) {
        self.m.clear_cache();
        self.dirty = true;
        match then {
            Then::EditBody(id) => self.msg(format!("edited {id}")),
            Then::EditEpic(e) => self.msg(format!("edited {e} description")),
            Then::Page => {
                let _ = std::fs::remove_file(
                    self.m.ns.join(format!("tui-detail.{}", std::process::id())),
                );
            }
            Then::NewEpic(e) => {
                let desc = self
                    .m
                    .backlog_dir()
                    .join("tasks")
                    .join(&e)
                    .join("DESCRIPTION.md");
                if std::fs::metadata(desc).is_ok_and(|m| m.len() > 0) {
                    self.msg(format!("created epic {e}"));
                } else {
                    self.msg(format!("created epic {e} -- description left empty"));
                }
            }
            Then::NewTask { cat, title } => self.finish_new_task(&cat, &title),
        }
    }

    fn body_path(&self) -> PathBuf {
        self.m.ns.join(format!("tui-body.{}", std::process::id()))
    }

    fn finish_new_task(&mut self, cat: &str, title: &str) {
        let path = self.body_path();
        let text = std::fs::read_to_string(&path).unwrap_or_default();
        let kept: String = text
            .split_inclusive('\n')
            .filter(|l| l.trim_end_matches(['\n', '\r']) != BODY_HINT)
            .collect();
        if kept.is_empty() {
            self.msg("new: empty body, cancelled");
        } else {
            self.mutate("add", &[cat, title], &kept);
        }
        let _ = std::fs::remove_file(path);
    }

    fn cat_choice(&mut self, k: Key) {
        self.m.overlay = Overlay::None;
        let cat = match k {
            Key::Char('f') => "feat",
            Key::Char('x') => "fix",
            Key::Char('c') => "chore",
            Key::Char('r') => "refactor",
            _ => return self.msg("new: cancelled"),
        };
        self.input("title: ", InputThen::NewTitle(cat.into()));
    }

    fn input(&mut self, label: impl Into<String>, then: InputThen) {
        self.m.overlay = Overlay::Input {
            label: label.into(),
            text: String::new(),
            then,
        };
    }

    fn submit(&mut self, then: InputThen, text: String) -> Effect {
        match then {
            InputThen::Search => {
                self.m.search = text;
                self.m.sel = 0;
                self.m.top = 0;
            }
            InputThen::NewTitle(cat) => {
                if text.is_empty() {
                    self.msg("new: empty title, cancelled");
                    return Effect::None;
                }
                let path = self.body_path();
                if std::fs::write(&path, format!("{BODY_HINT}\n")).is_err() {
                    self.msg("new: cannot create a body file");
                    return Effect::None;
                }
                return self.editor_run(path, Then::NewTask { cat, title: text });
            }
            InputThen::Retitle(id) => {
                if text.is_empty() {
                    self.msg("retitle cancelled");
                } else {
                    self.mutate("retitle", &[&id, &text], "");
                }
            }
            InputThen::ConfirmDelete(id) => {
                if ["y", "Y", "yes"].contains(&text.as_str()) {
                    self.mutate("remove", &[&id], "");
                } else {
                    self.msg("delete cancelled");
                }
            }
            InputThen::NewEpic => return self.new_epic(&text),
        }
        Effect::None
    }

    /// The epic exists before the editor runs, so an editor that writes nothing leaves a real epic with an empty description.
    fn new_epic(&mut self, epic: &str) -> Effect {
        if epic.is_empty() {
            self.msg("new epic: cancelled");
            return Effect::None;
        }
        let out = self.bl(&["epic-add", epic], "");
        if out.0 != 0 {
            self.msg(format!("epic-add failed: {}", Self::text(&out)));
            return Effect::None;
        }
        let desc = self
            .m
            .backlog_dir()
            .join("tasks")
            .join(epic)
            .join("DESCRIPTION.md");
        self.editor_run(desc, Then::NewEpic(epic.into()))
    }

    fn pick(
        &mut self,
        title: String,
        multi: bool,
        items: Vec<(String, String)>,
        marked: Vec<String>,
        then: PickThen,
    ) {
        self.m.overlay = Overlay::Pick {
            title,
            multi,
            items,
            marked,
            sel: 0,
            top: 0,
            then,
        };
    }

    fn pick_key(&mut self, k: Key) {
        let Overlay::Pick {
            multi,
            items,
            marked,
            sel,
            then,
            ..
        } = &mut self.m.overlay
        else {
            return;
        };
        let last = items.len().saturating_sub(1);
        match k {
            Key::Char('j') => *sel = (*sel + 1).min(last),
            Key::Char('k') => *sel = sel.saturating_sub(1),
            Key::Char('g') => *sel = 0,
            Key::Char('G') => *sel = last,
            Key::Char(' ') if *multi => {
                let v = items[*sel].0.clone();
                match marked.iter().position(|m| *m == v) {
                    Some(p) => {
                        marked.remove(p);
                    }
                    None => marked.push(v),
                }
            }
            Key::Enter => {
                let result = if *multi {
                    marked.clone()
                } else {
                    vec![items[*sel].0.clone()]
                };
                let then = then.clone();
                self.m.overlay = Overlay::None;
                self.picked(then, result);
            }
            Key::Char('q') | Key::Esc => {
                let then = then.clone();
                self.m.overlay = Overlay::None;
                self.msg(match then {
                    PickThen::Priority(_) => "priority cancelled",
                    PickThen::Deps(_) => "deps cancelled",
                    PickThen::Epic(_) => "epic move cancelled",
                });
            }
            _ => {}
        }
    }

    fn picked(&mut self, then: PickThen, result: Vec<String>) {
        match then {
            PickThen::Priority(id) => self.mutate("set-priority", &[&id, &result[0]], ""),
            PickThen::Epic(id) => self.mutate("epic-move", &[&id, &result[0]], ""),
            PickThen::Deps(id) => {
                let csv = result.join(",");
                self.mutate(
                    "set-deps",
                    &[&id, if csv.is_empty() { "--none" } else { &csv }],
                    "",
                );
            }
        }
    }

    fn set_priority(&mut self, ti: usize) {
        let id = self.m.tasks[ti].id.clone();
        let mut items: Vec<(String, String)> = PRIORITIES
            .iter()
            .map(|p| (p.to_string(), p.to_string()))
            .collect();
        items.push(("--none".into(), "(none) -- clear the priority".into()));
        self.pick(
            format!("priority for {id} (higher wins)"),
            false,
            items,
            vec![],
            PickThen::Priority(id),
        );
    }

    fn edit_deps(&mut self, ti: usize) {
        let me = &self.m.tasks[ti];
        let items: Vec<(String, String)> = self
            .m
            .tasks
            .iter()
            .enumerate()
            .filter(|(i, _)| *i != ti)
            .map(|(_, t)| (t.id.clone(), format!("{} -- {}", t.id, t.title)))
            .collect();
        if items.is_empty() {
            return self.msg("no other task to depend on");
        }
        let marked = me
            .deps
            .split([',', ' '])
            .filter(|s| !s.is_empty())
            .map(String::from)
            .collect();
        let id = me.id.clone();
        self.pick(
            format!("depends_on for {id}  (space toggles)"),
            true,
            items,
            marked,
            PickThen::Deps(id),
        );
    }

    fn move_epic(&mut self, ti: usize) {
        let out = self.bl(&["epics"], "");
        if out.1.is_empty() && self.m.tasks[ti].epic.is_empty() {
            return self.msg("no epics yet -- press E to create one");
        }
        let mut items = vec![(
            "--none".to_string(),
            "(none) -- move out of any epic".to_string(),
        )];
        items.extend(
            out.1
                .lines()
                .filter(|l| !l.is_empty())
                .map(|l| (l.to_string(), format!("epic: {l}"))),
        );
        let id = self.m.tasks[ti].id.clone();
        self.pick(
            format!("epic for {id}"),
            false,
            items,
            vec![],
            PickThen::Epic(id),
        );
    }

    fn input_key(&mut self, k: Key) -> Effect {
        let Overlay::Input { text, .. } = &mut self.m.overlay else {
            return Effect::None;
        };
        match k {
            Key::Char(c) => text.push(c),
            Key::Back => {
                text.pop();
            }
            Key::Enter | Key::Esc | Key::CtrlC => {
                let typed = if k == Key::Enter {
                    std::mem::take(text)
                } else {
                    String::new()
                };
                let Overlay::Input { then, .. } =
                    std::mem::replace(&mut self.m.overlay, Overlay::None)
                else {
                    return Effect::None;
                };
                return self.submit(then, typed);
            }
            _ => {}
        }
        Effect::None
    }

    fn detail_key(&mut self, k: Key) {
        let half = (self.list_h() / 2).max(1);
        match k {
            Key::Char('q') | Key::Esc => self.m.overlay = Overlay::None,
            Key::CtrlD => self.m.det_top += half,
            Key::CtrlU => self.m.det_top = self.m.det_top.saturating_sub(half),
            Key::Char(c @ ('h' | 'l')) if self.m.cur_task().is_some() => {
                self.m.det_view = if c == 'l' {
                    DetView::Plan
                } else {
                    DetView::Body
                };
                self.m.det_top = 0;
            }
            _ => {}
        }
    }

    /// Whether `k` is a motion in the current state, applying it when `apply`; a held burst coalesces into one frame.
    fn motion(&mut self, k: Key, apply: bool) -> bool {
        let done = self.m.mode == Mode::Done;
        let n = if done {
            self.m.done.len()
        } else {
            self.m.rows.len()
        };
        let narrow = done || !self.split_on();
        let ok = match k {
            Key::Char('j' | 'k' | 'g' | 'G') => true,
            Key::Char('n' | 'N') => !done,
            Key::CtrlD | Key::CtrlU | Key::Char('h' | 'l') => {
                !narrow && (!matches!(k, Key::Char(_)) || self.m.cur_task().is_some())
            }
            _ => false,
        };
        if !ok || !apply {
            return ok;
        }
        let half = (self.list_h() / 2).max(1);
        let sel = if done {
            &mut self.m.done_sel
        } else {
            &mut self.m.sel
        };
        match k {
            Key::Char('j') => *sel = (*sel + 1).min(n.saturating_sub(1)),
            Key::Char('k') => *sel = sel.saturating_sub(1),
            Key::Char('g') => *sel = 0,
            Key::Char('G') => *sel = n.saturating_sub(1),
            Key::Char('n') => self.m.search_jump(1),
            Key::Char('N') => self.m.search_jump(-1),
            Key::CtrlD => self.m.det_top += half,
            Key::CtrlU => self.m.det_top = self.m.det_top.saturating_sub(half),
            Key::Char(c) => {
                self.m.det_view = if c == 'l' {
                    DetView::Plan
                } else {
                    DetView::Body
                };
                self.m.det_top = 0;
            }
            _ => {}
        }
        true
    }

    pub fn is_motion(&mut self, k: KeyEvent) -> bool {
        matches!(self.m.overlay, Overlay::None)
            && map(k).is_some_and(|k| self.motion(k.vi(), false))
    }

    pub fn key(&mut self, ev: KeyEvent) -> Effect {
        let Some(k) = map(ev) else {
            return Effect::None;
        };
        self.dirty = true;
        if k == Key::CtrlC && !matches!(self.m.overlay, Overlay::Input { .. }) {
            self.interrupted = true;
            self.quit = true;
            return Effect::Quit;
        }
        match self.m.overlay {
            Overlay::Help(_) => self.help_key(k.vi()),
            Overlay::Palette { .. } => return self.palette_key(k),
            Overlay::Detail => self.detail_key(k.vi()),
            Overlay::Category => self.cat_choice(k),
            Overlay::Input { .. } => return self.input_key(k),
            Overlay::Pick { .. } => self.pick_key(k.vi()),
            Overlay::None => return self.list_key(k),
        }
        Effect::None
    }

    fn scope(&self) -> Scope {
        match self.m.mode {
            Mode::List => Scope::List,
            Mode::Done => Scope::Done,
        }
    }

    fn help_key(&mut self, k: Key) {
        let last = actions::help().len().saturating_sub(self.list_h());
        let Overlay::Help(top) = &mut self.m.overlay else {
            return;
        };
        match k {
            Key::Char('j') => *top = (*top + 1).min(last),
            Key::Char('k') => *top = top.saturating_sub(1),
            _ => self.m.overlay = Overlay::None,
        }
    }

    /// The palette rows the overlay shows for its current filter.
    pub fn palette_items(&self) -> Vec<&'static actions::Action> {
        match &self.m.overlay {
            Overlay::Palette { query, .. } => actions::matches(query, self.scope()),
            _ => Vec::new(),
        }
    }

    fn palette_key(&mut self, k: Key) -> Effect {
        let items = self.palette_items();
        let n = items.len();
        let Overlay::Palette { query, sel } = &mut self.m.overlay else {
            return Effect::None;
        };
        match k {
            Key::Char(c) => {
                query.push(c);
                *sel = 0;
            }
            Key::Back => {
                query.pop();
                *sel = 0;
            }
            Key::Down | Key::Tab => *sel = (*sel + 1).min(n.saturating_sub(1)),
            Key::Up => *sel = sel.saturating_sub(1),
            Key::Esc => self.m.overlay = Overlay::None,
            Key::Enter => {
                let pick = items.get(*sel).map(|a| a.id);
                self.m.overlay = Overlay::None;
                return match pick {
                    Some(id) => self.act(id),
                    None => Effect::None,
                };
            }
            _ => {}
        }
        Effect::None
    }

    fn list_key(&mut self, k: Key) -> Effect {
        if self.motion(k.vi(), true) {
            return Effect::None;
        }
        self.m.clear_cache();
        match actions::by_key(k, self.scope()) {
            Some(a) => self.act(a.id),
            None => Effect::None,
        }
    }

    /// The selected task, or a message saying the row is an epic header.
    fn need_task(&mut self) -> Option<usize> {
        let ti = self.m.cur_task();
        if ti.is_none() {
            self.msg("epic header selected -- no task here");
        }
        ti
    }

    /// Runs one registry action by id; a key and a palette pick land here alike.
    fn act(&mut self, id: &str) -> Effect {
        self.m.clear_cache();
        let done = self.m.mode == Mode::Done;
        match id {
            "quit" => return self.quit_effect(),
            "help" => self.m.overlay = Overlay::Help(0),
            "palette" => {
                self.m.overlay = Overlay::Palette {
                    query: String::new(),
                    sel: 0,
                }
            }
            "reload" if done => {
                self.load_done();
                self.msg("reloaded");
            }
            "reload" => {
                self.load();
                self.msg("reloaded");
            }
            "done" if done => self.m.mode = Mode::List,
            "done" => {
                self.m.mode = Mode::Done;
                self.load_done();
            }
            "edit" => return self.edit(),
            "open" => {
                if self.m.cur_task().is_none() {
                    self.m.toggle_collapse();
                } else if !self.split_on() {
                    self.m.det_top = 0;
                    self.m.overlay = Overlay::Detail;
                }
            }
            "view" => return self.view_task(),
            "order" => return self.view_order(),
            "new" => self.m.overlay = Overlay::Category,
            "delete" => {
                if let Some(ti) = self.need_task() {
                    let t = &self.m.tasks[ti];
                    let (label, id) = (format!("delete \"{}\"? [y/N] ", t.title), t.id.clone());
                    self.input(label, InputThen::ConfirmDelete(id));
                }
            }
            "category" => {
                if let Some(ti) = self.need_task() {
                    let t = &self.m.tasks[ti];
                    let at = CATEGORIES.iter().position(|c| *c == t.cat).unwrap_or(0);
                    let id = t.id.clone();
                    self.mutate(
                        "set-category",
                        &[&id, CATEGORIES[(at + 1) % CATEGORIES.len()]],
                        "",
                    );
                }
            }
            "retitle" => {
                if let Some(ti) = self.need_task() {
                    let t = &self.m.tasks[ti];
                    let (label, id) = (format!("new title (was \"{}\"): ", t.title), t.id.clone());
                    self.input(label, InputThen::Retitle(id));
                }
            }
            "priority" => {
                if let Some(ti) = self.need_task() {
                    self.set_priority(ti);
                }
            }
            "deps" => {
                if let Some(ti) = self.need_task() {
                    self.edit_deps(ti);
                }
            }
            "epic-move" => {
                if let Some(ti) = self.need_task() {
                    self.move_epic(ti);
                }
            }
            "epic-new" => self.input("new epic id (slug, empty cancels): ", InputThen::NewEpic),
            "worktree" => self.toggle_session(false),
            "branch" => self.toggle_session(true),
            "sort-created" | "sort-priority" | "sort-category" | "sort-title" => {
                self.m.sort = match id {
                    "sort-priority" => Sort::Priority,
                    "sort-category" => Sort::Category,
                    "sort-title" => Sort::Title,
                    _ => Sort::Created,
                };
                self.m.sort_tasks();
                self.m.build_rows();
                self.msg(format!("sort:{}", self.m.sort.name()));
            }
            "search" => self.input("search: ", InputThen::Search),
            _ => {}
        }
        Effect::None
    }

    fn quit_effect(&mut self) -> Effect {
        self.quit = true;
        Effect::Quit
    }

    fn edit(&mut self) -> Effect {
        if let Some(ti) = self.m.cur_task() {
            let t = &self.m.tasks[ti];
            return self.editor_run(self.m.task_path(t), Then::EditBody(t.id.clone()));
        }
        match self.m.rows.get(self.m.sel) {
            Some(Row::Epic(e)) => {
                let path = self
                    .m
                    .backlog_dir()
                    .join("tasks")
                    .join(e)
                    .join("DESCRIPTION.md");
                self.editor_run(path, Then::EditEpic(e.clone()))
            }
            _ => Effect::None,
        }
    }

    fn view_task(&mut self) -> Effect {
        if self.m.rows.is_empty() {
            return Effect::None;
        }
        let text = detail::compose(&self.m, &|a| self.bl(a, ""));
        self.pager_run(&text)
    }

    /// `o` pages `order --report` verbatim: the format stays the CLI's business.
    fn view_order(&mut self) -> Effect {
        let out = self.bl(&["order", "--report"], "");
        if out.0 != 0 {
            self.msg(format!("order failed: {}", Self::text(&out)));
            return Effect::None;
        }
        self.pager_run(&format!("{}{}", out.1, out.2))
    }
}

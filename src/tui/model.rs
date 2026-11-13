use super::detail::{self, DetLine};
use super::task::Task;
use std::collections::HashMap;
use std::path::PathBuf;

pub const CATEGORIES: [&str; 4] = ["feat", "fix", "chore", "refactor"];
pub const SPLIT_MIN: usize = 100;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Mode {
    List,
    Done,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Sort {
    Created,
    Priority,
    Category,
    Title,
}

impl Sort {
    pub fn name(self) -> &'static str {
        match self {
            Sort::Created => "created",
            Sort::Priority => "priority",
            Sort::Category => "category",
            Sort::Title => "title",
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum DetView {
    Body,
    Plan,
}

#[derive(Clone, PartialEq, Eq, Debug)]
pub enum Row {
    Task(usize),
    Epic(String),
}

#[derive(Clone, Debug)]
pub enum InputThen {
    NewTitle(String),
    Retitle(String),
    Search,
    NewEpic,
    ConfirmDelete(String),
    /// Task id, then the `set-meta` field the typed values go to.
    Meta(String, String),
    AddPlan(String),
    ConfirmEpicRemove(String),
    ConfirmReconcile,
}

#[derive(Clone, Debug)]
pub enum PickThen {
    Priority(String),
    Deps(String),
    Epic(String),
    MetaField(String),
    MetaValue(String, String),
    EpicDeps(String),
}

#[derive(Clone, Debug)]
pub enum Overlay {
    None,
    /// The help overlay, scrolled to this line.
    Help(usize),
    /// The `:` command palette: the filter text and the highlighted match.
    Palette {
        query: String,
        sel: usize,
    },
    Detail,
    Category,
    Input {
        label: String,
        text: String,
        then: InputThen,
    },
    Pick {
        title: String,
        multi: bool,
        items: Vec<(String, String)>,
        marked: Vec<String>,
        sel: usize,
        top: usize,
        then: PickThen,
    },
}

/// One `state steps-list` row: the task's place in the current radin-batch run.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Step {
    pub order: String,
    pub status: String,
    pub attempts: String,
    pub note: String,
}

/// One `state completed-list --long` row.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct DoneRow {
    pub id: String,
    pub commit: String,
    pub ts: String,
    pub title: String,
}

/// What the detail pane needs beyond the list load, fetched for the selected row only.
#[derive(Clone, Debug, Default)]
pub struct Extra {
    /// The row it was fetched for: a task id, `epic:<name>` or `done:<id>`.
    pub key: String,
    /// Open decisions of a task, the description of an epic, or `completed-show` lines of a done task.
    pub lines: Vec<String>,
}

struct DetCache {
    key: String,
    view: DetView,
    width: usize,
    lines: Vec<DetLine>,
}

pub struct Model {
    pub tasks: Vec<Task>,
    pub rows: Vec<Row>,
    pub sel: usize,
    pub top: usize,
    pub mode: Mode,
    pub overlay: Overlay,
    pub sort: Sort,
    pub det_view: DetView,
    pub det_top: usize,
    pub session: (Option<bool>, Option<bool>),
    pub collapsed: Vec<String>,
    pub search: String,
    pub msg: Option<String>,
    pub done: Vec<DoneRow>,
    pub steps: HashMap<String, Step>,
    /// Every epic, including one with no task yet, with the csv of epics it depends on.
    pub epics: Vec<(String, String)>,
    pub extra: Extra,
    pub done_sel: usize,
    pub done_top: usize,
    pub now: i64,
    pub ns: PathBuf,
    /// Detail documents built since start; a motion key must not raise it.
    pub det_builds: usize,
    det_row: Option<String>,
    cache: Option<DetCache>,
}

fn prio_num(p: &str) -> i64 {
    let digits: String = p.chars().take_while(char::is_ascii_digit).collect();
    digits.parse().unwrap_or(0)
}

fn cat_index(c: &str) -> usize {
    CATEGORIES
        .iter()
        .position(|k| *k == c)
        .unwrap_or(CATEGORIES.len())
}

impl Model {
    pub fn new(ns: PathBuf, now: i64) -> Model {
        Model {
            tasks: Vec::new(),
            rows: Vec::new(),
            sel: 0,
            top: 0,
            mode: Mode::List,
            overlay: Overlay::None,
            sort: Sort::Created,
            det_view: DetView::Body,
            det_top: 0,
            session: (None, None),
            collapsed: Vec::new(),
            search: String::new(),
            msg: None,
            done: Vec::new(),
            steps: HashMap::new(),
            epics: Vec::new(),
            extra: Extra::default(),
            done_sel: 0,
            done_top: 0,
            now,
            ns,
            det_builds: 0,
            det_row: None,
            cache: None,
        }
    }

    pub fn backlog_dir(&self) -> PathBuf {
        self.ns.join("backlog")
    }

    pub fn set_tasks(&mut self, tasks: Vec<Task>) {
        self.tasks = tasks;
        self.cache = None;
        self.sort_tasks();
        self.build_rows();
    }

    pub fn sort_tasks(&mut self) {
        let by = self.sort;
        self.tasks.sort_by(|a, b| {
            let ord = match by {
                Sort::Created => std::cmp::Ordering::Equal,
                Sort::Priority => {
                    let (x, y) = (!a.prio.is_empty(), !b.prio.is_empty());
                    y.cmp(&x).then_with(|| match x {
                        true => prio_num(&b.prio).cmp(&prio_num(&a.prio)),
                        false => std::cmp::Ordering::Equal,
                    })
                }
                Sort::Category => cat_index(&a.cat).cmp(&cat_index(&b.cat)),
                Sort::Title => a
                    .title
                    .to_ascii_lowercase()
                    .cmp(&b.title.to_ascii_lowercase()),
            };
            ord.then(a.ord.cmp(&b.ord))
        });
    }

    /// Ungrouped tasks first, then one collapsible header per epic in name order followed by its children; an empty epic still gets its header.
    pub fn build_rows(&mut self) {
        let mut rows: Vec<Row> = (0..self.tasks.len())
            .filter(|&i| self.tasks[i].epic.is_empty())
            .map(Row::Task)
            .collect();
        let mut epics: Vec<&str> = self
            .tasks
            .iter()
            .filter(|t| !t.epic.is_empty())
            .map(|t| t.epic.as_str())
            .chain(self.epics.iter().map(|(e, _)| e.as_str()))
            .collect();
        epics.sort_unstable();
        epics.dedup();
        for e in epics {
            rows.push(Row::Epic(e.to_string()));
            if !self.collapsed.iter().any(|c| c == e) {
                rows.extend(
                    (0..self.tasks.len())
                        .filter(|&i| self.tasks[i].epic == e)
                        .map(Row::Task),
                );
            }
        }
        self.rows = rows;
        self.sel = self.sel.min(self.rows.len().saturating_sub(1));
        self.det_row = None;
    }

    pub fn cur_task(&self) -> Option<usize> {
        match self.rows.get(self.sel)? {
            Row::Task(i) => Some(*i),
            Row::Epic(_) => None,
        }
    }

    pub fn cur_epic(&self) -> Option<&str> {
        match self.rows.get(self.sel)? {
            Row::Epic(e) => Some(e),
            Row::Task(_) => None,
        }
    }

    pub fn search_hit(&self, t: &Task) -> bool {
        !self.search.is_empty()
            && format!("{} {}", t.id, t.title)
                .to_ascii_lowercase()
                .contains(&self.search.to_ascii_lowercase())
    }

    pub fn kids(&self, epic: &str) -> usize {
        self.tasks.iter().filter(|t| t.epic == epic).count()
    }

    pub fn epic_deps(&self, epic: &str) -> &str {
        self.epics
            .iter()
            .find(|(e, _)| e == epic)
            .map_or("", |(_, d)| d.as_str())
    }

    /// The key `Extra` is fetched under for the selected row.
    pub fn extra_key(&self) -> String {
        if self.mode == Mode::Done {
            return self
                .done
                .get(self.done_sel)
                .map_or(String::new(), |d| format!("done:{}", d.id));
        }
        match self.rows.get(self.sel) {
            Some(Row::Task(i)) => self.tasks[*i].id.clone(),
            Some(Row::Epic(e)) => format!("epic:{e}"),
            None => String::new(),
        }
    }

    /// Next (dir 1) or previous (dir -1) row matching the search, wrapping; a match in a collapsed epic has no row.
    pub fn search_jump(&mut self, dir: isize) {
        let n = self.rows.len() as isize;
        if self.search.is_empty() || n == 0 {
            return;
        }
        for step in 1..=n {
            let i = (self.sel as isize + dir * step).rem_euclid(n) as usize;
            if let Row::Task(t) = self.rows[i] {
                if self.search_hit(&self.tasks[t]) {
                    self.sel = i;
                    return;
                }
            }
        }
    }

    pub fn toggle_collapse(&mut self) {
        let Some(e) = self.cur_epic().map(String::from) else {
            return;
        };
        match self.collapsed.iter().position(|c| *c == e) {
            Some(p) => {
                self.collapsed.remove(p);
            }
            None => self.collapsed.push(e),
        }
        self.build_rows();
    }

    pub fn task_path(&self, t: &Task) -> PathBuf {
        self.backlog_dir().join(&t.file)
    }

    pub fn clear_cache(&mut self) {
        self.cache = None;
    }

    /// A move resets the detail scroll from the render path, so no key handler has to.
    pub fn sync_det_scroll(&mut self) {
        let k = self.extra_key();
        if self.det_row.as_ref() != Some(&k) {
            self.det_row = Some(k);
            self.det_top = 0;
        }
    }

    /// The detail document for the selected row, built once per (row, view, width); `App::sync_extra` runs first.
    pub fn detail(&mut self, width: usize) -> &[DetLine] {
        let width = width.max(1);
        let key = self.extra_key();
        let fresh = self
            .cache
            .as_ref()
            .is_some_and(|c| c.key == key && c.view == self.det_view && c.width == width);
        if !fresh {
            self.det_builds += 1;
            self.cache = Some(DetCache {
                key,
                view: self.det_view,
                width,
                lines: detail::build(self, width),
            });
        }
        &self.cache.as_ref().unwrap().lines
    }

    /// The selected row's identity (task id, or epic name), which survives a reload.
    pub fn ident(&self) -> Option<Result<String, String>> {
        Some(match self.rows.get(self.sel)? {
            Row::Task(i) => Ok(self.tasks[*i].id.clone()),
            Row::Epic(e) => Err(e.clone()),
        })
    }

    pub fn reselect(&mut self, id: Option<Result<String, String>>) {
        let found = self.rows.iter().position(|r| match (&id, r) {
            (Some(Ok(id)), Row::Task(i)) => self.tasks[*i].id == *id,
            (Some(Err(e)), Row::Epic(n)) => e == n,
            _ => false,
        });
        if let Some(i) = found {
            self.sel = i;
        }
    }
}

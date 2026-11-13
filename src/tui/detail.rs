use super::model::{DetView, Mode, Model};
use super::text::{clean, fit, md_line, wrap_at, MdStyle};
use crate::Out;
use std::fs;

const MAX_LINES: usize = 1024;
const LABEL: usize = 10;

#[derive(Clone, Debug, PartialEq)]
pub struct DetLine {
    pub text: String,
    pub rule: bool,
    pub style: MdStyle,
    /// Leading columns painted dim: a field line's label.
    pub label: usize,
    /// Column of the active name in the `body  plan` marker line.
    pub mark: Option<usize>,
}

struct Doc {
    width: usize,
    lines: Vec<DetLine>,
}

impl Doc {
    fn full(&self) -> bool {
        self.lines.len() >= MAX_LINES
    }

    fn rule(&mut self) {
        if !self.full() {
            self.lines.push(DetLine {
                text: String::new(),
                rule: true,
                style: MdStyle::Plain,
                label: 0,
                mark: None,
            });
        }
    }

    /// One markdown source line, wrapped at the pane width; each continuation indents to the content column.
    fn line(&mut self, src: &str, indent_override: Option<usize>) {
        let (text, style, indent) = md_line(&clean(src));
        let indent = indent_override.unwrap_or(indent);
        let avail = self.width.saturating_sub(indent).max(8);
        let mut t = text.as_str();
        let mut first = true;
        while !self.full() {
            let mut cut = wrap_at(t, if first { self.width } else { avail });
            // A field's first break must fall after its label, or a long unbroken value leaves the label alone.
            if first && indent_override.is_some_and(|i| i > 0) && cut <= indent {
                cut = fit(t, self.width).len().max(1);
            }
            let pad = if first {
                String::new()
            } else {
                " ".repeat(indent)
            };
            self.lines.push(DetLine {
                text: format!("{pad}{}", &t[..cut]),
                rule: false,
                style,
                label: 0,
                mark: None,
            });
            first = false;
            t = t[cut..].trim_start_matches(' ');
            if t.is_empty() {
                return;
            }
        }
    }

    fn field(&mut self, label: &str, val: &str) {
        let first = self.lines.len();
        self.line(&format!("{label:<LABEL$} {val}"), Some(LABEL + 1));
        if let Some(l) = self.lines.get_mut(first) {
            l.label = LABEL;
        }
    }

    fn file(&mut self, path: &std::path::Path) -> bool {
        match fs::read_to_string(path) {
            Ok(t) => {
                for l in t.lines() {
                    self.line(l, None);
                }
                true
            }
            Err(_) => false,
        }
    }
}

/// A `meta` plan path is absolute or relative to the namespace dir, so the pane and the composed document open the same file.
fn plan_abs(m: &Model, p: &str) -> std::path::PathBuf {
    if p.starts_with('/') {
        p.into()
    } else {
        m.ns.join(p)
    }
}

fn plans(meta: &[String]) -> impl Iterator<Item = &str> {
    meta.iter().filter_map(|l| l.strip_prefix("plan\t"))
}

/// The label a `backlog meta` key reads as in the pane.
fn meta_label(k: &str) -> &str {
    match k {
        "skill" | "skills" => "skill",
        "location" => "location",
        "complexity" => "complexity",
        "exclusive" => "exclusive",
        "origin" => "origin",
        "facts" => "facts",
        "acceptance" => "accept",
        other => other,
    }
}

/// `id -- title` for a task id, or the id alone when it left the backlog.
fn titled(m: &Model, id: &str) -> String {
    match m.tasks.iter().find(|t| t.id == id) {
        Some(t) => format!("{id} -- {}", t.title),
        None => format!("{id} (not in the backlog)"),
    }
}

impl Doc {
    /// One field per value: the label on the first line only.
    fn fields(&mut self, label: &str, vals: impl IntoIterator<Item = String>) {
        for (i, v) in vals.into_iter().enumerate() {
            self.field(if i == 0 { label } else { "" }, &v);
        }
    }
}

fn task_doc(d: &mut Doc, m: &Model, ti: usize) {
    let t = &m.tasks[ti];
    let meta = |k: &str| -> Vec<String> {
        t.meta
            .iter()
            .filter_map(|l| l.split_once('\t').filter(|(mk, _)| *mk == k))
            .map(|(_, v)| v.to_string())
            .collect()
    };
    d.line(&format!("# {}", t.title), None);
    d.rule();
    d.field("category", &t.cat);
    d.field("id", &t.id);
    d.field(
        "priority",
        if t.prio.is_empty() { "unset" } else { &t.prio },
    );
    let needed = meta("planning").iter().any(|v| v == "needed");
    d.field(
        "planned",
        match (t.planned, needed) {
            (true, _) => "yes",
            (false, true) => "no -- planning needed",
            (false, false) => "no",
        },
    );
    if let Some(s) = m.steps.get(&t.id) {
        d.field(
            "run",
            &format!("{}  order {}  attempts {}", s.status, s.order, s.attempts),
        );
        if !s.note.is_empty() {
            d.field("note", &s.note);
        }
    }
    if !t.created.is_empty() {
        d.field("created", &t.created);
    }
    if !t.epic.is_empty() {
        d.field("epic", &t.epic);
    }
    let deps: Vec<String> = t
        .deps
        .split([',', ' '])
        .filter(|s| !s.is_empty())
        .map(|id| titled(m, id))
        .collect();
    d.fields("depends", deps);
    let blocks: Vec<String> = m
        .tasks
        .iter()
        .filter(|o| o.deps.split([',', ' ']).any(|x| x == t.id))
        .map(|o| titled(m, &o.id))
        .collect();
    d.fields("blocks", blocks);
    for k in [
        "complexity",
        "location",
        "skill",
        "origin",
        "exclusive",
        "facts",
        "acceptance",
    ] {
        d.fields(meta_label(k), meta(k));
    }
    let shown = [
        "plan",
        "planning",
        "complexity",
        "location",
        "skill",
        "origin",
        "exclusive",
        "facts",
        "acceptance",
    ];
    for l in &t.meta {
        let (k, v) = l.split_once('\t').unwrap_or((l, ""));
        if !shown.contains(&k) {
            d.field(k, v);
        }
    }
    if m.extra.key == t.id {
        d.fields("decide", m.extra.lines.iter().map(|q| format!("? {q}")));
    }
    let plan = m.det_view == DetView::Plan;
    let at = d.lines.len();
    d.line("body  plan", Some(0));
    if let Some(l) = d.lines.get_mut(at) {
        l.mark = Some(if plan { 6 } else { 0 });
    }
    d.rule();
    d.line("", None);
    if !plan {
        d.file(&m.task_path(t));
        return;
    }
    let mut any = false;
    for rel in plans(&t.meta) {
        d.line(&format!("### {rel}"), None);
        d.line("", None);
        if !d.file(&plan_abs(m, rel)) {
            d.line("(plan file missing)", None);
        }
        d.line("", None);
        any = true;
    }
    if !any {
        d.line("(no plan yet -- run /radin-plan)", None);
    }
}

fn epic_doc(d: &mut Doc, m: &Model, e: &str) {
    let kids: Vec<&super::task::Task> = m.tasks.iter().filter(|t| t.epic == e).collect();
    d.line(&format!("# epic: {e}"), None);
    d.rule();
    let planned = kids.iter().filter(|t| t.planned).count();
    d.field("tasks", &format!("{} ({planned} planned)", kids.len()));
    let deps = m.epic_deps(e);
    if !deps.is_empty() {
        d.field("depends", &deps.replace(',', ", "));
    }
    let by: Vec<&str> = m
        .epics
        .iter()
        .filter(|(_, d)| d.split(',').any(|x| x == e))
        .map(|(n, _)| n.as_str())
        .collect();
    if !by.is_empty() {
        d.field("needed by", &by.join(", "));
    }
    d.rule();
    d.line("", None);
    if m.extra.key == format!("epic:{e}") && !m.extra.lines.is_empty() {
        for l in &m.extra.lines {
            d.line(l, None);
        }
        d.line("", None);
    }
    d.line("## tasks", None);
    d.line("", None);
    if kids.is_empty() {
        d.line("(no task yet -- press m on a task to move it here)", None);
    }
    for t in kids {
        let status = m
            .steps
            .get(&t.id)
            .map_or(String::new(), |s| format!("  [{}]", s.status));
        let prio = if t.prio.is_empty() { "\u{b7}" } else { &t.prio };
        d.line(
            &format!("{prio:>3}  {:<9} {}{status}", t.cat, t.title),
            Some(15),
        );
    }
}

fn done_doc(d: &mut Doc, m: &Model) {
    let Some(r) = m.done.get(m.done_sel) else {
        return;
    };
    d.line(
        &format!("# {}", if r.title.is_empty() { &r.id } else { &r.title }),
        None,
    );
    d.rule();
    if m.extra.key != format!("done:{}", r.id) {
        return;
    }
    for l in &m.extra.lines {
        let (k, v) = l.split_once('\t').unwrap_or((l, ""));
        if !v.is_empty() {
            d.field(k, v);
        }
    }
}

pub fn build(m: &Model, width: usize) -> Vec<DetLine> {
    let mut d = Doc {
        width,
        lines: Vec::new(),
    };
    if m.mode == Mode::Done {
        done_doc(&mut d, m);
    } else if let Some(ti) = m.cur_task() {
        task_doc(&mut d, m, ti);
    } else if let Some(e) = m.cur_epic() {
        epic_doc(&mut d, m, e);
    }
    d.lines
}

/// The whole human-side composition `v` pages: everything the agent-facing stack keeps behind pointers.
pub fn compose(m: &Model, bl: &dyn Fn(&[&str]) -> Out) -> String {
    let desc = |epic: &str| {
        let (code, out, _) = bl(&["epic-show", epic]);
        if code == 0 && !out.is_empty() {
            out
        } else {
            "(no description)\n".to_string()
        }
    };
    let mut f = String::new();
    let Some(ti) = m.cur_task() else {
        let e = m.cur_epic().unwrap_or("");
        f += &format!("# epic: {e}\n\n{}\n## Tasks\n\n", desc(e));
        for t in m.tasks.iter().filter(|t| t.epic == e) {
            f += &format!("- {}\n", t.title);
        }
        return f;
    };
    let t = &m.tasks[ti];
    let prio = if t.prio.is_empty() {
        "(unset)"
    } else {
        &t.prio
    };
    f += &format!(
        "# {}\n\nid: {}\ncategory: {}\npriority: {prio}\n\n## Task\n\n",
        t.title, t.id, t.cat
    );
    f += &fs::read_to_string(m.task_path(t)).unwrap_or_default();
    f += "\n## Epic\n\n";
    if t.epic.is_empty() {
        f += "(ungrouped)\n";
    } else {
        f += &format!("{}\n\n{}", t.epic, desc(&t.epic));
    }
    f += "\n## Plans\n\n";
    let mut any = false;
    for p in plans(&t.meta) {
        f += &format!("### {p}\n\n");
        f += &fs::read_to_string(plan_abs(m, p)).unwrap_or_else(|_| "(plan file missing)\n".into());
        f += "\n";
        any = true;
    }
    if !any {
        f += "(no plan)\n";
    }
    f += "\n## Depends on\n\n";
    if t.deps.is_empty() {
        return f + "(none)\n";
    }
    for tok in t.deps.split([',', ' ']).filter(|s| !s.is_empty()) {
        let title = m
            .tasks
            .iter()
            .find(|x| x.id == tok)
            .map(|x| x.title.clone())
            .or_else(|| {
                let (_, out, _) = bl(&["find", tok]);
                out.lines()
                    .next()
                    .and_then(|l| l.split('\t').nth(2))
                    .map(String::from)
            })
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| "(unknown id)".into());
        f += &format!("- {tok} -- {title}\n");
    }
    f
}

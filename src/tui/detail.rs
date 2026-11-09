use super::model::{DetView, Model};
use super::text::{clean, md_line, wrap_at, MdStyle};
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
            let cut = wrap_at(t, if first { self.width } else { avail });
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

pub fn build(m: &Model, width: usize) -> Vec<DetLine> {
    let mut d = Doc {
        width,
        lines: Vec::new(),
    };
    match m.cur_task() {
        Some(ti) => {
            let t = &m.tasks[ti];
            d.line(&format!("# {}", t.title), None);
            d.rule();
            d.field("category", &t.cat);
            d.field("id", &t.id);
            d.field(
                "priority",
                if t.prio.is_empty() { "unset" } else { &t.prio },
            );
            d.field("planned", if t.planned { "yes" } else { "no" });
            if !t.created.is_empty() {
                d.field("created", &t.created);
            }
            if !t.epic.is_empty() {
                d.field("epic", &t.epic);
            }
            if !t.deps.is_empty() {
                d.field("depends", &t.deps);
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
                let mut shown = false;
                for l in t.meta.iter().filter(|l| !l.is_empty()) {
                    let (k, v) = l.split_once('\t').unwrap_or((l, ""));
                    d.field(k, v);
                    shown = true;
                }
                if shown {
                    d.line("", None);
                }
                d.file(&m.task_path(t));
            } else {
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
        }
        None => {
            if let Some(e) = m.cur_epic() {
                d.line(&format!("# epic: {e}"), None);
                d.rule();
                d.line("", None);
                for t in m.tasks.iter().filter(|t| t.epic == e) {
                    d.line(&format!("- {}", t.title), None);
                }
            }
        }
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

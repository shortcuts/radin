use crossterm::event::{KeyCode, KeyEvent, KeyEventKind, KeyModifiers};

/// A key after the Ctrl mapping, so the handlers see single characters.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Key {
    Char(char),
    Up,
    Down,
    Left,
    Right,
    Enter,
    Tab,
    Esc,
    Back,
    CtrlD,
    CtrlU,
    CtrlC,
    Other,
}

impl Key {
    /// Arrows read as their vi letters wherever a list moves; a text field keeps them apart from typed letters.
    pub fn vi(self) -> Key {
        match self {
            Key::Up => Key::Char('k'),
            Key::Down => Key::Char('j'),
            Key::Left => Key::Char('h'),
            Key::Right => Key::Char('l'),
            k => k,
        }
    }

    fn label(self) -> String {
        match self {
            Key::Char(' ') => "space".into(),
            Key::Char(c) => c.to_string(),
            Key::Enter => "enter".into(),
            Key::Tab => "Tab".into(),
            Key::Esc => "esc".into(),
            Key::CtrlD => "^d".into(),
            Key::CtrlU => "^u".into(),
            k => format!("{k:?}").to_ascii_lowercase(),
        }
    }
}

pub fn map(k: KeyEvent) -> Option<Key> {
    if k.kind == KeyEventKind::Release {
        return None;
    }
    let ctrl = k.modifiers.contains(KeyModifiers::CONTROL);
    Some(match k.code {
        KeyCode::Char('c') if ctrl => Key::CtrlC,
        KeyCode::Char('d') if ctrl => Key::CtrlD,
        KeyCode::Char('u') if ctrl => Key::CtrlU,
        KeyCode::Char(_) if ctrl => Key::Other,
        KeyCode::Char(c) => Key::Char(c),
        KeyCode::Up => Key::Up,
        KeyCode::Down => Key::Down,
        KeyCode::Left => Key::Left,
        KeyCode::Right => Key::Right,
        KeyCode::Enter => Key::Enter,
        KeyCode::Tab => Key::Tab,
        KeyCode::Esc => Key::Esc,
        KeyCode::Backspace => Key::Back,
        _ => Key::Other,
    })
}

/// Where an action runs: `Nav` rows are motions `App::motion` owns, listed for help only.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Scope {
    Nav,
    List,
    Done,
    Any,
}

#[derive(Debug)]
pub struct Action {
    pub id: &'static str,
    pub keys: &'static [Key],
    /// Replaces the key text for a key family.
    pub shown: Option<&'static str>,
    pub label: &'static str,
    pub group: &'static str,
    pub scope: Scope,
    /// One word for the footer.
    pub hint: Option<&'static str>,
}

impl Action {
    const fn new(
        id: &'static str,
        keys: &'static [Key],
        label: &'static str,
        group: &'static str,
        scope: Scope,
    ) -> Action {
        Action {
            id,
            keys,
            shown: None,
            label,
            group,
            scope,
            hint: None,
        }
    }

    const fn shown(mut self, s: &'static str) -> Action {
        self.shown = Some(s);
        self
    }

    const fn hint(mut self, w: &'static str) -> Action {
        self.hint = Some(w);
        self
    }

    pub fn keys_label(&self) -> String {
        match self.shown {
            Some(s) => s.into(),
            None => self
                .keys
                .iter()
                .map(|k| k.label())
                .collect::<Vec<_>>()
                .join(" / "),
        }
    }

    fn applies(&self, scope: Scope) -> bool {
        self.scope == scope || self.scope == Scope::Any
    }
}

const fn ch(c: char) -> Key {
    Key::Char(c)
}

use Scope::{Any, List, Nav};

/// The one list of what the TUI does: key dispatch, footer, help and the `:` palette all read it.
pub const ACTIONS: &[Action] = &[
    Action::new("down", &[ch('j'), Key::Down], "next row", "move", Nav).shown("j / down"),
    Action::new("up", &[ch('k'), Key::Up], "previous row", "move", Nav)
        .shown("k / up")
        .hint("move"),
    Action::new("ends", &[ch('g'), ch('G')], "first / last row", "move", Nav).shown("g / G"),
    Action::new(
        "scroll",
        &[Key::CtrlD, Key::CtrlU],
        "scroll the detail half a pane",
        "move",
        Nav,
    )
    .shown("^d / ^u"),
    Action::new(
        "views",
        &[ch('h'), ch('l')],
        "detail: task body / plan files",
        "move",
        Nav,
    )
    .shown("h / l"),
    Action::new(
        "matches",
        &[ch('n'), ch('N')],
        "next / previous search match",
        "move",
        Nav,
    )
    .shown("n / N"),
    Action::new(
        "open",
        &[Key::Enter],
        "epic: collapse/expand; task under 100 columns: detail overlay",
        "move",
        List,
    )
    .hint("open"),
    Action::new("search", &[ch('/')], "search id and title", "move", List).hint("search"),
    Action::new("new", &[ch('a')], "new task", "task", List).hint("new"),
    Action::new(
        "edit",
        &[ch('e')],
        "edit body (epic: DESCRIPTION.md)",
        "task",
        List,
    )
    .hint("edit"),
    Action::new("retitle", &[ch('r')], "retitle task", "task", List),
    Action::new("category", &[ch('c')], "next category", "task", List),
    Action::new("priority", &[ch('p')], "set priority", "task", List),
    Action::new("deps", &[ch('D')], "edit depends_on", "task", List),
    Action::new("delete", &[ch('d')], "delete task", "task", List),
    Action::new(
        "epic-move",
        &[ch('m')],
        "move task into / out of an epic",
        "epic",
        List,
    ),
    Action::new("epic-new", &[ch('E')], "new epic", "epic", List),
    Action::new("view", &[ch('v')], "page the composed detail", "view", List).hint("detail"),
    Action::new(
        "order",
        &[ch('o')],
        "page the execution order",
        "view",
        List,
    ),
    Action::new(
        "sort-created",
        &[ch('A')],
        "sort by creation order",
        "view",
        List,
    ),
    Action::new(
        "sort-priority",
        &[ch('P')],
        "sort by priority",
        "view",
        List,
    ),
    Action::new(
        "sort-category",
        &[ch('C')],
        "sort by category",
        "view",
        List,
    ),
    Action::new("sort-title", &[ch('T')], "sort by title", "view", List),
    Action::new("done", &[Key::Tab], "toggle the Done view", "view", Any).hint("done"),
    Action::new(
        "worktree",
        &[ch('w')],
        "toggle the worktree answer",
        "run",
        List,
    ),
    Action::new(
        "branch",
        &[ch('b')],
        "toggle the branch answer",
        "run",
        List,
    ),
    Action::new("reload", &[ch('R')], "reload from disk", "app", Any),
    Action::new("palette", &[ch(':')], "command palette", "app", Any).hint("commands"),
    Action::new("help", &[ch('?')], "keys and legend", "app", Any).hint("keys"),
    Action::new("quit", &[ch('q')], "quit", "app", Any).hint("quit"),
];

pub fn by_key(k: Key, scope: Scope) -> Option<&'static Action> {
    ACTIONS
        .iter()
        .find(|a| a.applies(scope) && a.keys.contains(&k))
}

/// True when every char of `q` appears in `s` in order.
fn subsequence(q: &str, s: &str) -> bool {
    let mut it = s.chars();
    q.chars().all(|c| it.any(|x| x == c))
}

/// Palette rows for `query`: substring hits on label or id first, then subsequence hits, registry order within each.
pub fn matches(query: &str, scope: Scope) -> Vec<&'static Action> {
    let q = query.to_ascii_lowercase();
    let hay = |a: &Action| format!("{} {}", a.id, a.label).to_ascii_lowercase();
    let pool = ACTIONS
        .iter()
        .filter(|a| a.applies(scope) && a.scope != Nav && a.id != "palette");
    let (mut sub, mut seq) = (Vec::new(), Vec::new());
    for a in pool {
        let h = hay(a);
        if h.contains(&q) {
            sub.push(a);
        } else if subsequence(&q, &h) {
            seq.push(a);
        }
    }
    sub.extend(seq);
    sub
}

pub fn footer(scope: Scope) -> String {
    ACTIONS
        .iter()
        .filter(|a| a.hint.is_some() && (a.applies(scope) || (a.scope == Nav)))
        .map(|a| {
            let k = match a.id {
                "up" => "j/k".to_string(),
                _ => a.keys_label(),
            };
            format!("{k} {}", a.hint.unwrap_or(""))
        })
        .collect::<Vec<_>>()
        .join("  ")
}

const LEGEND: &str = include_str!("help.txt");

/// The help overlay: one section per group in registry order, then the legend.
pub fn help() -> Vec<String> {
    let mut out = vec!["radin tui keys".to_string()];
    let mut group = "";
    for a in ACTIONS {
        if a.group != group {
            group = a.group;
            out.push(String::new());
            out.push(group.to_string());
        }
        out.push(format!("  {:<13} {}", a.keys_label(), a.label));
    }
    out.push(String::new());
    out.extend(LEGEND.lines().map(String::from));
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use Scope::Done;

    #[test]
    fn every_key_dispatches_to_one_action_per_scope() {
        for scope in [List, Done] {
            let mut seen: Vec<Key> = Vec::new();
            for a in ACTIONS
                .iter()
                .filter(|a| a.applies(scope) || a.scope == Nav)
            {
                for k in a.keys {
                    assert!(!seen.contains(k), "{k:?} bound twice in {scope:?}");
                    seen.push(*k);
                }
            }
        }
    }

    #[test]
    fn substring_hits_rank_before_subsequence_hits() {
        let ids: Vec<&str> = matches("pri", List).iter().map(|a| a.id).collect();
        assert_eq!(ids[0], "priority");
        assert!(ids.contains(&"sort-priority"));
        assert!(matches("zzz", List).is_empty());
    }

    #[test]
    fn the_done_scope_hides_list_only_actions() {
        assert!(matches("", Done).iter().all(|a| a.scope == Any));
        assert!(by_key(ch('d'), Done).is_none());
        assert_eq!(by_key(ch('d'), List).map(|a| a.id), Some("delete"));
    }
}

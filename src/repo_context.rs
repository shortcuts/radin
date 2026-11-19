//! Static budget of the files a session loads from the working repo and the user's own config.
use crate::context::{split_skill, tokens};
use crate::stats::{row, table, Rows};
use crate::Ctx;
use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};

/// Claude Code stops following `@imports` after five hops.
const IMPORT_DEPTH: usize = 5;

pub(crate) struct Item {
    scope: &'static str,
    label: String,
    tokens: usize,
    via: String,
}

/// A loaded file with its text, for the checks that read it.
pub(crate) struct Loaded {
    pub scope: &'static str,
    pub label: String,
    pub path: PathBuf,
    pub text: String,
}

/// Every `@path` token outside a fence or a code span, as a path that exists.
fn imports(text: &str, dir: &Path, home: &Path) -> Vec<PathBuf> {
    let mut v = Vec::new();
    let mut fenced = false;
    for line in text.lines() {
        if line.trim_start().starts_with("```") {
            fenced = !fenced;
        }
        if fenced {
            continue;
        }
        for seg in line.split('`').step_by(2) {
            for w in seg.split_whitespace() {
                let Some(p) = w.strip_prefix('@').filter(|p| !p.is_empty()) else {
                    continue;
                };
                let path = match p.strip_prefix("~/") {
                    Some(rest) => home.join(rest),
                    None => dir.join(p),
                };
                if path.is_file() {
                    v.push(path);
                }
            }
        }
    }
    v
}

struct Walk<'a> {
    cwd: &'a Path,
    home: &'a Path,
    seen: BTreeSet<PathBuf>,
    items: Vec<Item>,
    files: Vec<Loaded>,
}

impl Walk<'_> {
    fn label(&self, p: &Path, scope: &str) -> String {
        let rel = if scope == "user" {
            p.strip_prefix(self.home)
                .ok()
                .map(|r| Path::new("~").join(r))
        } else {
            p.strip_prefix(self.cwd).ok().map(Path::to_path_buf)
        };
        rel.unwrap_or_else(|| p.to_path_buf()).display().to_string()
    }

    /// Adds a file and, recursively, every file it imports. A file seen twice counts once.
    fn file(&mut self, p: &Path, scope: &'static str, via: &str, depth: usize) {
        let Ok(text) = fs::read_to_string(p) else {
            return;
        };
        if !self
            .seen
            .insert(fs::canonicalize(p).unwrap_or(p.to_path_buf()))
        {
            return;
        }
        let label = self.label(p, scope);
        self.files.push(Loaded {
            scope,
            label: label.clone(),
            path: p.to_path_buf(),
            text: text.clone(),
        });
        self.items.push(Item {
            scope,
            label,
            tokens: tokens(&text),
            via: via.into(),
        });
        if depth < IMPORT_DEPTH {
            let name = p
                .file_name()
                .map_or(String::new(), |n| n.to_string_lossy().into());
            for q in imports(&text, p.parent().unwrap_or(Path::new(".")), self.home) {
                self.file(&q, scope, &format!("via {name}"), depth + 1);
            }
        }
    }

    fn rules(&mut self, dir: &Path, scope: &'static str) {
        let Ok(rd) = fs::read_dir(dir) else { return };
        let mut es: Vec<_> = rd.flatten().map(|e| e.path()).collect();
        es.sort();
        for p in es {
            if p.is_dir() {
                self.rules(&p, scope);
            } else if p.extension().is_some_and(|e| e == "md") {
                self.file(&p, scope, "", 0);
            }
        }
    }

    /// One row per skill the model sees listed: its name and description, never its body.
    fn skills(&mut self, dir: &Path, scope: &'static str) {
        let Ok(rd) = fs::read_dir(dir) else { return };
        let mut es: Vec<_> = rd.flatten().map(|e| e.path()).collect();
        es.sort();
        for d in es {
            let Ok(text) = fs::read_to_string(d.join("SKILL.md")) else {
                continue;
            };
            let id = fs::canonicalize(d.join("SKILL.md")).unwrap_or(d.clone());
            if !self.seen.insert(id) {
                continue;
            }
            let name = d
                .file_name()
                .map_or(String::new(), |n| n.to_string_lossy().into());
            let s = split_skill(&name, &text);
            if s.model_invoked {
                self.items.push(Item {
                    scope,
                    label: format!("skill {name}"),
                    tokens: s.listed,
                    via: "listing only".into(),
                });
            }
        }
    }
}

pub(crate) fn load(c: &Ctx) -> (Vec<Item>, Vec<Loaded>) {
    // a cwd comes back canonical, so compare it with canonical paths: macOS `/var` is `/private/var`
    let canon = |p: PathBuf| fs::canonicalize(&p).unwrap_or(p);
    let home = canon(c.home.clone());
    let cfg = (c.env)("CLAUDE_CONFIG_DIR")
        .filter(|d| !d.is_empty())
        .map_or(home.join(".claude"), PathBuf::from);
    let cfg = canon(cfg);
    let codex = (c.env)("CODEX_HOME")
        .filter(|d| !d.is_empty())
        .map_or(home.join(".codex"), PathBuf::from);
    let codex = canon(codex);
    let mut w = Walk {
        cwd: &c.cwd,
        home: &home,
        seen: BTreeSet::new(),
        items: Vec::new(),
        files: Vec::new(),
    };
    for dir in c.cwd.ancestors() {
        for f in ["CLAUDE.md", "CLAUDE.local.md", "AGENTS.md"] {
            w.file(&dir.join(f), "project", "", 0);
        }
        // `~/.claude` is the user config, counted below
        if dir == home {
            continue;
        }
        w.file(&dir.join(".claude/CLAUDE.md"), "project", "", 0);
        w.rules(&dir.join(".claude/rules"), "project");
        w.skills(&dir.join(".claude/skills"), "project");
        w.skills(&dir.join(".agents/skills"), "project");
    }
    w.file(&cfg.join("CLAUDE.md"), "user", "", 0);
    w.rules(&cfg.join("rules"), "user");
    w.skills(&cfg.join("skills"), "user");
    w.file(&codex.join("AGENTS.md"), "user", "", 0);
    (w.items, w.files)
}

pub fn measure(c: &Ctx) -> String {
    let (mut items, _) = load(c);
    items.sort_by_key(|i| std::cmp::Reverse(i.tokens));
    let mut rows = Rows::from([row(["item", "scope", "tokens", "note"])]);
    for i in &items {
        rows.push(row([&i.label, i.scope, &i.tokens.to_string(), &i.via]));
    }
    let sum = |scope: &str| -> usize {
        items
            .iter()
            .filter(|i| scope.is_empty() || i.scope == scope)
            .map(|i| i.tokens)
            .sum()
    };
    for (label, scope) in [
        ("total project", "project"),
        ("total user", "user"),
        ("total", ""),
    ] {
        rows.push(row([label, scope, &sum(scope).to_string(), ""]));
    }
    table(
        "repo: auto-loaded (est. tokens; every session pays these before the first prompt)",
        &rows,
    )
}

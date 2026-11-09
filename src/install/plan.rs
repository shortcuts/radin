use super::assets::host;
use super::{Session, Stop};
use sha2::{Digest, Sha256};
use std::fs;
use std::path::{Path, PathBuf};

#[derive(Clone, Copy, PartialEq, Debug)]
pub enum St {
    Free,
    Current,
    Edited,
    Unowned,
}

pub struct Row {
    pub st: St,
    pub path: PathBuf,
    pub render: &'static str,
    pub unit: Option<PathBuf>,
}

pub fn sha256_file(p: &Path) -> Option<String> {
    let b = fs::read(p).ok()?;
    Some(
        Sha256::digest(b)
            .iter()
            .map(|x| format!("{x:02x}"))
            .collect(),
    )
}

pub fn path_taken(p: &Path) -> bool {
    p.symlink_metadata().is_ok()
}

impl Session<'_> {
    pub(super) fn skills_dir(&self, render: &str) -> PathBuf {
        if render == "claude" {
            self.claude.join("skills")
        } else {
            self.home.join(".agents/skills")
        }
    }

    pub(super) fn renders(&self) -> Vec<&'static str> {
        let mut out: Vec<&'static str> = vec![];
        for id in &self.selected {
            let r = host(id).unwrap().2;
            if !out.contains(&r) {
                out.push(r);
            }
        }
        out
    }

    pub(super) fn neutral_paths(&self) -> Vec<PathBuf> {
        let mut v: Vec<PathBuf> = crate::shipped::shipped()
            .lib
            .iter()
            .map(|f| self.rh.join("lib").join(f))
            .collect();
        v.push(self.rh.join("bin/radin"));
        v
    }

    pub(super) fn render_paths(&self, render: &str) -> Vec<PathBuf> {
        let s = crate::shipped::shipped();
        let mut v: Vec<PathBuf> = s
            .hostlib
            .iter()
            .map(|f| self.rh.join(format!("hosts/{render}/lib/{f}")))
            .collect();
        for name in &s.skills {
            let base = self.skills_dir(render).join(name);
            v.extend(
                self.assets
                    .skill_files(name)
                    .into_iter()
                    .map(|(rel, _)| base.join(rel)),
            );
        }
        v
    }

    pub(super) fn opencode_paths(&self) -> Vec<PathBuf> {
        super::opencode::KINDS
            .iter()
            .map(|(k, _)| self.opencode_dir.join(format!("agents/radin-{k}.md")))
            .collect()
    }

    pub(super) fn owned_paths(&self) -> Vec<PathBuf> {
        let mut v = self.neutral_paths();
        for r in self.renders() {
            v.extend(self.render_paths(r));
        }
        if self.is_selected("opencode") {
            v.extend(self.opencode_paths());
        }
        v
    }

    fn rel(&self, p: &Path) -> String {
        p.strip_prefix(&self.home)
            .unwrap_or(p)
            .to_string_lossy()
            .into_owned()
    }

    fn legacy_owned(&self, rel: &str) -> bool {
        let Some(m) = self.prev.as_ref().filter(|_| self.legacy) else {
            return false;
        };
        if let Some(s) = rel.strip_prefix(".claude/skills/") {
            return m
                .skills
                .iter()
                .any(|n| Some(n.as_str()) == s.split('/').next());
        }
        if let Some(f) = rel.strip_prefix(".radin/hosts/claude/lib/") {
            return m.hostlib.iter().any(|n| n == f);
        }
        false
    }

    /// The recorded digest of a path under $HOME, `Some("")` for a legacy owner, `None` when unowned.
    pub(super) fn owned_digest(&self, p: &Path) -> Option<String> {
        let rel = self.rel(p);
        match self.owned.get(&rel) {
            Some(d) => Some(d.clone()),
            None => self.legacy_owned(&rel).then(String::new),
        }
    }

    pub(super) fn classify(&self, p: &Path) -> St {
        if !path_taken(p) {
            return St::Free;
        }
        let Some(want) = self.owned_digest(p) else {
            return St::Unowned;
        };
        let regular = p.symlink_metadata().is_ok_and(|m| m.is_file());
        if want.is_empty() || (regular && sha256_file(p).as_deref() == Some(want.as_str())) {
            St::Current
        } else {
            St::Edited
        }
    }

    fn skill_dir_of(&self, p: &Path) -> Option<PathBuf> {
        for base in [self.claude.join("skills"), self.home.join(".agents/skills")] {
            if let Ok(s) = p.strip_prefix(&base) {
                return Some(base.join(s.components().next()?));
            }
        }
        None
    }

    /// One row per host-specific target. A skill directory with no owned SKILL.md is unowned as a whole.
    pub(super) fn preflight(&mut self) {
        let mut plan = vec![];
        for r in self.renders() {
            for p in self.render_paths(r) {
                let mut st = self.classify(&p);
                let mut unit = Some(p.clone());
                if let Some(d) = self.skill_dir_of(&p).filter(|d| d.is_dir()) {
                    if matches!(self.classify(&d.join("SKILL.md")), St::Free | St::Unowned) {
                        st = St::Unowned;
                        unit = Some(d);
                    }
                }
                plan.push(Row {
                    st,
                    path: p,
                    render: r,
                    unit,
                });
            }
        }
        self.plan = plan;
    }

    /// Without --force, a render with an unowned target is left out, and so is every host that reads it.
    pub(super) fn drop_blocked(&mut self) -> Result<(), Stop> {
        if !self.o.force {
            for r in self.renders() {
                let mut units: Vec<PathBuf> = self
                    .plan
                    .iter()
                    .filter(|x| x.st == St::Unowned && x.render == r)
                    .filter_map(|x| x.unit.clone())
                    .collect();
                units.sort();
                units.dedup();
                if units.is_empty() {
                    continue;
                }
                let (ids, keep): (Vec<&str>, Vec<&str>) = self
                    .selected
                    .iter()
                    .partition(|id| host(id).unwrap().2 == r);
                let ids = ids.join(" ");
                if self.o.dry {
                    for u in &units {
                        println!("conflict {}", u.display());
                    }
                    println!("skip host {ids}");
                } else {
                    let msg = format!(
                        "{} exists and radin did not install it (and {} more): {ids} skipped; --force backs it up",
                        units[0].display(),
                        units.len() - 1
                    );
                    self.ui.warn(&msg);
                    if self.ui.loud {
                        for u in &units {
                            println!("    {}", u.display());
                        }
                    }
                }
                if self.o.update {
                    self.held
                        .extend(self.selected.iter().filter(|id| host(id).unwrap().2 == r));
                }
                self.selected = keep.into_iter().map(|s| host(s).unwrap().0).collect();
                self.plan.retain(|x| x.render != r);
            }
        }
        if self.selected.is_empty() {
            return Err(self.end_empty());
        }
        Ok(())
    }

    pub(super) fn end_empty(&self) -> Stop {
        self.ui
            .err("every selected host was skipped: nothing is installed.");
        Stop::Done(1)
    }

    pub(super) fn dry_run_report(&self) {
        let list = |v: Vec<PathBuf>| {
            for p in v {
                println!("write {}", p.display());
            }
        };
        self.ui.info(&format!(
            "hosts: {}{}",
            self.selected.join(" "),
            if self.o.force { " (--force)" } else { "" }
        ));
        list(self.neutral_paths());
        let mut backed: Vec<&PathBuf> = vec![];
        for x in &self.plan {
            if x.st == St::Edited && !self.o.force {
                println!("keep {}", x.path.display());
                continue;
            }
            if let (St::Unowned | St::Edited, Some(u)) = (x.st, &x.unit) {
                if !backed.contains(&u) {
                    println!("backup {}", u.display());
                    backed.push(u);
                }
            }
            println!("write {}", x.path.display());
        }
        list(vec![
            self.rh.join("install_root"),
            self.rh.join("manifest.json"),
            self.home.join(".local/bin/radin"),
        ]);
        if self.is_selected("claude") {
            list(vec![
                self.claude.join("CLAUDE.md"),
                self.claude.join("settings.json"),
            ]);
        }
        self.dry_run_commands();
    }
}

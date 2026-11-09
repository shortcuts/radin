use super::assets::host;
use super::plan::{path_taken, St};
use super::{Session, Stop};
use crate::render::{apply_tokens, render, Tokens};
use crate::Host;
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};

type Staged = Vec<(String, Vec<u8>)>;

const SURVIVORS: [(&str, &str); 4] = [
    ("RADIN_MODEL_", "sub-agent models"),
    ("RADIN_EFFORT_", "sub-agent efforts"),
    ("RADIN_CLI", "CLI invocation"),
    ("RADIN_LIB", "lib path"),
];

fn text_of(rel: &str, b: &[u8]) -> Result<String, String> {
    String::from_utf8(b.to_vec()).map_err(|_| format!("{rel}: not UTF-8"))
}

impl Session<'_> {
    /// Renders every file of one host in memory. A forbidden string in any file fails the whole render.
    fn render_host(&self, r: &str, t: &Tokens) -> Result<Staged, String> {
        let rules = self.assets.rules(r)?;
        let s = crate::shipped::shipped();
        let mut out: Staged = vec![];
        for f in &s.hostlib {
            let rel = format!("lib/{f}");
            let b = self
                .assets
                .lib(f)
                .ok_or_else(|| format!("{rel}: unreadable"))?;
            let text = text_of(&rel, &b)?;
            let body = if text.is_empty() {
                text
            } else {
                render(&text, &rel, &rules)?
            };
            out.push((rel, apply_tokens(&body, t).into_bytes()));
        }
        for name in &s.skills {
            for (rel, b) in self.assets.skill_files(name) {
                let key = format!("{name}/{rel}");
                let bytes = if rel == "SKILL.md" {
                    let text = text_of(&key, &b)?;
                    let body = if text.is_empty() {
                        text
                    } else {
                        render(&text, &format!("skills/{key}"), &rules)?
                    };
                    apply_tokens(&body, t).into_bytes()
                } else if rel.ends_with(".md") {
                    apply_tokens(&text_of(&key, &b)?, t).into_bytes()
                } else {
                    b
                };
                out.push((key, bytes));
            }
        }
        Ok(out)
    }

    fn check_tokens(&self, r: &str, files: &Staged) -> Result<Option<String>, Stop> {
        let hit = |pat: &str| {
            files
                .iter()
                .find(|(_, b)| String::from_utf8_lossy(b).contains(pat))
                .map(|f| f.0.clone())
        };
        for (pat, what) in SURVIVORS {
            if r != "claude" && (pat == "RADIN_MODEL_" || pat == "RADIN_EFFORT_") {
                continue;
            }
            if let Some(f) = hit(pat) {
                self.ui.err(&format!(
                    "failed to write the {what} into {f}. Re-run the installer."
                ));
                return Err(Stop::Fail(1));
            }
        }
        if r == "agents" {
            let f = hit("RADIN_MODEL_").or_else(|| hit("RADIN_EFFORT_"));
            return Ok(f.map(|f| format!("{f}: model or effort token survives")));
        }
        Ok(None)
    }

    pub(super) fn backup_path(&mut self, p: &Path) -> Result<(), Stop> {
        let rel = p
            .strip_prefix(&self.home)
            .unwrap_or(p)
            .to_string_lossy()
            .into_owned();
        let base = self.rh.join("backups").join(&self.stamp);
        let mut dst = base.join(&rel);
        let mut n = 0;
        while path_taken(&dst) {
            n += 1;
            dst = base.join(format!("{rel}.{n}"));
        }
        fs::create_dir_all(dst.parent().unwrap())?;
        fs::rename(p, &dst)?;
        let drel = dst
            .strip_prefix(&self.home)
            .unwrap_or(&dst)
            .to_string_lossy()
            .into_owned();
        self.backups.push((drel, rel));
        self.ui
            .info(&format!("backed up {} to {}", p.display(), dst.display()));
        Ok(())
    }

    fn dst_of(&self, r: &str, rel: &str) -> PathBuf {
        match rel.strip_prefix("lib/") {
            Some(f) => self.rh.join(format!("hosts/{r}/lib/{f}")),
            None => self.skills_dir(r).join(rel),
        }
    }

    fn publish(&mut self, r: &str, files: Staged) -> Result<(), Stop> {
        let verdict: HashMap<PathBuf, (St, Option<PathBuf>)> = self
            .plan
            .iter()
            .rev()
            .map(|x| (x.path.clone(), (x.st, x.unit.clone())))
            .collect();
        let (mut written, mut same, mut kept) = (0, 0, 0);
        for (rel, bytes) in files {
            let dst = self.dst_of(r, &rel);
            let (st, unit) = verdict.get(&dst).cloned().unwrap_or((St::Current, None));
            if st != St::Free && st != St::Unowned && fs::read(&dst).is_ok_and(|b| b == bytes) {
                same += 1;
                continue;
            }
            if st == St::Edited && !self.o.force {
                let d = self.owned_digest(&dst).unwrap_or_default();
                let rel_home = dst
                    .strip_prefix(&self.home)
                    .unwrap_or(&dst)
                    .to_string_lossy()
                    .into_owned();
                self.kept.push((rel_home, d));
                self.ui.warn(&format!(
                    "kept {}: you edited it (--force replaces it)",
                    dst.display()
                ));
                kept += 1;
                continue;
            }
            if let Some(u) =
                unit.filter(|u| matches!(st, St::Unowned | St::Edited) && path_taken(u))
            {
                self.backup_path(&u)?;
            }
            fs::create_dir_all(dst.parent().unwrap())?;
            fs::write(&dst, bytes)?;
            written += 1;
        }
        self.ui.ok(&format!(
            "{r} render installed to {}: {written} written, {same} unchanged, {kept} kept",
            self.ui.bold(&self.skills_dir(r).display().to_string())
        ));
        Ok(())
    }

    fn drop_render(&mut self, r: &str, why: &str) -> Result<(), Stop> {
        self.ui.warn(&format!("{r} render failed: {why}"));
        let (gone, keep): (Vec<&str>, Vec<&str>) = self
            .selected
            .iter()
            .partition(|id| host(id).unwrap().2 == r);
        for id in &gone {
            self.ui.warn(&format!("{id} is left out of this install."));
            if self.o.update {
                self.held.push(id);
            }
        }
        self.selected = keep;
        if self.selected.is_empty() {
            return Err(self.end_empty());
        }
        Ok(())
    }

    /// Renders in memory first, so one bad file leaves its hosts out and writes nothing.
    pub(super) fn install_render(&mut self, r: &'static str) -> Result<(), Stop> {
        let t = Tokens {
            host: if r == "claude" {
                Host::Claude
            } else {
                Host::Agents
            },
            model_major: self.major.clone(),
            model_minor: self.minor.clone(),
            effort_major: String::new(),
            effort_minor: String::new(),
            cli: self.cli_value.clone(),
            lib_dir: self
                .rh
                .join(format!("hosts/{r}/lib"))
                .to_string_lossy()
                .into_owned(),
        };
        let files = match self.render_host(r, &t) {
            Ok(f) => match self.check_tokens(r, &f)? {
                None => f,
                Some(e) => return self.drop_render(r, &e),
            },
            Err(e) => return self.drop_render(r, &e),
        };
        self.publish(r, files)?;
        if r == "claude" {
            let s = crate::shipped::shipped();
            for n in s.renamed_skills.iter().chain(&s.retired_skills) {
                let dir = self.claude.join("skills").join(n);
                let named = fs::read_to_string(dir.join("SKILL.md"))
                    .is_ok_and(|t| t.lines().any(|l| l == format!("name: {n}")));
                if named {
                    fs::remove_dir_all(dir)?;
                }
            }
        }
        for id in self.selected.clone() {
            let h = host(id).unwrap();
            if h.2 == r && r == "agents" && self.which(h.3).is_none() {
                self.ui.warn(&format!(
                    "{} CLI not found: radin's own files are installed, companion steps skipped",
                    h.3
                ));
            }
        }
        Ok(())
    }
}

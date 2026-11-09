use crate::render::Rules;
use include_dir::{include_dir, Dir};
use std::fs;
use std::path::{Path, PathBuf};

static SKILLS: Dir = include_dir!("$CARGO_MANIFEST_DIR/skills");
static LIB: Dir = include_dir!("$CARGO_MANIFEST_DIR/lib");
static HOSTS: Dir = include_dir!("$CARGO_MANIFEST_DIR/hosts");

/// (id, label, render, cli). A render is `claude` or `agents` (Codex and opencode read the same one).
pub const HOSTS_TABLE: [(&str, &str, &str, &str); 3] = [
    ("claude", "Claude Code", "claude", "claude"),
    ("codex", "Codex CLI", "agents", "codex"),
    ("opencode", "opencode", "agents", "opencode"),
];

pub fn host_ids() -> Vec<&'static str> {
    HOSTS_TABLE.iter().map(|h| h.0).collect()
}

pub fn host(id: &str) -> Option<&'static (&'static str, &'static str, &'static str, &'static str)> {
    HOSTS_TABLE.iter().find(|h| h.0 == id)
}

/// The files radin ships. `RADIN_ASSETS` names a source tree that replaces the embedded copy, for dev runs and tests.
pub struct Assets {
    dir: Option<PathBuf>,
}

fn walk(d: &Dir, prefix: &str, out: &mut Vec<(String, Vec<u8>)>) {
    for f in d.files() {
        let rel = f.path().to_string_lossy();
        out.push((
            rel.strip_prefix(prefix).unwrap_or(&rel).to_string(),
            f.contents().to_vec(),
        ));
    }
    for sub in d.dirs() {
        walk(sub, prefix, out);
    }
}

fn walk_disk(root: &Path, dir: &Path, out: &mut Vec<(String, Vec<u8>)>) {
    let Ok(rd) = fs::read_dir(dir) else { return };
    for e in rd.flatten() {
        let p = e.path();
        if p.is_dir() {
            walk_disk(root, &p, out);
        } else if let Ok(b) = fs::read(&p) {
            let rel = p.strip_prefix(root).unwrap().to_string_lossy().into_owned();
            out.push((rel, b));
        }
    }
}

impl Assets {
    pub fn new(env: &dyn Fn(&str) -> Option<String>) -> Assets {
        Assets {
            dir: env("RADIN_ASSETS")
                .filter(|d| !d.is_empty())
                .map(PathBuf::from),
        }
    }

    /// Every file of one shipped skill, relative to the skill directory, sorted.
    pub fn skill_files(&self, name: &str) -> Vec<(String, Vec<u8>)> {
        let mut out = Vec::new();
        match &self.dir {
            Some(d) => {
                let root = d.join("skills").join(name);
                walk_disk(&root, &root, &mut out);
            }
            None => {
                if let Some(d) = SKILLS.get_dir(name) {
                    walk(d, &format!("{name}/"), &mut out);
                }
            }
        }
        out.sort_by(|a, b| a.0.cmp(&b.0));
        out
    }

    pub fn lib(&self, name: &str) -> Option<Vec<u8>> {
        match &self.dir {
            Some(d) => fs::read(d.join("lib").join(name)).ok(),
            None => LIB.get_file(name).map(|f| f.contents().to_vec()),
        }
    }

    pub fn opencode_agent(&self) -> Option<String> {
        let b = match &self.dir {
            Some(d) => fs::read(d.join("hosts/opencode-agent.md")).ok(),
            None => HOSTS
                .get_file("opencode-agent.md")
                .map(|f| f.contents().to_vec()),
        }?;
        String::from_utf8(b).ok()
    }

    pub fn rules(&self, render: &str) -> Result<Rules, String> {
        match &self.dir {
            Some(d) => Rules::from_dir(&d.join("lib"), render),
            None => Rules::embedded(render),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::shipped::shipped;

    #[test]
    fn every_shipped_name_resolves_to_bytes() {
        let a = Assets::new(&|_| None);
        let s = shipped();
        for n in &s.skills {
            let files = a.skill_files(n);
            assert!(files.iter().any(|f| f.0 == "SKILL.md"), "{n}");
        }
        for n in s.hostlib.iter().chain(&s.lib) {
            assert!(a.lib(n).is_some_and(|b| !b.is_empty()), "{n}");
        }
        assert!(a.opencode_agent().unwrap().contains("RADIN_AGENT_KIND"));
    }
}

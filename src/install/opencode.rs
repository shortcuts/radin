use super::plan::St;
use super::{Session, Stop};
use crate::jsonedit;
use std::fs;

/// (kind, description), one agent file each. No ":" or "#", so the YAML value stays plain.
pub const KINDS: [(&str, &str); 7] = [
    ("planning", "radin leaf that plans one backlog entry"),
    (
        "execution",
        "radin leaf that implements one planned task and commits it",
    ),
    ("review", "radin leaf that reviews a staged diff"),
    ("debug", "radin leaf that diagnoses a failed task"),
    ("factfind", "radin leaf that answers one factual question"),
    ("gate", "radin leaf that gates a finished session"),
    ("merge", "radin leaf that merges task branches"),
];

impl Session<'_> {
    pub(super) fn install_opencode_agents(&mut self) -> Result<(), Stop> {
        let tpl = self
            .assets
            .opencode_agent()
            .ok_or_else(|| Stop::Err("hosts/opencode-agent.md: missing".into()))?;
        fs::create_dir_all(self.opencode_dir.join("agents"))?;
        for (kind, desc) in KINDS {
            let p = self.opencode_dir.join(format!("agents/radin-{kind}.md"));
            let body = tpl
                .replace("RADIN_AGENT_DESC", desc)
                .replace("RADIN_AGENT_KIND", kind);
            let st = self.classify(&p);
            if matches!(st, St::Edited | St::Unowned) {
                if !self.o.force {
                    if st == St::Edited {
                        let rel = p
                            .strip_prefix(&self.home)
                            .unwrap_or(&p)
                            .to_string_lossy()
                            .into_owned();
                        self.kept
                            .push((rel, self.owned_digest(&p).unwrap_or_default()));
                    }
                    self.ui.warn(&format!(
                        "kept {}: you edited it (--force replaces it)",
                        p.display()
                    ));
                    continue;
                }
                self.backup_path(&p)?;
            }
            fs::write(&p, body)?;
        }
        self.ui.ok(&format!(
            "opencode agents written to {}",
            self.ui
                .bold(&self.opencode_dir.join("agents").display().to_string())
        ));
        Ok(())
    }

    /// Goes in after the companions: plugin add and cbm both write opencode's global config.
    pub(super) fn opencode_allow_rule(&mut self) -> Result<(), Stop> {
        let f = self.opencode_config.clone();
        fs::create_dir_all(&self.rh)?;
        let real = fs::canonicalize(&self.rh).unwrap_or_else(|_| self.rh.clone());
        let mut globs = vec![format!("{}/**", self.rh.display())];
        if real != self.rh {
            globs.push(format!("{}/**", real.display()));
        }
        let refs: Vec<&str> = globs.iter().map(String::as_str).collect();
        let ok = if !f.exists() && self.opencode_dir.join("opencode.jsonc").exists() {
            false
        } else {
            fs::create_dir_all(f.parent().unwrap())?;
            jsonedit::edit_ext_dir(&f.to_string_lossy(), true, &refs).0 == 0
        };
        if ok {
            self.opencode_allow = f.display().to_string();
        } else {
            let rules: Vec<String> = globs.iter().map(|g| format!("\"{g}\":\"allow\"")).collect();
            self.ui.warn(&format!(
                "could not edit the opencode config safely: merge this rule into {}:",
                f.display()
            ));
            println!(
                "{{\"permission\":{{\"external_directory\":{{{}}}}}}}",
                rules.join(",")
            );
        }
        Ok(())
    }
}

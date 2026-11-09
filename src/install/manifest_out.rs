use super::assets::{host, host_ids};
use super::plan::sha256_file;
use super::{Session, Stop};
use crate::manifest::Manifest;
use serde_json::{Map, Value};
use std::path::PathBuf;

impl Session<'_> {
    fn files_map(&self) -> Map<String, Value> {
        let rel = |p: &PathBuf| {
            p.strip_prefix(&self.home)
                .unwrap_or(p)
                .to_string_lossy()
                .into_owned()
        };
        let mut files = Map::new();
        for p in self.owned_paths() {
            let k = rel(&p);
            let kept = self
                .kept
                .iter()
                .find(|(r, _)| *r == k)
                .map(|(_, d)| d.clone());
            if let Some(d) = kept.or_else(|| sha256_file(&p)).filter(|d| !d.is_empty()) {
                files.insert(k, Value::String(d));
            }
        }
        let mut seen: Vec<&str> = vec![];
        let mut held: Vec<PathBuf> = vec![];
        for id in &self.held {
            let r = host(id).unwrap().2;
            if !seen.contains(&r) {
                seen.push(r);
                held.extend(self.render_paths(r));
            }
            if *id == "opencode" {
                held.extend(self.opencode_paths());
            }
        }
        for p in held {
            let k = rel(&p);
            if let Some(d) = self.owned.get(&k) {
                files.insert(k, Value::String(d.clone()));
            }
        }
        files
    }

    fn plugin_on(&mut self, id: &str) -> bool {
        self.which("claude").is_some() && self.plugin_state(id) == Some("enabled")
    }

    pub(super) fn write_manifest(&mut self) -> Result<(), Stop> {
        self.plugin_list = None;
        let s = crate::shipped::shipped();
        let held_ids = self.held.clone();
        let held = |id: &str| held_ids.contains(&id);
        let hosts: Vec<String> = host_ids()
            .into_iter()
            .filter(|id| self.is_selected(id) || held(id))
            .map(String::from)
            .collect();
        let prev = self.prev.take().unwrap_or_default();
        let agents_clis: Vec<String> = hosts
            .iter()
            .filter_map(|id| {
                host(id)
                    .filter(|h| h.2 == "agents")
                    .map(|h| h.3.to_string())
            })
            .collect();
        let mut backups = prev.backups.clone();
        for (k, v) in &self.backups {
            backups.insert(k.clone(), Value::String(v.clone()));
        }
        let companion = {
            let mut m = Map::new();
            m.insert("rtk".into(), self.which("rtk").is_some().into());
            m.insert(
                "codebase-memory-mcp".into(),
                self.cbm_bin().is_some().into(),
            );
            for (name, id, _) in [
                ("caveman", "caveman@caveman", ()),
                ("ponytail", "ponytail@ponytail", ()),
                (
                    "mattpocock-skills",
                    "mattpocock-skills@claude-plugins-official",
                    (),
                ),
            ] {
                let on = self.plugin_on(id);
                m.insert(name.into(), on.into());
            }
            for n in ["unslop", "technical-writing"] {
                m.insert(n.into(), self.pstack_owned.iter().any(|x| x == n).into());
            }
            m
        };
        let files = self.files_map();
        let mut skills: Vec<String> = s.skills.iter().map(|x| x.to_string()).collect();
        skills.push("thermo-nuclear".into());
        let sel = |id: &str, now: bool, was: bool| {
            if self.is_selected(id) || !held(id) {
                now
            } else {
                was
            }
        };
        let m = Manifest {
            manifest_version: 2,
            version: env!("CARGO_PKG_VERSION").into(),
            installed_at: crate::telemetry::now_utc(),
            package_manager: self.pkg.clone(),
            install_root: self.rh.display().to_string(),
            wave_cap: self.wave_cap,
            model_planning: self.major.clone(),
            model_execution: self.major.clone(),
            model_review: self.major.clone(),
            model_debug: self.major.clone(),
            model_factfind: self.minor.clone(),
            model_low: self.minor.clone(),
            claude_md_guidance: sel("claude", self.claude_md, prev.claude_md_guidance),
            codex_guidance: sel("codex", self.codex_guidance, prev.codex_guidance),
            opencode_guidance: sel("opencode", self.opencode_guidance, prev.opencode_guidance),
            opencode_allow: if held("opencode") {
                prev.opencode_allow.clone()
            } else {
                self.opencode_allow.clone()
            },
            cbm_agent_config: sel("claude", self.cbm_cfg, prev.cbm_agent_config),
            cli_on_path: self.cli_on_path,
            hosts,
            agents_clis,
            skills,
            lib: s.lib.iter().map(|x| x.to_string()).collect(),
            hostlib: s.hostlib.iter().map(|x| x.to_string()).collect(),
            agents_skills: self.agents_owned.clone(),
            companion_tools: companion,
            files,
            backups,
            ..Manifest::default()
        };
        std::fs::create_dir_all(&self.rh)?;
        std::fs::write(
            self.rh.join("install_root"),
            format!("{}\n", self.rh.display()),
        )?;
        m.write(&self.rh.join("manifest.json"))?;
        self.ui.ok(&format!(
            "manifest written to {}",
            self.ui
                .bold(&self.rh.join("manifest.json").display().to_string())
        ));
        Ok(())
    }
}

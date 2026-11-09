use serde::Deserialize;
use serde_json::{Map, Value};
use std::fs;
use std::io;
use std::path::Path;

fn wave_cap() -> u32 {
    2
}

#[derive(Debug, Default, Deserialize, PartialEq)]
#[serde(default)]
pub struct Manifest {
    pub manifest_version: u32,
    pub version: String,
    pub installed_at: String,
    pub package_manager: String,
    pub install_root: String,
    #[serde(default = "wave_cap")]
    pub wave_cap: u32,
    pub model_planning: String,
    pub model_execution: String,
    pub model_review: String,
    pub model_debug: String,
    pub model_factfind: String,
    pub model_low: String,
    pub effort_planning: String,
    pub effort_execution: String,
    pub effort_review: String,
    pub effort_debug: String,
    pub effort_factfind: String,
    pub effort_low: String,
    pub claude_md_guidance: bool,
    pub codex_guidance: bool,
    pub opencode_guidance: bool,
    pub opencode_allow: String,
    pub cbm_agent_config: bool,
    pub cli_on_path: bool,
    pub hosts: Vec<String>,
    pub agents_clis: Vec<String>,
    pub skills: Vec<String>,
    pub lib: Vec<String>,
    pub hostlib: Vec<String>,
    pub agents_skills: Vec<String>,
    pub companion_tools: Map<String, Value>,
    pub files: Map<String, Value>,
    pub backups: Map<String, Value>,
}

fn js<T: serde::Serialize + ?Sized>(v: &T) -> String {
    serde_json::to_string(v).unwrap()
}

fn list(v: &[String]) -> String {
    format!("[{}]", v.iter().map(js).collect::<Vec<_>>().join(", "))
}

fn map(m: &Map<String, Value>) -> String {
    let rows: Vec<String> = m
        .iter()
        .map(|(k, v)| format!("\n    {}: {}", js(k), js(v)))
        .collect();
    format!("{{{}\n  }}", rows.join(","))
}

impl Manifest {
    pub fn read(path: &Path) -> anyhow::Result<Option<Manifest>> {
        match fs::read_to_string(path) {
            Ok(t) => Ok(Some(serde_json::from_str(&t)?)),
            Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(None),
            Err(e) => Err(e.into()),
        }
    }

    pub fn to_json(&self) -> String {
        let s = |k: &str, v: &str| format!("  \"{k}\": {},\n", js(v));
        let b = |k: &str, v: bool| format!("  \"{k}\": {v},\n");
        let a = |k: &str, v: &[String]| format!("  \"{k}\": {},\n", list(v));
        let mut o = format!("{{\n  \"manifest_version\": {},\n", self.manifest_version);
        o += &s("version", &self.version);
        o += &s("installed_at", &self.installed_at);
        o += &s("package_manager", &self.package_manager);
        o += &s("install_root", &self.install_root);
        o += &format!("  \"wave_cap\": {},\n", self.wave_cap);
        for (k, v) in [
            ("model_planning", &self.model_planning),
            ("model_execution", &self.model_execution),
            ("model_review", &self.model_review),
            ("model_debug", &self.model_debug),
            ("model_factfind", &self.model_factfind),
            ("model_low", &self.model_low),
            ("effort_planning", &self.effort_planning),
            ("effort_execution", &self.effort_execution),
            ("effort_review", &self.effort_review),
            ("effort_debug", &self.effort_debug),
            ("effort_factfind", &self.effort_factfind),
            ("effort_low", &self.effort_low),
        ] {
            o += &s(k, v);
        }
        o += &b("claude_md_guidance", self.claude_md_guidance);
        o += &b("codex_guidance", self.codex_guidance);
        o += &b("opencode_guidance", self.opencode_guidance);
        o += &s("opencode_allow", &self.opencode_allow);
        o += &b("cbm_agent_config", self.cbm_agent_config);
        o += &b("cli_on_path", self.cli_on_path);
        o += &a("hosts", &self.hosts);
        o += &a("agents_clis", &self.agents_clis);
        o += &a("skills", &self.skills);
        o += &a("lib", &self.lib);
        o += &a("hostlib", &self.hostlib);
        o += &a("agents_skills", &self.agents_skills);
        o += &format!("  \"companion_tools\": {},\n", map(&self.companion_tools));
        o += &format!("  \"files\": {},\n", map(&self.files));
        o += &format!("  \"backups\": {}\n}}\n", map(&self.backups));
        o
    }

    pub fn write(&self, path: &Path) -> io::Result<()> {
        fs::write(path, self.to_json())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const FIXTURE: &str = include_str!("../tests/fixtures/manifest-v2.json");

    #[test]
    fn v2_round_trips_byte_for_byte() {
        let d = tempfile::tempdir().unwrap();
        let (a, b) = (d.path().join("a.json"), d.path().join("b.json"));
        fs::write(&a, FIXTURE).unwrap();
        let m = Manifest::read(&a).unwrap().unwrap();
        assert_eq!(m.hosts, ["claude", "agents"]);
        assert_eq!(m.agents_clis, Vec::<String>::new());
        assert_eq!(m.files.len(), 1);
        m.write(&b).unwrap();
        assert_eq!(fs::read_to_string(&b).unwrap(), FIXTURE);
    }

    #[test]
    fn empty_maps_keep_the_heredoc_shape() {
        let m = Manifest {
            manifest_version: 2,
            ..Manifest::default()
        };
        let j = m.to_json();
        assert!(
            j.contains("  \"files\": {\n  },\n  \"backups\": {\n  }\n}\n"),
            "{j}"
        );
        assert!(j.contains("  \"hosts\": [],\n"));
    }

    #[test]
    fn v1_manifest_loads_with_defaults() {
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("m.json");
        fs::write(
            &p,
            "{\n  \"manifest_version\": 1,\n  \"version\": \"2.0.0\",\n  \"skills\": [\"a\"]\n}\n",
        )
        .unwrap();
        let m = Manifest::read(&p).unwrap().unwrap();
        assert_eq!(m.manifest_version, 1);
        assert_eq!(m.version, "2.0.0");
        assert_eq!(m.skills, ["a"]);
        assert_eq!(m.wave_cap, 2);
        assert!(m.hosts.is_empty() && m.files.is_empty() && m.backups.is_empty());
        assert!(!m.claude_md_guidance);
    }

    #[test]
    fn absent_file_is_none_and_bad_json_is_an_error() {
        let d = tempfile::tempdir().unwrap();
        assert_eq!(Manifest::read(&d.path().join("none")).unwrap(), None);
        let p = d.path().join("bad");
        fs::write(&p, "{").unwrap();
        assert!(Manifest::read(&p).is_err());
    }

    #[test]
    fn fixture_keys_follow_install_order() {
        let keys: Vec<&str> = FIXTURE
            .lines()
            .filter_map(|l| l.strip_prefix("  \"")?.split('"').next())
            .collect();
        assert_eq!(keys.len(), 33);
        assert_eq!(&keys[..3], ["manifest_version", "version", "installed_at"]);
        assert_eq!(&keys[30..], ["companion_tools", "files", "backups"]);
    }
}

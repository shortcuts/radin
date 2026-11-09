use super::{Session, Stop};
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

const PSTACK_RAW: &str =
    "https://raw.githubusercontent.com/cursor/plugins/refs/heads/main/pstack/skills";
const CBM_INSTALL: &str = "curl -fsSL https://raw.githubusercontent.com/DeusData/codebase-memory-mcp/main/install.sh | bash -s -- --skip-config";
const CAVEMAN_CODEX: &str = "curl -fsSL https://raw.githubusercontent.com/JuliusBrussee/caveman/main/install.sh | bash -s -- --only codex --non-interactive";
const PONYTAIL_CODEX: &str =
    "codex plugin marketplace add DietrichGebert/ponytail && codex plugin add ponytail@ponytail";
const RTK_CODEX: &str = "rtk init -g --codex";
const CBM_CODEX: &str = "\"$CBM_BIN\" install -y --clients=codex";
const CAVEMAN_OPENCODE: &str = "curl -fsSL https://raw.githubusercontent.com/JuliusBrussee/caveman/main/install.sh | bash -s -- --only opencode --non-interactive";
const PONYTAIL_OPENCODE: &str = "opencode plugin add @dietrichgebert/ponytail";
const RTK_OPENCODE: &str = "rtk init -g --opencode";
const CBM_OPENCODE: &str = "\"$CBM_BIN\" install -y --clients=opencode";
const THERMO_INSTALL: &str = "npx -y skills@latest add \"https://github.com/cursor/plugins/tree/main/cursor-team-kit/skills/thermo-nuclear-code-quality-review\" -g -a claude-code -y";
const THERMO_RAW: &str = "https://raw.githubusercontent.com/cursor/plugins/refs/heads/main/cursor-team-kit/skills/thermo-nuclear-code-quality-review/SKILL.md";

const PLUGINS: [(&str, &str, &str); 3] = [
    ("caveman", "caveman@caveman", "JuliusBrussee/caveman"),
    ("ponytail", "ponytail@ponytail", "DietrichGebert/ponytail"),
    (
        "mattpocock-skills",
        "mattpocock-skills@claude-plugins-official",
        "anthropics/claude-plugins-official",
    ),
];

pub fn which_in(path: &str, name: &str) -> Option<PathBuf> {
    path.split(':')
        .map(|d| Path::new(if d.is_empty() { "." } else { d }).join(name))
        .find(|p| fs::metadata(p).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0))
}

enum Line {
    Ok(String),
    Warn(String),
    Tail(String),
}

/// What one companion job reports. Jobs run on threads, so they print only after joining.
type Report = Vec<Line>;

struct ToolCfg {
    refresh: bool,
    verbose: bool,
    path: String,
    local_bin: PathBuf,
}

/// Runs a shell command with stdin closed. Returns whether it succeeded and its combined output.
/// bash with pipefail: a failed `curl` in `curl ... | bash` must fail the install step.
fn sh(cmd: &str, verbose: bool, cbm_bin: Option<&Path>) -> (bool, String) {
    let mut c = Command::new("bash");
    c.args(["-o", "pipefail"]).stdin(Stdio::null());
    if let Some(b) = cbm_bin {
        c.env("CBM_BIN", b);
    }
    if verbose {
        let ok = c.arg("-c").arg(cmd).status().is_ok_and(|s| s.success());
        return (ok, String::new());
    }
    c.arg("-c").arg(format!("exec 2>&1; {cmd}"));
    match c.output() {
        Ok(o) => (
            o.status.success(),
            String::from_utf8_lossy(&o.stdout).into_owned(),
        ),
        Err(e) => (false, e.to_string()),
    }
}

fn tail20(log: &str) -> String {
    let lines: Vec<&str> = log.lines().collect();
    lines[lines.len().saturating_sub(20)..].join("\n")
}

fn install_tool_job(cfg: &ToolCfg, name: &str, cmd: &str, cbm_bin: Option<&Path>) -> Report {
    let present = which_in(&cfg.path, name).is_some() || {
        let p = cfg.local_bin.join(name);
        fs::metadata(&p).is_ok_and(|m| m.permissions().mode() & 0o111 != 0)
    };
    if !cfg.refresh && present {
        return vec![Line::Ok(format!("{name} already installed."))];
    }
    let (ok, log) = sh(cmd, cfg.verbose, cbm_bin);
    if ok {
        return vec![Line::Ok(format!("{name} installed."))];
    }
    let mut r = vec![];
    if !log.is_empty() {
        r.push(Line::Tail(tail20(&log)));
    }
    r.push(Line::Warn(format!(
        "{name} install failed -- radin itself is unaffected."
    )));
    r
}

fn strip_invocation(text: &str) -> String {
    text.split_inclusive('\n')
        .filter(|l| !l.starts_with("disable-model-invocation:"))
        .collect()
}

fn curl_to(url: &str, out: &Path) -> bool {
    Command::new("curl")
        .args(["-fsSL", url, "-o"])
        .arg(out)
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_ok_and(|s| s.success())
}

fn starts_with_frontmatter(p: &Path) -> bool {
    fs::read(p).is_ok_and(|b| b.starts_with(b"---"))
}

impl Session<'_> {
    fn cfg(&self) -> ToolCfg {
        ToolCfg {
            refresh: self.o.refresh,
            verbose: self.o.verbose,
            path: (self.c.env)("PATH").unwrap_or_default(),
            local_bin: self.home.join(".local/bin"),
        }
    }

    fn emit(&self, r: Report) {
        for l in r {
            match l {
                Line::Ok(m) => self.ui.ok(&m),
                Line::Warn(m) => self.ui.warn(&m),
                Line::Tail(t) => eprintln!("{t}"),
            }
        }
    }

    fn install_tool(&self, name: &str, cmd: &str) {
        let cbm = self.cbm_bin();
        self.emit(install_tool_job(&self.cfg(), name, cmd, cbm.as_deref()));
    }

    pub(super) fn cbm_bin(&self) -> Option<PathBuf> {
        crate::cbm::which(self.c).map(PathBuf::from)
    }

    fn rtk_cmd(&self, mgr: &str) -> String {
        match (mgr, &self.brew, &self.mise) {
            ("brew", Some(b), _) => format!("{0} install rtk || {0} upgrade rtk", b.display()),
            ("mise", _, Some(m)) => format!("{} use -g aqua:rtk-ai/rtk@latest", m.display()),
            _ => "curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh | sh".into(),
        }
    }

    pub(super) fn dry_run_commands(&self) {
        let mgr = match self
            .prev
            .as_ref()
            .map(|m| m.package_manager.clone())
            .filter(|m| !m.is_empty())
        {
            Some(m) => m,
            None if self.brew.is_some() => "brew".into(),
            None if self.mise.is_some() => "mise".into(),
            None => "curl".into(),
        };
        println!("run {}\nrun {CBM_INSTALL}", self.rtk_cmd(&mgr));
        if self.is_selected("claude") {
            println!("run {THERMO_INSTALL}");
            for n in ["unslop", "technical-writing"] {
                println!("run curl -fsSL {PSTACK_RAW}/{n}/SKILL.md");
            }
            for p in PLUGINS {
                println!("run claude plugin install {}", p.1);
            }
        }
        if self.is_selected("codex") {
            println!("write {}", self.codex_home.join("AGENTS.md").display());
            for c in [CAVEMAN_CODEX, PONYTAIL_CODEX, RTK_CODEX, CBM_CODEX] {
                println!("run {c}");
            }
        }
        if self.is_selected("opencode") {
            println!("write {}", self.opencode_dir.join("AGENTS.md").display());
            println!("write {}", self.opencode_config.display());
            for p in self.opencode_paths() {
                println!("write {}", p.display());
            }
            for c in [
                CAVEMAN_OPENCODE,
                PONYTAIL_OPENCODE,
                RTK_OPENCODE,
                CBM_OPENCODE,
            ] {
                println!("run {c}");
            }
        }
        if self.agents_selected() {
            for (n, base, files) in self.agents_rows() {
                if self.agents_skill_wanted(&n) {
                    for f in files {
                        println!("run curl -fsSL {base}/{f}");
                    }
                }
            }
        }
    }

    pub(super) fn agents_selected(&self) -> bool {
        self.selected
            .iter()
            .any(|id| super::assets::host(id).unwrap().2 == "agents")
    }

    fn agents_rows(&self) -> Vec<(String, String, Vec<String>)> {
        let text = self.assets.lib("companion-skills.txt").unwrap_or_default();
        String::from_utf8_lossy(&text)
            .lines()
            .filter(|l| !l.starts_with('#') && !l.trim().is_empty())
            .filter_map(|l| {
                let f: Vec<&str> = l.split_whitespace().collect();
                (f.len() >= 4).then(|| {
                    (
                        f[0].to_string(),
                        f[2].to_string(),
                        f[3].split(',').map(String::from).collect(),
                    )
                })
            })
            .collect()
    }

    fn agents_skill_present(&self, name: &str) -> bool {
        self.home
            .join(format!(".agents/skills/{name}/SKILL.md"))
            .is_file()
            || (self.is_selected("opencode")
                && self
                    .opencode_dir
                    .join(format!("skills/{name}/SKILL.md"))
                    .is_file())
    }

    fn agents_skill_wanted(&self, name: &str) -> bool {
        if self
            .prev
            .as_ref()
            .is_some_and(|m| m.agents_skills.iter().any(|n| n == name))
        {
            return true;
        }
        !self.agents_skill_present(name)
            && !self.home.join(format!(".agents/skills/{name}")).is_dir()
    }

    pub(super) fn plugin_state(&mut self, id: &str) -> Option<&'static str> {
        if self.plugin_list.is_none() {
            let out = Command::new("claude")
                .args(["plugin", "list"])
                .stdin(Stdio::null())
                .stderr(Stdio::null())
                .output()
                .ok();
            self.plugin_list = Some(
                out.map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
                    .unwrap_or_default(),
            );
        }
        let (mut cur, mut scope, mut state) = (false, "", None);
        for l in self.plugin_list.as_deref().unwrap_or("").lines() {
            let f: Vec<&str> = l.split_whitespace().collect();
            if l.contains("❯ ") {
                cur = f.get(1) == Some(&id);
                scope = "";
            } else if cur && l.contains("Scope:") {
                scope = f.get(1).copied().unwrap_or("");
            } else if cur && scope == "user" && l.contains("Status:") {
                state = Some(if l.contains("disabled") {
                    "disabled"
                } else {
                    "enabled"
                });
            }
        }
        state
    }

    fn run_plugin_cmds(&self, cmds: &[String]) -> bool {
        let (ok, log) = sh(&cmds.join("; "), self.o.verbose, None);
        if !ok && !log.is_empty() {
            eprintln!("{}", tail20(&log));
        }
        ok
    }

    fn install_plugin(&mut self, name: &str, id: &str, source: &str) {
        if self.which("claude").is_none() {
            self.ui.warn(&format!(
                "{name} skipped: the 'claude' CLI is not on PATH. Install Claude Code, then re-run install.sh."
            ));
            return;
        }
        let state = self.plugin_state(id);
        if !self.o.refresh && state.is_some() {
            self.ui.ok(&format!("{name} already installed."));
        } else {
            let (cmds, done, fail) = if state.is_some() {
                (
                    vec![
                        "claude plugin marketplace update".to_string(),
                        format!("claude plugin update {id}"),
                    ],
                    "updated",
                    "update",
                )
            } else {
                (
                    vec![
                        format!("claude plugin marketplace add {source}"),
                        format!("claude plugin install {id}"),
                    ],
                    "installed",
                    "install",
                )
            };
            if self.run_plugin_cmds(&cmds) {
                self.ui.ok(&format!("{name} {done}."));
            } else {
                self.ui.warn(&format!(
                    "{name} {fail} failed -- radin itself is unaffected."
                ));
            }
            self.plugin_list = None;
        }
        if self.plugin_state(id) != Some("disabled") {
            return;
        }
        let _ = Command::new("claude")
            .args(["plugin", "enable", "--scope", "user", id])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();
        self.plugin_list = None;
        if self.plugin_state(id) != Some("enabled") {
            self.ui.warn(&format!(
                "{name} is installed but disabled, so its hooks do not run. Run: claude plugin enable --scope user {id}"
            ));
        }
    }

    fn thermo(&self) -> Result<(), Stop> {
        let skills = self.claude.join("skills");
        let skill = skills.join("thermo-nuclear/SKILL.md");
        if !self.o.refresh && skill.is_file() {
            self.ui.ok("thermo-nuclear already installed.");
        } else {
            if self.which("npx").is_some() {
                let (ok, log) = sh(THERMO_INSTALL, false, None);
                if !ok {
                    eprint!("{log}");
                    return Err(Stop::Fail(1));
                }
                let src = skills.join("thermo-nuclear-code-quality-review");
                if src.is_dir() {
                    let _ = fs::remove_dir_all(skills.join("thermo-nuclear"));
                    fs::rename(src, skills.join("thermo-nuclear"))?;
                }
            } else {
                self.ui.warn("npx not found -- falling back to a direct SKILL.md download for thermo-nuclear.");
                fs::create_dir_all(skill.parent().unwrap())?;
                if !curl_to(THERMO_RAW, &skill) {
                    return Err(Stop::Fail(1));
                }
            }
            self.ui.ok("thermo-nuclear installed.");
        }
        if let Ok(t) = fs::read_to_string(&skill) {
            fs::write(&skill, strip_invocation(&t))?;
        }
        Ok(())
    }

    fn install_pstack_skill(&mut self, name: &str, tmp: &Path) {
        let dir = self.claude.join("skills").join(name);
        let mine = self.owned_flag(name);
        let file = tmp.join(name);
        if dir.is_dir() && !mine {
            self.ui.warn(&format!(
                "{name} skipped: {} exists and radin did not install it.",
                dir.display()
            ));
            let _ = fs::remove_file(&file);
            return;
        }
        if starts_with_frontmatter(&file) {
            let body = strip_invocation(&fs::read_to_string(&file).unwrap_or_default());
            if fs::create_dir_all(&dir)
                .and_then(|_| fs::write(dir.join("SKILL.md"), body))
                .is_ok()
            {
                self.ui.ok(&format!("{name} installed."));
                self.pstack_owned.push(name.into());
            }
        } else {
            self.ui.warn(&format!(
                "{name} download failed -- radin itself is unaffected."
            ));
            if mine && dir.join("SKILL.md").is_file() {
                self.pstack_owned.push(name.into());
            }
        }
        let _ = fs::remove_file(&file);
    }

    fn owned_flag(&self, tool: &str) -> bool {
        self.prev
            .as_ref()
            .and_then(|m| m.companion_tools.get(tool))
            .and_then(|v| v.as_bool())
            .unwrap_or(false)
    }

    /// The pstack fetches and the rtk and codebase-memory-mcp installs touch disjoint paths and wait on the network, so they run at once.
    fn rtk_cbm_and_pstack(&mut self) -> Result<(), Stop> {
        let claude = self.is_selected("claude");
        let tmp = std::env::temp_dir().join(format!("radin-pstack-{}", std::process::id()));
        fs::create_dir_all(&tmp)?;
        let cfg = self.cfg();
        let rtk = self.rtk_cmd(&self.pkg);
        let verbose = self.o.verbose;
        let (mut rtk_r, mut cbm_r) = (vec![], vec![]);
        std::thread::scope(|sc| {
            if claude {
                for n in ["unslop", "technical-writing"] {
                    let out = tmp.join(n);
                    sc.spawn(move || curl_to(&format!("{PSTACK_RAW}/{n}/SKILL.md"), &out));
                }
            }
            if !verbose {
                let a = sc.spawn(|| install_tool_job(&cfg, "rtk", &rtk, None));
                let b =
                    sc.spawn(|| install_tool_job(&cfg, "codebase-memory-mcp", CBM_INSTALL, None));
                rtk_r = a.join().unwrap_or_default();
                cbm_r = b.join().unwrap_or_default();
            }
        });
        if claude {
            for n in ["unslop", "technical-writing"] {
                self.install_pstack_skill(n, &tmp);
            }
        } else {
            for n in ["unslop", "technical-writing"] {
                if self.owned_flag(n) {
                    self.pstack_owned.push(n.into());
                }
            }
        }
        if verbose {
            self.install_tool("rtk", &rtk);
            self.install_tool("codebase-memory-mcp", CBM_INSTALL);
        } else {
            self.emit(rtk_r);
            self.emit(cbm_r);
        }
        let _ = fs::remove_dir(&tmp);
        Ok(())
    }

    fn agent_hosts(&self, host: &str, steps: [(&str, &str); 4]) {
        let cli = super::assets::host(host).unwrap().3;
        if self.which(cli).is_none() {
            return;
        }
        let tag = |t: &str| format!("{t}-{host}");
        self.install_tool(&tag("caveman"), steps[0].1);
        self.install_tool(&tag("ponytail"), steps[1].1);
        if self.which("rtk").is_some() {
            self.install_tool(&tag("rtk"), steps[2].1);
        } else {
            self.ui.warn(&format!(
                "rtk not found: skipping rtk init for {}.",
                if host == "codex" { "Codex" } else { host }
            ));
        }
        if self.cbm_bin().is_some() {
            self.install_tool(&tag("codebase-memory-mcp"), steps[3].1);
        } else {
            self.ui.warn(&format!(
                "codebase-memory-mcp not found: skipping its {} config.",
                if host == "codex" { "Codex" } else { host }
            ));
        }
    }

    fn backup_copy(&self, src: &Path, name: &str, what: &str) -> Result<(), Stop> {
        if !src.is_file() {
            return Ok(());
        }
        let dst = self.rh.join(format!("backups/{name}.{}.bak", self.stamp));
        fs::create_dir_all(dst.parent().unwrap())?;
        if dst.exists() {
            return Ok(());
        }
        fs::copy(src, &dst)?;
        self.ui.info(&format!(
            "{what} copied to {}: restore it by hand if a companion replaces your {}.",
            dst.display(),
            if name == "hooks.json" {
                "hooks"
            } else {
                "settings"
            }
        ));
        Ok(())
    }

    fn resolve_agents_skill(
        &mut self,
        name: &str,
        base: &str,
        files: &[String],
    ) -> Result<(), Stop> {
        let dir = self.home.join(".agents/skills").join(name);
        let mine = self
            .prev
            .as_ref()
            .is_some_and(|m| m.agents_skills.iter().any(|n| n == name));
        if !self.agents_skill_wanted(name) {
            if dir.is_dir() && !self.agents_skill_present(name) {
                self.ui.warn(&format!(
                    "{name} skipped: {} exists and radin did not install it.",
                    dir.display()
                ));
            }
            if mine {
                self.agents_owned.push(name.into());
            }
            return Ok(());
        }
        let tmp = std::env::temp_dir().join(format!("radin-agents-{}-{name}", std::process::id()));
        let _ = fs::remove_dir_all(&tmp);
        let mut good = true;
        for f in files {
            let out = tmp.join(f);
            fs::create_dir_all(out.parent().unwrap())?;
            good &= curl_to(&format!("{base}/{f}"), &out)
                && fs::metadata(&out).is_ok_and(|m| m.len() > 0);
        }
        good &= starts_with_frontmatter(&tmp.join("SKILL.md"));
        if good {
            let text =
                strip_invocation(&fs::read_to_string(tmp.join("SKILL.md")).unwrap_or_default());
            let mut done = false;
            let body: String = text
                .split_inclusive('\n')
                .map(|l| {
                    if !done && l.starts_with("name:") {
                        done = true;
                        format!("name: {name}\n")
                    } else {
                        l.to_string()
                    }
                })
                .collect();
            fs::write(tmp.join("SKILL.md"), body)?;
            for f in files {
                let dst = dir.join(f);
                fs::create_dir_all(dst.parent().unwrap())?;
                fs::copy(tmp.join(f), dst)?;
            }
            self.ui.ok(&format!(
                "{name} installed to {}.",
                self.ui.bold(&dir.display().to_string())
            ));
            self.agents_owned.push(name.into());
        } else {
            self.ui.warn(&format!(
                "{name} download failed -- radin itself is unaffected."
            ));
            if mine && dir.join("SKILL.md").is_file() {
                self.agents_owned.push(name.into());
            }
        }
        let _ = fs::remove_dir_all(&tmp);
        Ok(())
    }

    pub(super) fn companions_step(&mut self) -> Result<(), Stop> {
        if self.is_selected("claude") {
            self.thermo()?;
        }
        self.rtk_cbm_and_pstack()?;
        if self.is_selected("claude") {
            for (name, id, src) in PLUGINS {
                self.install_plugin(name, id, src);
                if name == "ponytail" {
                    let band = self.claude.join(".ponytail-band");
                    if !band.exists() {
                        fs::create_dir_all(&self.claude)?;
                        fs::write(band, "off")?;
                    }
                }
            }
        }
        if self.is_selected("codex") && self.which("codex").is_some() {
            self.backup_copy(
                &self.codex_home.join("hooks.json"),
                "hooks.json",
                "hooks.json",
            )?;
            self.agent_hosts(
                "codex",
                [
                    ("caveman", CAVEMAN_CODEX),
                    ("ponytail", PONYTAIL_CODEX),
                    ("rtk", RTK_CODEX),
                    ("cbm", CBM_CODEX),
                ],
            );
        }
        if self.is_selected("opencode") {
            self.backup_copy(
                &self.opencode_config.clone(),
                "opencode.json",
                "opencode config",
            )?;
            self.agent_hosts(
                "opencode",
                [
                    ("caveman", CAVEMAN_OPENCODE),
                    ("ponytail", PONYTAIL_OPENCODE),
                    ("rtk", RTK_OPENCODE),
                    ("cbm", CBM_OPENCODE),
                ],
            );
            self.opencode_allow_rule()?;
        }
        if self.agents_selected() {
            for (n, base, files) in self.agents_rows() {
                self.resolve_agents_skill(&n, &base, &files)?;
            }
        } else if let Some(m) = &self.prev {
            self.agents_owned = m.agents_skills.clone();
        }
        if self.is_selected("codex") && self.which("codex").is_some() {
            self.ui.info("Codex: open /hooks and trust the new hooks once (caveman, ponytail, rtk, codebase-memory-mcp). radin cannot do this for you.");
        }
        self.wire_cbm();
        Ok(())
    }
}

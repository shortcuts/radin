mod assets;
mod cbm;
mod companions;
mod guidance;
mod home;
mod manifest_out;
mod opencode;
mod pick;
mod plan;
mod publish;
mod ui;
mod update;
mod wizard;

pub use update::run as run_update;

use crate::manifest::Manifest;
use crate::{Ctx, Out};
use assets::{host, host_ids, Assets, HOSTS_TABLE};
use pick::Input;
use std::collections::HashMap;
use std::io::IsTerminal;
use std::path::PathBuf;
use ui::Ui;

const STEP_TOTAL: usize = 6;

const USAGE: &str = "usage: radin install [--yes] [--verbose] [--details] [--update] [--refresh] [--list] [--dry-run] [--force] [--wave-cap N] [--only ID[,ID...]]\nhosts: claude codex opencode\n";

/// Why a run stopped. `Done` and `Abort` are quiet; `Fail` and `Err` leave a partial install behind.
pub(crate) enum Stop {
    Done(i32),
    Abort,
    Fail(i32),
    Err(String),
}

impl From<std::io::Error> for Stop {
    fn from(e: std::io::Error) -> Stop {
        Stop::Err(e.to_string())
    }
}

impl From<pick::Abort> for Stop {
    fn from(_: pick::Abort) -> Stop {
        Stop::Abort
    }
}

#[derive(Default)]
struct Opts {
    yes: bool,
    verbose: bool,
    details: bool,
    update: bool,
    refresh: bool,
    list: bool,
    dry: bool,
    force: bool,
    only: Option<Vec<&'static str>>,
    wave_cap: Option<u32>,
}

fn parse(args: &[String], update: bool, details: bool) -> Result<Opts, ()> {
    let mut o = Opts {
        update,
        details,
        ..Opts::default()
    };
    let mut i = 0;
    let mut only: Option<String> = None;
    let mut cap: Option<String> = None;
    while i < args.len() {
        let a = args[i].as_str();
        match a {
            "--yes" => o.yes = true,
            "--verbose" => o.verbose = true,
            "--update" => o.update = true,
            "--refresh" => o.refresh = true,
            "--details" => o.details = true,
            "--list" => o.list = true,
            "--dry-run" => o.dry = true,
            "--force" => o.force = true,
            "--only" | "--wave-cap" => {
                i += 1;
                let v = args.get(i).ok_or(())?.clone();
                if a == "--only" {
                    only = Some(v);
                } else {
                    cap = Some(v);
                }
            }
            _ => match (a.strip_prefix("--only="), a.strip_prefix("--wave-cap=")) {
                (Some(v), _) => only = Some(v.into()),
                (_, Some(v)) => cap = Some(v.into()),
                _ => return Err(()),
            },
        }
        i += 1;
    }
    if let Some(w) = only {
        let want: Vec<&str> = w.split(',').filter(|s| !s.is_empty()).collect();
        if want.iter().any(|id| host(id).is_none()) {
            return Err(());
        }
        let ids: Vec<&'static str> = host_ids()
            .into_iter()
            .filter(|id| want.contains(id))
            .collect();
        if ids.is_empty() {
            return Err(());
        }
        o.only = Some(ids);
    }
    if let Some(c) = cap {
        if c.is_empty() || c.starts_with('0') || !c.bytes().all(|b| b.is_ascii_digit()) {
            return Err(());
        }
        o.wave_cap = Some(c.parse().map_err(|_| ())?);
    }
    Ok(o)
}

pub(crate) struct Session<'a> {
    c: &'a Ctx<'a>,
    o: Opts,
    ui: Ui,
    input: Input,
    assets: Assets,
    home: PathBuf,
    rh: PathBuf,
    claude: PathBuf,
    codex_home: PathBuf,
    opencode_dir: PathBuf,
    opencode_config: PathBuf,
    brew: Option<PathBuf>,
    mise: Option<PathBuf>,
    prev: Option<Manifest>,
    legacy: bool,
    owned: HashMap<String, String>,
    selected: Vec<&'static str>,
    held: Vec<&'static str>,
    major: String,
    minor: String,
    models_picked: bool,
    pkg: String,
    wave_cap: u32,
    migrated: bool,
    legacy_left: bool,
    plan: Vec<plan::Row>,
    kept: Vec<(String, String)>,
    backups: Vec<(String, String)>,
    cli_value: String,
    cli_on_path: bool,
    plugin_list: Option<String>,
    pstack_owned: Vec<String>,
    agents_owned: Vec<String>,
    claude_md: bool,
    codex_guidance: bool,
    opencode_guidance: bool,
    opencode_allow: String,
    cbm_cfg: bool,
    stamp: String,
}

impl<'a> Session<'a> {
    fn new(c: &'a Ctx<'a>, o: Opts) -> Session<'a> {
        let env = |k: &str| (c.env)(k).filter(|v| !v.is_empty());
        let home = c.home.clone();
        let xdg = env("XDG_CONFIG_HOME").map_or_else(|| home.join(".config"), PathBuf::from);
        let opencode_dir = xdg.join("opencode");
        let opencode_config = match env("OPENCODE_CONFIG").map(PathBuf::from) {
            Some(f) if f.is_file() => f,
            _ => opencode_dir.join("opencode.json"),
        };
        let stamp: String = crate::telemetry::now_utc()
            .chars()
            .filter(|c| !"-:".contains(*c))
            .collect();
        let ui = Ui::new(o.details, o.verbose, STEP_TOTAL);
        let mut s = Session {
            c,
            ui,
            input: Input::new(
                c.stdin.is_empty() && std::io::stdin().is_terminal() && !o.yes,
                &c.stdin,
            ),
            assets: Assets::new(c.env),
            rh: crate::paths::radin_home(&home),
            claude: home.join(".claude"),
            codex_home: env("CODEX_HOME").map_or_else(|| home.join(".codex"), PathBuf::from),
            opencode_dir,
            opencode_config,
            brew: None,
            mise: None,
            prev: None,
            legacy: false,
            owned: HashMap::new(),
            selected: vec![],
            held: vec![],
            major: "sonnet".into(),
            minor: "haiku".into(),
            models_picked: false,
            pkg: "curl".into(),
            wave_cap: 2,
            migrated: false,
            legacy_left: false,
            plan: vec![],
            kept: vec![],
            backups: vec![],
            cli_value: "\"$HOME/.radin/bin/radin\"".into(),
            cli_on_path: false,
            plugin_list: None,
            pstack_owned: vec![],
            agents_owned: vec![],
            claude_md: false,
            codex_guidance: false,
            opencode_guidance: false,
            opencode_allow: String::new(),
            cbm_cfg: false,
            stamp,
            home,
            o,
        };
        s.brew = s.which("brew");
        s.mise = s.which("mise");
        s.reload_prev();
        s
    }

    pub(crate) fn which(&self, name: &str) -> Option<PathBuf> {
        companions::which_in(&(self.c.env)("PATH").unwrap_or_default(), name)
    }

    fn is_selected(&self, id: &str) -> bool {
        self.selected.contains(&id)
    }

    fn abort(&self, msg: String) -> Stop {
        self.ui.err(&msg);
        Stop::Done(1)
    }

    /// Reads the previous manifest, from the old home when the new one does not exist yet.
    fn reload_prev(&mut self) {
        let mut path = self.rh.join("manifest.json");
        if !path.exists() {
            path = self.claude.join(".radin/manifest.json");
        }
        let text = std::fs::read_to_string(&path).unwrap_or_default();
        self.legacy = !text.is_empty() && !text.contains("\n  \"files\": {");
        self.prev = serde_json::from_str(&text).ok();
        self.owned = self
            .prev
            .as_ref()
            .map(|m| {
                m.files
                    .iter()
                    .filter_map(|(k, v)| Some((k.clone(), v.as_str()?.to_string())))
                    .collect()
            })
            .unwrap_or_default();
    }

    fn select_hosts(&mut self) {
        if let Some(only) = &self.o.only {
            self.selected = only.clone();
            return;
        }
        let want: Vec<&'static str> = match (&self.prev, self.o.update) {
            (Some(m), true) => host_ids()
                .into_iter()
                .filter(|id| m.hosts.iter().any(|h| h == id))
                .collect(),
            _ => vec![],
        };
        self.selected = if want.is_empty() {
            vec!["claude"]
        } else {
            want
        };
    }

    fn go(&mut self) -> Result<(), Stop> {
        if self.o.update {
            if let Some(m) = self.prev.as_ref() {
                if self.o.wave_cap.is_none() {
                    self.wave_cap = m.wave_cap;
                }
                let pick = |v: &str, d: &str| {
                    if v.is_empty() {
                        d.to_string()
                    } else {
                        v.to_string()
                    }
                };
                self.major = pick(&m.model_planning, "sonnet");
                self.minor = pick(&m.model_factfind, "haiku");
                self.pkg = pick(&m.package_manager, "curl");
            }
        }
        if let Some(w) = self.o.wave_cap {
            self.wave_cap = w;
        }
        self.ui.banner();
        self.select_hosts();
        self.wizard()?;
        self.ui.info(&format!("hosts: {}", self.selected.join(" ")));

        self.ui.step("Installing radin");
        self.migrate_home()?;
        self.reload_prev();
        self.preflight();
        self.drop_blocked()?;
        if self.o.dry {
            self.ui.info("dry run: nothing below is written or run");
            self.dry_run_report();
            return Err(Stop::Done(0));
        }
        let era = self.bash_era();
        std::fs::create_dir_all(self.rh.join("lib"))?;
        for f in crate::shipped::shipped().lib {
            let b = self
                .assets
                .lib(f)
                .ok_or_else(|| Stop::Err(format!("{f}: missing")))?;
            std::fs::write(self.rh.join("lib").join(f), b)?;
        }
        self.remove_orphans();
        self.install_binary()?;
        if era {
            self.rewrite_hooks();
        }

        self.ui.step("Sub-agent models");
        self.models_step();

        self.ui.step("radin CLI on PATH");
        self.link_cli()?;
        for r in self.renders() {
            self.install_render(r)?;
        }
        self.ui.ok("skills installed");

        self.ui.step("Agent guidance");
        self.guidance_step()?;

        self.ui.step("Companion tools");
        self.companions_step()?;

        self.ui.step("Writing install manifest");
        self.write_manifest()?;
        self.ui.finish_step();
        Ok(())
    }

    fn models_step(&self) {
        let (a, b) = (&self.major, &self.minor);
        if self.o.update {
            self.ui.ok(&format!(
                "keeping sub-agent models: {a}, {b} for fact-finding"
            ));
        } else if !self.is_selected("claude") {
        } else if self.models_picked {
            self.ui
                .ok(&format!("sub-agent models: {a}, {b} for fact-finding"));
        } else {
            self.ui
                .ok("keeping default sub-agent models (sonnet; haiku for fact-finding)");
        }
    }

    fn guidance_step(&mut self) -> Result<(), Stop> {
        if self.is_selected("claude") {
            self.claude_md = true;
            self.write_block(&self.claude.join("CLAUDE.md"), &self.claude_body())?;
        }
        if self.is_selected("codex") {
            self.codex_guidance = true;
            self.write_block(&self.codex_home.join("AGENTS.md"), &self.agents_body())?;
        }
        if self.is_selected("opencode") {
            self.opencode_guidance = true;
            self.write_block(&self.opencode_dir.join("AGENTS.md"), &self.agents_body())?;
            self.install_opencode_agents()?;
        }
        Ok(())
    }
}

fn list_rows(s: &Session) -> String {
    HOSTS_TABLE
        .iter()
        .map(|h| {
            format!(
                "{}\t{}\t{}\n",
                h.0,
                h.1,
                if s.host_detected(h.0) { "yes" } else { "no" }
            )
        })
        .collect()
}

/// `radin install` and, with `update`, the install half of `radin update`.
pub fn run(c: &Ctx, args: &[String], update: bool) -> Out {
    let details = (c.env)("RADIN_DETAILS").is_some_and(|v| !v.is_empty());
    let o = match parse(args, update, details) {
        Ok(o) => o,
        Err(()) => return (2, String::new(), USAGE.to_string()),
    };
    let list = o.list;
    let mut s = Session::new(c, o);
    if list {
        return (0, list_rows(&s), String::new());
    }
    let r = s.go();
    let ui = &s.ui;
    let early = |code: i32| {
        ui.err(&format!(
            "install stopped early ({code}) -- ~/.claude holds a partial install. Re-run it, or check with: radin doctor"
        ));
        code
    };
    let code = match r {
        Ok(()) => {
            ui.say(&format!(
                "radin {} in {}s. {}",
                if s.o.update { "updated" } else { "installed" },
                ui.elapsed(),
                ui.dim("Go be stingy with those tokens.")
            ));
            if !s.o.update {
                ui.say(&format!(
                    "Open Claude Code in a repo and run {} to file your first",
                    ui.bold("/radin-record")
                ));
                ui.say(&format!(
                    "task, then {} to work the backlog. {} opens the TUI.",
                    ui.bold("/radin-batch"),
                    ui.bold("radin")
                ));
            }
            if s.migrated {
                ui.warn("restart open Claude sessions: they hold the old path");
            }
            ui.say(&format!(
                "{} checks this install · {} updates radin itself.",
                ui.bold("radin doctor"),
                ui.bold("radin update")
            ));
            0
        }
        Err(Stop::Done(code)) => code,
        Err(Stop::Abort) => {
            eprintln!("\n{}", ui.red(&format!("{} aborted.", ui::RAT)));
            130
        }
        Err(Stop::Fail(code)) => early(code),
        Err(Stop::Err(msg)) => {
            ui.err(&msg);
            early(1)
        }
    };
    (code, String::new(), String::new())
}

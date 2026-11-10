use crate::manifest::Manifest;
use crate::shipped::{shipped, Shipped};
use crate::{cbm, jsonedit, Ctx, Out};
use sha2::{Digest, Sha256};
use std::fmt::Write as _;
use std::fs;
use std::io::Read;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::mpsc;
use std::time::{Duration, Instant};

const CODEX_DEADLINE: Duration = Duration::from_secs(20);

pub(crate) fn which(c: &Ctx, name: &str) -> Option<PathBuf> {
    let path = (c.env)("PATH").unwrap_or_default();
    path.split(':')
        .map(|d| Path::new(if d.is_empty() { "." } else { d }).join(name))
        .find(|p| fs::metadata(p).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0))
}

fn env_dir(c: &Ctx, key: &str, default: PathBuf) -> PathBuf {
    (c.env)(key)
        .filter(|v| !v.is_empty())
        .map_or(default, PathBuf::from)
}

fn probe(cmd: &Path, args: &[&str], deadline: Duration) -> Option<String> {
    let (mut reader, writer) = std::io::pipe().ok()?;
    let mut child = Command::new(cmd)
        .args(args)
        .stdin(Stdio::null())
        .stdout(writer.try_clone().ok()?)
        .stderr(writer)
        .spawn()
        .ok()?;
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        let mut buf = Vec::new();
        let _ = reader.read_to_end(&mut buf);
        let _ = tx.send(String::from_utf8_lossy(&buf).into_owned());
    });
    let end = Instant::now() + deadline;
    let status = loop {
        if let Some(s) = child.try_wait().ok()? {
            break s;
        }
        if Instant::now() >= end {
            let _ = child.kill();
            let _ = child.wait();
            return None;
        }
        std::thread::sleep(Duration::from_millis(50));
    };
    // A grandchild can keep the pipe open past the child's exit.
    let out = rx.recv_timeout(Duration::from_secs(1)).ok()?;
    status.success().then_some(out)
}

fn stdout_of(cmd: &Path, args: &[&str]) -> Option<String> {
    let o = Command::new(cmd)
        .args(args)
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .ok()?;
    Some(String::from_utf8_lossy(&o.stdout).into_owned())
}

fn first_version(text: &str) -> Option<[u64; 3]> {
    let b = text.as_bytes();
    let run = |i: usize| b[i..].iter().take_while(|c| c.is_ascii_digit()).count();
    (0..b.len())
        .filter(|&i| b[i].is_ascii_digit())
        .find_map(|i| {
            let mut at = i;
            let mut v = [0u64; 3];
            for (k, slot) in v.iter_mut().enumerate() {
                let n = run(at);
                if n == 0 {
                    return None;
                }
                *slot = text[at..at + n].parse().unwrap_or(0);
                at += n;
                if k < 2 {
                    if b.get(at) != Some(&b'.') {
                        return None;
                    }
                    at += 1;
                }
            }
            Some(v)
        })
}

fn sha256_of(p: &Path) -> Option<String> {
    fs::read(p).ok().map(|b| format!("{:x}", Sha256::digest(b)))
}

fn files_in(dir: &Path, out: &mut Vec<PathBuf>) {
    let Ok(rd) = fs::read_dir(dir) else { return };
    for e in rd.flatten() {
        match e.file_type() {
            Ok(t) if t.is_dir() => files_in(&e.path(), out),
            Ok(t) if t.is_file() => out.push(e.path()),
            _ => {}
        }
    }
}

fn files_under(dirs: &[PathBuf]) -> Vec<PathBuf> {
    let mut v = Vec::new();
    for d in dirs {
        if d.is_dir() {
            files_in(d, &mut v);
        } else if d.is_file() {
            v.push(d.clone());
        }
    }
    v.sort();
    v
}

fn first_hit(line: &str, pats: &[String]) -> Option<String> {
    (0..line.len())
        .filter(|&i| line.is_char_boundary(i))
        .find_map(|i| {
            pats.iter()
                .filter(|p| line[i..].starts_with(p.as_str()))
                .max_by_key(|p| p.len())
                .cloned()
        })
}

struct Doctor<'a, 'b> {
    c: &'a Ctx<'b>,
    s: Shipped,
    home: PathBuf,
    claude: PathBuf,
    rh: PathBuf,
    m: Manifest,
    bad_manifest: bool,
    out: String,
    missing: u32,
}

impl Doctor<'_, '_> {
    fn host_installed(&self, h: &str) -> bool {
        self.m.hosts.iter().any(|x| x == h) || (h == "claude" && self.m.hosts.is_empty())
    }

    fn agents_render(&self) -> bool {
        self.host_installed("codex") || self.host_installed("opencode")
    }

    fn line(&mut self, text: &str) {
        self.out.push_str(text);
        self.out.push('\n');
    }

    fn fail(&mut self, text: &str) {
        self.line(text);
        self.missing += 1;
    }

    fn check_file(&mut self, label: &str, path: &Path) {
        if path.is_file() {
            self.line(&format!("  OK       {label}"));
        } else {
            self.fail(&format!("  MISSING  {label}"));
        }
    }

    fn check_dir(&mut self, path: &Path) {
        let l = path.display();
        if path.is_dir() {
            self.line(&format!("  OK       {l}"));
        } else {
            self.fail(&format!("  MISSING  {l}"));
        }
    }

    fn check_guidance(&mut self, path: &Path) {
        let l = path.display();
        let blocks = fs::read_to_string(path).map_or(0, |t| {
            t.lines().filter(|x| *x == "<!-- radin:begin -->").count()
        });
        if blocks == 1 {
            self.line(&format!("  OK       {l}"));
        } else {
            self.fail(&format!("  MISSING  {l} (re-run install.sh)"));
        }
    }

    fn check_cli(&mut self, name: &str) {
        let tail = if which(self.c, name).is_some() {
            "found"
        } else {
            "not found (companion steps were skipped; install it, then re-run install.sh)"
        };
        self.line(&format!("  {name:<20} {tail}"));
    }

    fn found(&mut self, label: &str, yes: bool) {
        self.line(&format!(
            "  {label:<20} {}",
            if yes { "found" } else { "not found" }
        ));
    }

    fn check_plugin(&mut self, label: &str, id: &str) {
        let mut state = "";
        if let Some(list) = which(self.c, "claude").and_then(|p| stdout_of(&p, &["plugin", "list"]))
        {
            let (mut cur, mut scope) = (false, "");
            for l in list.lines() {
                let f: Vec<&str> = l.split_whitespace().collect();
                if l.contains("❯ ") {
                    cur = f.get(1) == Some(&id);
                    scope = "";
                } else if cur && l.contains("Scope:") {
                    scope = f.get(1).copied().unwrap_or("");
                } else if cur && scope == "user" && l.contains("Status:") {
                    state = if l.contains("disabled") {
                        "disabled"
                    } else {
                        "enabled"
                    };
                }
            }
        }
        match state {
            "enabled" => self.found(label, true),
            "disabled" => self.line(&format!(
                "  {label:<20} disabled (its hooks do not run: claude plugin enable --scope user {id})"
            )),
            _ => self.found(label, false),
        }
    }

    fn digest_group(&self, key: &str) -> &'static str {
        let has = |p: &str| key.starts_with(p);
        if has(".radin/lib/") || has(".radin/bin/") {
            "shared"
        } else if has(".claude/skills/") || has(".radin/hosts/claude/") {
            "claude"
        } else if has(".agents/skills/") || has(".radin/hosts/agents/") {
            "agents"
        } else if key.contains("/opencode/agents/") {
            "opencode"
        } else {
            "other"
        }
    }

    fn check_digests(&mut self) {
        let (mut n, mut bad) = (0, 0);
        let files: Vec<(String, String)> = self
            .m
            .files
            .iter()
            .map(|(k, v)| (k.clone(), v.as_str().unwrap_or("").to_string()))
            .collect();
        for (key, want) in files {
            match self.digest_group(&key) {
                "shared" => {}
                g @ ("claude" | "opencode") if self.host_installed(g) => {}
                "agents" if self.agents_render() => {}
                _ => continue,
            }
            let p = if key.starts_with('/') {
                PathBuf::from(&key)
            } else {
                self.home.join(&key)
            };
            n += 1;
            if !p.is_file() {
                self.line(&format!("  MISSING  {}", p.display()));
                bad += 1;
            } else if sha256_of(&p).as_deref() != Some(want.as_str()) {
                self.line(&format!(
                    "  INVALID  {} (changed since install; install.sh --force restores it)",
                    p.display()
                ));
                bad += 1;
            }
        }
        if n > 0 && bad == 0 {
            self.line(&format!(
                "  OK       {n} file(s) match their recorded digest"
            ));
        }
        self.missing += bad;
    }

    fn check_forbid(&mut self, render: &str, skills: &Path) {
        let list = self.rh.join(format!("lib/forbid-{render}.txt"));
        let pats: Vec<String> = fs::read_to_string(list)
            .unwrap_or_default()
            .lines()
            .filter(|l| !l.is_empty() && !l.starts_with('#'))
            .map(str::to_string)
            .collect();
        let mut n = 0;
        if !pats.is_empty() {
            let mut dirs = vec![self.rh.join(format!("hosts/{render}/lib"))];
            dirs.extend(self.s.skills.iter().map(|s| skills.join(s)));
            for f in files_under(&dirs) {
                if f.extension().is_none_or(|e| e != "md") {
                    continue;
                }
                let text = fs::read_to_string(&f).unwrap_or_default();
                if let Some(hit) = text.lines().find_map(|l| first_hit(l, &pats)) {
                    self.line(&format!(
                        "  INVALID  {} (forbidden string \"{hit}\" in the {render} render)",
                        f.display()
                    ));
                    n += 1;
                }
            }
        }
        if n == 0 {
            self.line(&format!(
                "  OK       no forbidden string in the {render} render"
            ));
        }
        self.missing += n;
    }

    fn check_agent_file(&mut self, f: &Path) {
        let text = fs::read_to_string(f).unwrap_or_default();
        let mut lines = text.lines();
        let mut fm = Vec::new();
        let mut closed = false;
        if lines.next() == Some("---") {
            for l in lines {
                if l == "---" {
                    closed = true;
                    break;
                }
                fm.push(l);
            }
        }
        let why = if !closed {
            "front matter missing or not closed"
        } else if !fm.iter().any(|l| l.starts_with("description:")) {
            "no description line"
        } else if !fm.contains(&"mode: subagent") {
            "mode is not subagent"
        } else if fm.iter().any(|l| l.starts_with("tools:")) {
            "tools line stops opencode from booting"
        } else {
            ""
        };
        if why.is_empty() {
            self.line(&format!("  OK       {}", f.display()));
        } else {
            self.fail(&format!("  INVALID  {} ({why})", f.display()));
        }
    }

    /// Reads each host's config for an `fff` server; running the host CLI would cost seconds per host.
    fn fff_servers(&mut self) {
        let json_has = |p: PathBuf, keys: [&str; 2]| {
            fs::read_to_string(p)
                .ok()
                .and_then(|t| serde_json::from_str::<serde_json::Value>(&t).ok())
                .is_some_and(|v| v[keys[0]].get(keys[1]).is_some())
        };
        let claude_dir = env_dir(self.c, "CLAUDE_CONFIG_DIR", self.home.clone());
        let codex = env_dir(self.c, "CODEX_HOME", self.home.join(".codex"));
        let opencode = env_dir(self.c, "XDG_CONFIG_HOME", self.home.join(".config"))
            .join("opencode/opencode.json");
        for (h, yes) in [
            (
                "claude",
                json_has(claude_dir.join(".claude.json"), ["mcpServers", "fff"]),
            ),
            (
                "codex",
                fs::read_to_string(codex.join("config.toml"))
                    .is_ok_and(|t| t.contains("[mcp_servers.fff]")),
            ),
            ("opencode", json_has(opencode, ["mcp", "fff"])),
        ] {
            if self.host_installed(h) {
                self.found(&format!("fff server ({h})"), yes);
            }
        }
    }

    fn check_codex(&mut self) {
        let dir = env_dir(self.c, "CODEX_HOME", self.home.join(".codex"));
        self.line("\nCodex:");
        self.check_cli("codex");
        self.check_guidance(&dir.join("AGENTS.md"));
        if !fs::read_to_string(dir.join("hooks.json")).is_ok_and(|t| t.contains("\"command\"")) {
            self.line(
                "  NOTE     no Codex hooks found (companion hooks missing; re-run install.sh)",
            );
        } else if !fs::read_to_string(dir.join("config.toml"))
            .is_ok_and(|t| t.contains("trusted_hash"))
        {
            self.line("  NOTE     Codex hooks untrusted: open /hooks in Codex and trust the new hooks once");
        } else {
            self.line("  OK       Codex hook trust recorded (hashes not re-verified)");
        }
        let Some(codex) = which(self.c, "codex") else {
            return;
        };
        if probe(&codex, &["debug", "prompt-input"], CODEX_DEADLINE)
            .is_some_and(|o| o.contains("radin-batch"))
        {
            self.line("  OK       Codex lists radin skills");
        } else {
            self.line("  NOTE     Codex skills listing did not answer (informational)");
        }
    }

    fn check_opencode(&mut self) {
        let dir = env_dir(self.c, "XDG_CONFIG_HOME", self.home.join(".config")).join("opencode");
        self.line("\nopencode:");
        self.check_cli("opencode");
        self.check_guidance(&dir.join("AGENTS.md"));
        self.check_dir(&dir.join("agents"));
        if let Some(bin) = which(self.c, "opencode") {
            match stdout_of(&bin, &["--version"])
                .as_deref()
                .and_then(first_version)
            {
                None => self.line("  NOTE     opencode version not readable"),
                Some(v) => {
                    let s = format!("{}.{}.{}", v[0], v[1], v[2]);
                    if v >= [1, 18, 29] {
                        self.line(&format!("  OK       opencode {s}"));
                    } else {
                        self.fail(&format!("  INVALID  opencode {s} is below 1.18.29"));
                    }
                }
            }
        }
        let mut agents = Vec::new();
        files_in_flat(&dir.join("agents"), &mut agents);
        for f in agents {
            self.check_agent_file(&f);
        }
        let mut cfg = PathBuf::from(&self.m.opencode_allow);
        if self.m.opencode_allow.is_empty() {
            if let Some(f) = ["opencode.json", "opencode.jsonc"]
                .iter()
                .map(|n| dir.join(n))
                .find(|f| f.is_file())
            {
                cfg = f;
            }
        }
        let text = fs::read_to_string(&cfg).unwrap_or_default();
        let rule = format!("{}/**", self.rh.display());
        if !cfg.as_os_str().is_empty()
            && text.contains("external_directory")
            && text.contains(&rule)
        {
            self.line("  OK       external_directory rule for ~/.radin/**");
        } else {
            self.fail(
                "  MISSING  opencode external_directory rule for ~/.radin/** (re-run install.sh)",
            );
        }
    }

    fn token_scan(&mut self) {
        let mut dirs = vec![self.rh.join("lib")];
        let skills: Vec<(PathBuf, &str)> = vec![
            (self.claude.join("skills"), "claude"),
            (self.home.join(".agents/skills"), "agents"),
        ];
        for (base, host) in skills {
            if host == "claude" && !self.host_installed("claude")
                || host == "agents" && !self.agents_render()
            {
                continue;
            }
            dirs.extend(self.s.skills.iter().map(|s| base.join(s)));
            dirs.push(self.rh.join(format!("hosts/{host}/lib")));
        }
        let tokens = ["RADIN_MODEL_", "RADIN_EFFORT_", "RADIN_CLI ", "@@skill:"];
        let hit = files_under(&dirs).iter().any(|f| {
            let t = String::from_utf8_lossy(&fs::read(f).unwrap_or_default()).into_owned();
            tokens.iter().any(|k| t.contains(k))
        });
        if hit {
            self.fail("  INVALID  unsubstituted RADIN_ token -- re-run install.sh");
        } else {
            self.line("  OK       no unsubstituted token left");
        }
    }

    fn hook_commands(&mut self) {
        let settings = self.claude.join("settings.json");
        self.line(&format!("\nHook commands ({}):", settings.display()));
        if !settings.is_file() {
            self.line("  OK       no settings.json, no hooks to check");
            return;
        }
        let (code, dead, _) = jsonedit::dead_hooks(&cbm::jctx(self.c), &settings.to_string_lossy());
        if code == 0 {
            self.line("  OK       every hook command resolves");
            return;
        }
        for l in dead.lines().filter(|l| !l.is_empty()) {
            self.fail(&format!(
                "  INVALID  hook {}",
                l.strip_prefix("DEAD     ").unwrap_or(l)
            ));
        }
    }

    fn agents_companions(&mut self) {
        let clis = &self.m.agents_clis;
        let (codex, opencode) = (
            clis.iter().any(|x| x == "codex"),
            clis.iter().any(|x| x == "opencode"),
        );
        let oc_dir = env_dir(self.c, "XDG_CONFIG_HOME", self.home.join(".config")).join("opencode");
        self.line("\nAgents companion skills (~/.agents/skills):");
        let read = |f: &str| fs::read_to_string(self.rh.join("lib").join(f)).unwrap_or_default();
        let invoked: Vec<String> = read("skill-names-agents.txt")
            .lines()
            .filter_map(|l| l.split_whitespace().next().map(str::to_string))
            .collect();
        let names: Vec<String> = read("companion-skills.txt")
            .lines()
            .filter(|l| !l.starts_with('#'))
            .filter_map(|l| l.split_whitespace().next().map(str::to_string))
            .collect();
        for name in names {
            let mut found = self
                .home
                .join(format!(".agents/skills/{name}/SKILL.md"))
                .is_file();
            // Codex reads only ~/.agents/skills, so a copy in the opencode dir breaks Codex runs.
            if !codex && opencode {
                found |= oc_dir.join(format!("skills/{name}/SKILL.md")).is_file();
            }
            if invoked.contains(&name) {
                if found {
                    self.line(&format!("  OK       {name}"));
                } else {
                    self.fail(&format!("  MISSING  {name}"));
                }
            } else {
                self.found(&name, found);
            }
        }
    }

    fn cbm_wiring(&mut self) {
        self.line("\ncodebase-memory-mcp wiring (informational):");
        let has = |p: &Path| fs::read_to_string(p).is_ok_and(|t| t.contains("codebase-memory-mcp"));
        let settings = self.claude.join("settings.json");
        if has(&settings) {
            self.line(&format!("  OK       hooks in {}", settings.display()));
        } else {
            self.line(&format!(
                "  MISSING  hooks in {} (re-run install.sh, or radin hooks all)",
                settings.display()
            ));
        }
        if has(&self.home.join(".claude.json")) || has(&self.c.cwd.join(".mcp.json")) {
            self.line("  OK       MCP server entry (user scope or this repo)");
        } else {
            self.line("  MISSING  MCP server entry -- re-run install.sh, or radin hooks mcp here");
        }
        if self.rh.join("backups").is_dir() {
            self.line(&format!(
                "  OK       config snapshots in {}/backups",
                self.rh.display()
            ));
        }
    }

    fn report(&mut self) {
        let rh = self.rh.display().to_string();
        self.line("radin doctor");
        self.line("============");
        if self.bad_manifest {
            let p = self.rh.join("manifest.json");
            self.line("\nManifest:");
            self.fail(&format!("  INVALID  {} (not valid JSON)", p.display()));
        }
        let claude = self.host_installed("claude");
        if claude {
            self.line(&format!("\nSkills ({}/skills):", self.claude.display()));
            let names: Vec<&str> = self
                .s
                .skills
                .iter()
                .copied()
                .chain(["thermo-nuclear"])
                .collect();
            for n in names {
                self.check_file(n, &self.claude.join(format!("skills/{n}/SKILL.md")));
            }
        }
        self.line(&format!("\nLib ({rh}/lib):"));
        self.line(&format!("\nCLI ({rh}/bin):"));
        self.check_file("radin (dispatcher)", &self.rh.join("bin/radin"));
        let linked = fs::read_link(self.home.join(".local/bin/radin"))
            .is_ok_and(|t| t == self.rh.join("bin/radin"));
        self.line(&format!(
            "  {:<20} {}",
            "radin (PATH)",
            if linked {
                "symlinked into ~/.local/bin"
            } else {
                "not on PATH (optional; skills fall back to the full path)"
            }
        ));
        for n in self.s.lib.clone() {
            self.check_file(n, &self.rh.join(format!("lib/{n}")));
        }
        let renders: Vec<&str> = [(claude, "claude"), (self.agents_render(), "agents")]
            .iter()
            .filter(|(on, _)| *on)
            .map(|(_, h)| *h)
            .collect();
        for h in renders {
            self.line(&format!("\nLib ({rh}/hosts/{h}/lib):"));
            for n in self.s.hostlib.clone() {
                self.check_file(n, &self.rh.join(format!("hosts/{h}/lib/{n}")));
            }
        }
        self.line("\nInstall-time substitutions:");
        self.token_scan();
        if claude {
            self.hook_commands();
        }
        if !self.m.files.is_empty() {
            self.line(&format!("\nDigests ({rh}/manifest.json):"));
            self.check_digests();
        }
        if self.agents_render() {
            self.line("\nAgents render (codex, opencode):");
            self.check_dir(&self.home.join(".agents/skills"));
            self.check_dir(&self.rh.join("hosts/agents/lib"));
            self.check_forbid("agents", &self.home.join(".agents/skills"));
            if ["codex", "opencode"]
                .iter()
                .all(|c| self.m.agents_clis.iter().any(|x| x == c))
            {
                self.line(
                    "  NOTE     codex and opencode share ~/.agents/skills: one render serves both",
                );
            }
        }
        if claude {
            self.check_forbid("claude", &self.claude.join("skills"));
        }
        if self.host_installed("codex") {
            self.check_codex();
        }
        if self.host_installed("opencode") {
            self.check_opencode();
        }
        self.line("\nCompanion tools (optional, advisory-only):");
        for t in ["rtk", "codebase-memory-mcp", "fff-mcp"] {
            self.found(t, which(self.c, t).is_some());
        }
        self.fff_servers();
        if claude {
            self.check_plugin("caveman", "caveman@caveman");
            self.check_plugin("ponytail", "ponytail@ponytail");
            self.check_plugin(
                "mattpocock-skills",
                "mattpocock-skills@claude-plugins-official",
            );
            for s in ["unslop", "technical-writing"] {
                self.found(
                    s,
                    self.claude.join(format!("skills/{s}/SKILL.md")).is_file(),
                );
            }
        }
        if !self.m.agents_clis.is_empty() {
            self.agents_companions();
        }
        if claude && cbm::which(self.c).is_some() {
            self.cbm_wiring();
        }
        self.out.push('\n');
    }
}

fn files_in_flat(dir: &Path, out: &mut Vec<PathBuf>) {
    let Ok(rd) = fs::read_dir(dir) else { return };
    out.extend(rd.flatten().map(|e| e.path()).filter(|p| {
        p.is_file()
            && p.file_name().is_some_and(|n| {
                n.to_string_lossy().starts_with("radin-") && n.to_string_lossy().ends_with(".md")
            })
    }));
    out.sort();
}

pub fn run(c: &Ctx, _args: &[String]) -> Out {
    let rh = c.home.join(".radin");
    let (m, bad_manifest) = match Manifest::read(&rh.join("manifest.json")) {
        Ok(m) => (m.unwrap_or_default(), false),
        Err(_) => (Manifest::default(), true),
    };
    let mut d = Doctor {
        c,
        s: shipped(),
        home: c.home.clone(),
        claude: c.home.join(".claude"),
        rh,
        m,
        bad_manifest,
        out: String::new(),
        missing: 0,
    };
    d.report();
    let mut out = d.out;
    if d.missing == 0 {
        out.push_str("All expected files present.\n");
        return (0, out, String::new());
    }
    let _ = writeln!(
        out,
        "{} check(s) failed (missing file, invalid file or unresolved hook).",
        d.missing
    );
    (1, out, String::new())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    fn script(dir: &Path, body: &str) -> PathBuf {
        let p = dir.join("mock");
        fs::write(&p, format!("#!/bin/sh\n{body}")).unwrap();
        fs::set_permissions(&p, fs::Permissions::from_mode(0o755)).unwrap();
        p
    }

    #[test]
    fn a_hung_probe_is_killed_at_the_deadline() {
        let d = tempfile::tempdir().unwrap();
        let p = script(d.path(), "sleep 30\n");
        let t = Instant::now();
        assert_eq!(probe(&p, &[], Duration::from_secs(1)), None);
        assert!(t.elapsed() < Duration::from_secs(10));
    }

    #[test]
    fn a_probe_merges_stderr_and_fails_on_a_non_zero_exit() {
        let d = tempfile::tempdir().unwrap();
        let p = script(d.path(), "echo out; echo err >&2\n");
        assert_eq!(
            probe(&p, &[], CODEX_DEADLINE).as_deref(),
            Some("out\nerr\n")
        );
        let p = script(d.path(), "echo out; exit 3\n");
        assert_eq!(probe(&p, &[], CODEX_DEADLINE), None);
    }

    #[test]
    fn the_version_is_the_first_dotted_triple() {
        assert_eq!(
            first_version("opencode v1.18.29 (2.0.0)"),
            Some([1, 18, 29])
        );
        assert_eq!(first_version("12.3.4.5"), Some([12, 3, 4]));
        assert_eq!(first_version("1.2 then 3.4.5"), Some([3, 4, 5]));
        assert_eq!(first_version("dev"), None);
        assert!([1, 18, 29] >= [1, 18, 29] && [2, 0, 0] > [1, 99, 99] && [1, 18, 28] < [1, 18, 29]);
    }

    #[test]
    fn the_longest_pattern_wins_at_the_leftmost_position() {
        let pats = vec!["Ask".to_string(), "AskUser".to_string(), "User".to_string()];
        assert_eq!(
            first_hit("x AskUserQuestion", &pats).as_deref(),
            Some("AskUser")
        );
        assert_eq!(first_hit("nothing", &pats), None);
    }
}

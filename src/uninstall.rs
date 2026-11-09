use crate::doctor::which;
use crate::manifest::Manifest;
use crate::shipped::shipped;
use crate::{cbm, jsonedit, Ctx, Out};
use sha2::{Digest, Sha256};
use std::collections::HashSet;
use std::fs;
use std::path::{Path, PathBuf};

const BEGIN: &str = "<!-- radin:begin -->";
const END: &str = "<!-- radin:end -->";

struct U<'a, 'b> {
    c: &'a Ctx<'b>,
    dry: bool,
    force: bool,
    home: PathBuf,
    rh: PathBuf,
    m: Manifest,
    has_files: bool,
    out: String,
    err: String,
    edited: u32,
    failed: bool,
}

fn exists(p: &Path) -> bool {
    fs::symlink_metadata(p).is_ok()
}

impl U<'_, '_> {
    fn line(&mut self, text: &str) {
        self.out.push_str(text);
        self.out.push('\n');
    }

    fn installed(&self, h: &str) -> bool {
        self.m.hosts.iter().any(|x| x == h)
            || (h == "claude" && (self.m.hosts.is_empty() || !self.has_files))
    }

    fn owned(&self) -> Vec<(String, String)> {
        if self.has_files {
            return self
                .m
                .files
                .iter()
                .filter_map(|(k, v)| Some((k.clone(), v.as_str()?.to_string())))
                .collect();
        }
        let s = shipped();
        let mut v: Vec<String> = s
            .skills
            .iter()
            .map(|n| format!(".claude/skills/{n}"))
            .collect();
        v.extend(s.lib.iter().map(|n| format!(".radin/lib/{n}")));
        v.extend(
            s.hostlib
                .iter()
                .map(|n| format!(".radin/hosts/claude/lib/{n}")),
        );
        v.push(".radin/bin/radin".into());
        v.into_iter().map(|p| (p, String::new())).collect()
    }

    fn remove_path(&mut self, label: &str, path: &Path) {
        if !exists(path) {
            return self.line(&format!("  ABSENT   {label}"));
        }
        if self.dry {
            return self.line(&format!("  WOULD REMOVE {label}"));
        }
        let real_dir = fs::symlink_metadata(path).is_ok_and(|m| m.is_dir());
        let r = if real_dir {
            fs::remove_dir_all(path)
        } else {
            fs::remove_file(path)
        };
        match r {
            Ok(()) => self.line(&format!("  REMOVED  {label}")),
            Err(e) => {
                self.err
                    .push_str(&format!("radin: cannot remove {}: {e}\n", path.display()));
                self.failed = true;
            }
        }
    }

    fn remove_owned(&mut self, rel: &str, want: &str) {
        let path = PathBuf::from(format!("{}/{rel}", self.home.display()));
        if want == "-" {
            return self.line(&format!("  KEPT (not radin's) {rel}"));
        }
        let Ok(meta) = fs::symlink_metadata(&path) else {
            return self.line(&format!("  ABSENT   {rel}"));
        };
        let mine = want.is_empty()
            || (self.force && (meta.is_symlink() || !path.is_dir()))
            || (meta.is_file()
                && fs::read(&path).is_ok_and(|b| format!("{:x}", Sha256::digest(b)) == want));
        if mine {
            self.remove_path(rel, &path);
        } else {
            self.line(&format!("  KEPT (edited) {rel}"));
            self.edited += 1;
        }
    }

    fn prune(&mut self, rel: &str, seen: &mut HashSet<PathBuf>) {
        let roots: Vec<String> = [".claude/skills", ".agents/skills", ".radin"]
            .iter()
            .map(|r| format!("{}/{r}/", self.home.display()))
            .collect();
        let mut d = PathBuf::from(format!("{}/{rel}", self.home.display()));
        loop {
            d = match d.parent() {
                Some(p) => p.to_path_buf(),
                None => return,
            };
            let with_slash = format!("{}/", d.display());
            if !roots
                .iter()
                .any(|r| with_slash.starts_with(r.as_str()) && with_slash.len() > r.len())
            {
                return;
            }
            if !d.is_dir() {
                continue;
            }
            if fs::remove_dir(&d).is_err() {
                if seen.insert(d.clone()) {
                    self.line(&format!("  KEPT (holds other files) {}", d.display()));
                }
                return;
            }
        }
    }

    fn strip_block(&mut self, file: &Path) {
        let Ok(text) = fs::read_to_string(file) else {
            return;
        };
        let lines: Vec<&str> = text
            .strip_suffix('\n')
            .unwrap_or(&text)
            .split('\n')
            .collect();
        let at = |m: &str| -> Vec<usize> { (0..lines.len()).filter(|&i| lines[i] == m).collect() };
        let (b, e) = (at(BEGIN), at(END));
        if b.is_empty() && e.is_empty() {
            return;
        }
        let f = file.display();
        if b.len() != 1 || e.len() != 1 || b[0] > e[0] {
            return self.line(&format!(
                "  KEPT (markers unbalanced) {f}: delete the radin block by hand"
            ));
        }
        if self.dry {
            return self.line(&format!("  WOULD STRIP {f}"));
        }
        let mut out = String::new();
        let mut pending = 0;
        for l in lines
            .iter()
            .enumerate()
            .filter(|(i, _)| *i < b[0] || *i > e[0])
            .map(|(_, l)| l)
        {
            if l.chars().all(|c| c == ' ' || c == '\t') {
                pending += 1;
            } else {
                out.push_str(&"\n".repeat(pending));
                pending = 0;
                out.push_str(l);
                out.push('\n');
            }
        }
        if fs::write(file, out).is_ok() {
            self.line(&format!("  STRIPPED {f}"));
        }
    }

    fn opencode_rule(&mut self) {
        let cfg = self.m.opencode_allow.clone();
        let rh = self.rh.display().to_string();
        if cfg.is_empty() {
            return self.line(&format!(
                "  SKIPPED  no opencode rule recorded -- remove the external_directory rule for {rh}/** by hand"
            ));
        }
        if self.dry {
            return self.line(&format!(
                "  WOULD REMOVE opencode external_directory rule in {cfg}"
            ));
        }
        let real = fs::canonicalize(&self.rh).unwrap_or_else(|_| self.rh.clone());
        let globs = [format!("{rh}/**"), format!("{}/**", real.display())];
        let refs: Vec<&str> = globs.iter().map(String::as_str).collect();
        if jsonedit::edit_ext_dir(&cfg, false, &refs).0 == 0 {
            self.line(&format!(
                "  REMOVED  opencode external_directory rule {rh}/** in {cfg}"
            ));
        } else {
            self.line(&format!(
                "  SKIPPED  {cfg} is not plain JSON -- remove the external_directory rule for {rh}/** by hand"
            ));
        }
    }

    fn untouched(&mut self) {
        let (home, rh) = (
            self.home.display().to_string(),
            self.rh.display().to_string(),
        );
        let claude = format!("{home}/.claude");
        self.line("\nLeft untouched:");
        self.line(&format!(
            "  {:<20} not vendored by radin, remove manually if wanted",
            "thermo-nuclear"
        ));
        for s in ["unslop", "technical-writing"] {
            self.line(&format!(
                "  {s:<20} fetched from cursor/plugins at install time, remove manually if wanted"
            ));
        }
        let pm = self.m.package_manager.as_str();
        let rtk = match pm {
            "brew" => "brew uninstall rtk".to_string(),
            "mise" => "mise rm -g aqua:rtk-ai/rtk".to_string(),
            _ => format!(
                "rm {}",
                which(self.c, "rtk")
                    .unwrap_or_else(|| self.home.join(".local/bin/rtk"))
                    .display()
            ),
        };
        let headroom = if pm == "mise" {
            "mise rm -g pipx:headroom-ai"
        } else {
            "pipx uninstall headroom-ai"
        };
        for (n, how) in [
            ("rtk", rtk.as_str()),
            ("codebase-memory-mcp", "codebase-memory-mcp uninstall"),
            ("headroom", headroom),
            ("caveman", "claude plugin uninstall caveman@caveman"),
            ("ponytail", "claude plugin uninstall ponytail@ponytail"),
        ] {
            self.line(&format!("  {n:<20} advisory install, remove with: {how}"));
        }
        self.line(&format!(
            "  {:<20} {claude}/.ponytail-band stays -- run /ponytail band on to show the band again",
            ""
        ));
        self.line(&format!(
            "  {:<20} advisory install, remove with: claude plugin uninstall mattpocock-skills@claude-plugins-official",
            "mattpocock-skills"
        ));
        self.line("  Any <repo-root>/.radin/ backlog directory -- your data, your call");
        if fs::read_to_string(format!("{claude}/CLAUDE.md"))
            .is_ok_and(|t| t.contains("<!-- codebase-memory-mcp MCP tools -->"))
        {
            self.line(&format!(
                "  {claude}/CLAUDE.md keeps the codebase-memory-mcp section written by radin hooks -- delete it by hand"
            ));
        }
        self.line("  Any <repo-root>/.mcp.json entry for codebase-memory-mcp -- per-repo config, delete it by hand");
        if self.rh.join("backups").is_dir() {
            self.line(&format!(
                "  {rh}/backups holds copies of your settings.json -- your data, your call"
            ));
        }
        if self.rh.join("telemetry").is_dir() {
            self.line(&format!(
                "  {rh}/telemetry holds your telemetry records -- your data, your call"
            ));
        }
        if !self.m.agents_skills.is_empty() {
            self.line(&format!(
                "  {home}/.agents/skills: {} -- fetched companion skills, remove by hand if wanted",
                self.m.agents_skills.join(" ")
            ));
        }
        if !self.has_files {
            let mut held: Vec<PathBuf> = fs::read_dir(self.home.join(".agents/skills"))
                .into_iter()
                .flatten()
                .flatten()
                .map(|e| e.path())
                .filter(|p| {
                    p.file_name()
                        .is_some_and(|n| n.to_string_lossy().starts_with("radin-"))
                })
                .collect();
            held.sort();
            held.push(self.rh.join("hosts/agents"));
            let held: String = held
                .iter()
                .filter(|p| p.exists())
                .map(|p| format!(" {}", p.display()))
                .collect();
            if !held.is_empty() {
                self.line(&format!("  agents render, remove by hand:{held}"));
            }
        }
    }

    fn run(&mut self) -> i32 {
        let rh = self.rh.display().to_string();
        let claude = self.home.join(".claude");
        self.line("radin uninstall");
        self.line("===============");
        if self.dry {
            self.line("(dry run: nothing changes)");
        }
        if self.installed("claude") {
            self.line(&format!(
                "\nPermissions ({}/settings.json):",
                claude.display()
            ));
            if self.dry {
                self.line("  WOULD REMOVE the Read(.../.radin/**) rules");
            } else {
                let (code, out, err) = cbm::unallow(self.c);
                self.out.push_str(&out);
                self.err.push_str(&err);
                if code != 0 {
                    self.line("  SKIPPED  settings.json is not valid JSON -- remove the Read(.../.radin/**) rules by hand");
                }
            }
        }
        if self.installed("opencode") {
            self.line("\nopencode config:");
            self.opencode_rule();
        }
        self.line("\nGuidance blocks:");
        let dir = |key: &str, default: PathBuf| {
            (self.c.env)(key)
                .filter(|v| !v.is_empty())
                .map_or(default, PathBuf::from)
        };
        let guidance = [
            ("claude", claude.join("CLAUDE.md")),
            (
                "codex",
                dir("CODEX_HOME", self.home.join(".codex")).join("AGENTS.md"),
            ),
            (
                "opencode",
                dir("XDG_CONFIG_HOME", self.home.join(".config")).join("opencode/AGENTS.md"),
            ),
        ];
        for (h, f) in guidance {
            if self.installed(h) {
                self.strip_block(&f);
            }
        }
        self.line("\nFiles:");
        let owned = self.owned();
        for (rel, want) in owned.iter().filter(|(r, _)| !r.is_empty()) {
            self.remove_owned(rel, want);
        }
        let s = shipped();
        for n in s.renamed_skills.iter().chain(&s.retired_skills) {
            self.remove_path(
                &format!(".claude/skills/{n}"),
                &claude.join(format!("skills/{n}")),
            );
        }
        if !self.dry {
            let mut seen = HashSet::new();
            for (rel, _) in owned.iter().filter(|(r, _)| !r.is_empty()) {
                self.prune(rel, &mut seen);
            }
        }
        self.line(&format!("\nCLI ({rh}/bin):"));
        let link = self.home.join(".local/bin/radin");
        if fs::read_link(&link)
            .is_ok_and(|t| t == self.rh.join("bin/radin") || t == claude.join(".radin/bin/radin"))
        {
            self.remove_path("radin (~/.local/bin symlink)", &link);
        }
        for (label, f) in [
            ("radin-tui", "radin-tui"),
            ("radin-cbm-json", "radin-cbm-json"),
            ("build stamp", ".radin-tui.sum"),
            ("build stamp", ".radin-cbm-json.sum"),
        ] {
            self.remove_path(label, &self.rh.join("bin").join(f));
        }
        if !self.dry {
            let _ = fs::remove_dir(self.rh.join("bin"));
        }
        self.untouched();
        if self.dry {
            self.line("\nDry run done. Nothing changed.");
            return 0;
        }
        if self.failed {
            return 1;
        }
        if self.edited == 0 {
            let _ = fs::remove_file(self.rh.join("manifest.json"));
            let _ = fs::remove_file(self.rh.join("install_root"));
            let _ = fs::remove_dir(&self.rh);
            self.line("\nradin removed.");
        } else {
            let n = self.edited;
            self.line(&format!(
                "\nradin removed, except {n} edited file(s). Run again with --force to remove them."
            ));
        }
        0
    }
}

pub fn run(c: &Ctx, args: &[String]) -> Out {
    let (mut dry, mut force) = (false, false);
    for a in args {
        match a.as_str() {
            "--dry-run" => dry = true,
            "--force" => force = true,
            _ => {
                return (
                    2,
                    String::new(),
                    "usage: radin uninstall [--dry-run] [--force]\n".into(),
                );
            }
        }
    }
    let rh = c.home.join(".radin");
    let parsed = match fs::read_to_string(rh.join("manifest.json")) {
        Ok(t) => serde_json::from_str::<serde_json::Value>(&t)
            .ok()
            .and_then(|v| {
                Some((
                    v.get("files").is_some_and(|f| f.is_object()),
                    serde_json::from_value::<Manifest>(v).ok()?,
                ))
            })
            .map(Some),
        Err(_) => Some(None),
    };
    let Some(parsed) = parsed else {
        return (
            1,
            String::new(),
            "radin: ~/.radin/manifest.json is not valid JSON: fix or delete it, then re-run\n"
                .into(),
        );
    };
    let (has_files, m) = parsed.unwrap_or_default();
    let mut u = U {
        c,
        dry,
        force,
        home: c.home.clone(),
        rh,
        m,
        has_files,
        out: String::new(),
        err: String::new(),
        edited: 0,
        failed: false,
    };
    let code = u.run();
    (code, u.out, u.err)
}

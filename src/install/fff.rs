use super::Session;
use crate::jsonedit;
use std::fs;
use std::path::PathBuf;
use std::process::{Command, Stdio};

pub(crate) const NAME: &str = "fff";
pub(crate) const BIN: &str = "fff-mcp";
pub(super) const CURL: &str =
    "curl -fsSL https://raw.githubusercontent.com/dmtrKovalenko/fff/main/install-mcp.sh | bash";
/// radin upgrades the binary on `--refresh`, so the server's own startup check only adds latency.
pub(super) const ARG: &str = "--no-update-check";

/// The args that add or remove radin's `fff` server through a host CLI.
pub(crate) fn cli_args<'a>(host: &str, add: bool, bin: &'a str) -> Vec<&'a str> {
    match (host, add) {
        ("claude", true) => vec!["mcp", "add", "-s", "user", NAME, "--", bin, ARG],
        ("claude", false) => vec!["mcp", "remove", "-s", "user", NAME],
        (_, true) => vec!["mcp", "add", NAME, "--", bin, ARG],
        (_, false) => vec!["mcp", "remove", NAME],
    }
}

pub(crate) fn quiet(cli: &str, args: &[&str]) -> bool {
    Command::new(cli)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_ok_and(|s| s.success())
}

impl Session<'_> {
    pub(super) fn fff_cmd(&self, mgr: &str) -> String {
        match (mgr, &self.brew, &self.mise) {
            ("brew", Some(b), _) => format!(
                "{0} install dmtrKovalenko/fff/fff-mcp || {0} upgrade fff-mcp",
                b.display()
            ),
            ("mise", _, Some(m)) => format!(
                "{} use -g 'github:dmtrKovalenko/fff[matching=fff-mcp,rename_exe=fff-mcp]@latest'",
                m.display()
            ),
            _ => CURL.into(),
        }
    }

    fn fff_bin(&self) -> Option<PathBuf> {
        self.which(BIN).or_else(|| {
            let p = self.home.join(".local/bin").join(BIN);
            p.is_file().then_some(p)
        })
    }

    /// Registers fff with `host` (claude, codex or opencode). An `fff` entry radin did not add stays untouched and unowned.
    pub(super) fn wire_fff(&mut self, host: &str) {
        let key = format!("fff:{host}");
        if self.owned_flag(&key) {
            self.fff_owned.push(key.clone());
        }
        let Some(bin) = self.fff_bin() else {
            self.ui.warn(&format!(
                "fff-mcp not found: skipping its {host} registration."
            ));
            return;
        };
        let bin = bin.display().to_string();
        let added = if host == "opencode" {
            let f = self.opencode_config.clone();
            let jsonc_only = !f.exists() && self.opencode_dir.join("opencode.jsonc").exists();
            let edited = (!jsonc_only && f.parent().is_some_and(|d| fs::create_dir_all(d).is_ok()))
                .then(|| jsonedit::opencode_mcp(&f.to_string_lossy(), NAME, &[&bin, ARG], true));
            match edited {
                Some((0, out, _)) => Some(out.starts_with("ADDED")),
                _ => {
                    self.ui.warn(&format!(
                        "could not edit the opencode config safely: merge this server into {}:",
                        f.display()
                    ));
                    println!(
                        "{{\"mcp\":{{\"{NAME}\":{{\"type\":\"local\",\"command\":[\"{bin}\",\"{ARG}\"],\"enabled\":true}}}}}}"
                    );
                    return;
                }
            }
        } else if self.which(host).is_none() {
            self.ui.warn(&format!(
                "fff registration skipped: the '{host}' CLI is not on PATH."
            ));
            return;
        } else if quiet(host, &["mcp", "get", NAME]) {
            Some(false)
        } else {
            quiet(host, &cli_args(host, true, &bin)).then_some(true)
        };
        match added {
            Some(true) => {
                if !self.fff_owned.contains(&key) {
                    self.fff_owned.push(key);
                }
                self.ui.ok(&format!("fff registered for {host}."));
            }
            Some(false) => self.ui.ok(&format!("fff already registered for {host}.")),
            None => self.ui.warn(&format!(
                "fff registration failed for {host} -- radin itself is unaffected."
            )),
        }
    }
}

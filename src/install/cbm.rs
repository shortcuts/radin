use super::Session;
use crate::{cbm, jsonedit};
use std::fs;
use std::process::{Command, Stdio};

impl Session<'_> {
    fn cbm_claude_md(&self) {
        let (_, out, _) = cbm::run_hooks(self.c, &["claude-md".to_string()]);
        if self.ui.loud {
            print!("{out}");
        }
    }

    /// Wires codebase-memory-mcp into Claude Code, then adds the Read rule for ~/.radin.
    pub(super) fn wire_cbm(&mut self) {
        if !self.is_selected("claude") {
            return;
        }
        if let Some(bin) = self.cbm_bin() {
            self.wire_with(&bin);
        }
        let (code, _, _) = cbm::allow(self.c);
        if code != 0 {
            self.ui
                .warn("could not add the Read rule for ~/.radin to settings.json --");
            self.ui
                .warn("Claude Code will ask before each read of radin's own files.");
        } else if self.migrated || self.legacy_left {
            let (code, _, _) = cbm::unallow_legacy(self.c);
            if code != 0 {
                self.ui.warn(
                    "could not remove the old Read rule for ~/.claude/.radin from settings.json.",
                );
            }
        }
    }

    fn wire_with(&mut self, bin: &std::path::Path) {
        let ui = &self.ui;
        let ver = Command::new(bin)
            .arg("--version")
            .stdin(Stdio::null())
            .stderr(Stdio::null())
            .output()
            .ok()
            .and_then(|o| {
                String::from_utf8_lossy(&o.stdout)
                    .lines()
                    .next()
                    .map(str::to_string)
            })
            .unwrap_or_default();
        let stamp = self.rh.join("cbm-wired.stamp");
        let settings = self
            .claude
            .join("settings.json")
            .to_string_lossy()
            .into_owned();
        let claude_json = self
            .home
            .join(".claude.json")
            .to_string_lossy()
            .into_owned();
        let current = !self.o.refresh
            && !ver.is_empty()
            && fs::read_to_string(&stamp).is_ok_and(|s| s == ver)
            && jsonedit::wired(&settings, &claude_json, cbm::NAME).0 == 0;
        if current {
            self.cbm_cfg = true;
            ui.ok(&format!(
                "codebase-memory-mcp wiring already current ({ver})."
            ));
            self.cbm_claude_md();
            return;
        }
        let indexed = Command::new(bin)
            .args(["config", "set", "auto_index", "true"])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .is_ok_and(|s| s.success());
        if !indexed {
            ui.warn("could not enable codebase-memory-mcp auto-index -- run: codebase-memory-mcp config set auto_index true");
        }
        let log = self.rh.join("cbm-config.log");
        let (code, out, err) = cbm::run_wire(self.c);
        let text = format!("{out}{err}");
        let _ = fs::write(&log, &text);
        if ui.verbose {
            print!("{text}");
        }
        let shown = ui.bold(&log.display().to_string());
        if code == 0 {
            self.cbm_cfg = true;
            if text.lines().any(|l| l.starts_with("PARTIAL ")) {
                ui.warn("codebase-memory-mcp reported a failure while configuring Claude Code,");
                ui.warn(&format!(
                    "but its hooks and MCP entry are in place. Details: {shown}"
                ));
            } else {
                ui.ok("codebase-memory-mcp wired: skill, graph agents, hooks, user-scope MCP (every repo, no per-project step).");
                if !ver.is_empty() {
                    let _ = fs::write(&stamp, &ver);
                }
            }
            self.cbm_claude_md();
        } else {
            ui.warn("codebase-memory-mcp configuration failed -- radin itself is unaffected.");
            ui.warn(&format!(
                "Your own hooks were restored from the snapshot. Details: {shown}"
            ));
            ui.info("Falling back to radin's merge-only wiring:");
            self.cbm_claude_md();
            ui.info("Then run \"radin hooks mcp\" in each repo for its .mcp.json entry.");
        }
    }
}

use super::plan::path_taken;
use super::{Session, Stop};
use crate::jsonedit::{self, Parsed};
use serde_json::Value;
use std::fs;
use std::os::unix::fs::{symlink, PermissionsExt};
use std::path::{Path, PathBuf};

/// A radin home holds a manifest that names its install time and its companion tools.
pub fn radin_home_at(dir: &Path) -> bool {
    fs::read_to_string(dir.join("manifest.json"))
        .is_ok_and(|t| t.contains("\"installed_at\"") && t.contains("\"companion_tools\""))
}

const BASH_BIN: [&str; 4] = [
    "radin-tui",
    "radin-cbm-json",
    ".radin-tui.sum",
    ".radin-cbm-json.sum",
];

const HOOK_VERBS: [(&str, &str); 10] = [
    ("backlog", "backlog"),
    ("state", "state"),
    ("scope", "scope"),
    ("prompt", "prompt"),
    ("stats", "stats"),
    ("telemetry", "telemetry"),
    ("update", "update"),
    ("doctor", "doctor"),
    ("uninstall", "uninstall"),
    ("cbm-hooks", "hooks"),
];

/// Maps `<home>/.radin/lib/radin-<name>.sh <args>` to `bin <verb> <args>`. `None` means no match, `Some(None)` no mapping.
fn map_hook(cmd: &str, bin: &str) -> Option<Option<String>> {
    let body = cmd.strip_prefix("bash ").unwrap_or(cmd).trim_start();
    let i = body.find("/lib/radin-")?;
    let prefix = &body[..i];
    prefix
        .strip_suffix("/.claude/.radin")
        .or_else(|| prefix.strip_suffix("/.radin"))?;
    let rest = &body[i + "/lib/radin-".len()..];
    let end = rest.find(".sh")?;
    let (name, args) = (&rest[..end], &rest[end + 3..]);
    if !(args.is_empty() || args.starts_with(' ')) {
        return None;
    }
    let verb = match name {
        "cbm-config" => match args.split_whitespace().next() {
            Some("install") => {
                return Some(Some(format!(
                    "{bin} wire{}",
                    &args.trim_start()["install".len()..]
                )))
            }
            Some("repair") => "repair",
            _ => return Some(None),
        },
        n => match HOOK_VERBS.iter().find(|h| h.0 == n) {
            Some(h) => h.1,
            None => return Some(None),
        },
    };
    Some(Some(format!("{bin} {verb}{args}")))
}

impl Session<'_> {
    pub(super) fn migrate_home(&mut self) -> Result<(), Stop> {
        let old = self.claude.join(".radin");
        if !radin_home_at(&old) {
            return Ok(());
        }
        let migrating = self.home.join(".radin.migrating");
        if self.o.dry {
            self.ui.info(&format!(
                "would move {} to {}",
                old.display(),
                self.rh.display()
            ));
            return Ok(());
        }
        if path_taken(&self.rh) {
            if radin_home_at(&self.rh) {
                self.ui.warn(&format!(
                    "{} is still there, unused: delete it by hand once you checked it.",
                    old.display()
                ));
                self.legacy_left = true;
                return Ok(());
            }
            return Err(self.abort(format!(
                "{} is not radin's: move it away, then re-run.",
                self.rh.display()
            )));
        }
        if path_taken(&migrating) {
            return Err(self.abort(format!(
                "{} was left by an interrupted move: inspect it, move it away, then re-run.",
                migrating.display()
            )));
        }
        if fs::rename(&old, &migrating).is_err() {
            return Err(self.abort(format!(
                "mv failed: {} is intact; the partial copy is at {}.",
                old.display(),
                migrating.display()
            )));
        }
        if fs::rename(&migrating, &self.rh).is_err() {
            return Err(self.abort(format!(
                "mv failed: the data is at {}, {} is gone; move it to {} by hand.",
                migrating.display(),
                old.display(),
                self.rh.display()
            )));
        }
        self.migrated = true;
        self.ui.ok("moved ~/.claude/.radin to ~/.radin");
        Ok(())
    }

    fn remove_file(&self, p: &Path) {
        if p.symlink_metadata().is_ok_and(|m| m.is_file()) && fs::remove_file(p).is_ok() {
            println!("removed {}", p.display());
        }
    }

    /// Detects a bash-era install by its manifest or its dispatcher script.
    pub(super) fn bash_era(&self) -> bool {
        let s = crate::shipped::shipped();
        let listed = self.prev.as_ref().is_some_and(|m| {
            m.manifest_version > 0 && m.lib.iter().any(|n| !s.lib.contains(&n.as_str()))
        });
        let script = fs::read(self.rh.join("bin/radin")).is_ok_and(|b| b.starts_with(b"#!"));
        listed || script
    }

    /// Removes files the previous manifest lists as radin's own and this release no longer ships.
    pub(super) fn remove_orphans(&self) {
        let s = crate::shipped::shipped();
        let lib = self.rh.join("lib");
        if let Some(m) = self.prev.as_ref().filter(|m| m.manifest_version > 0) {
            for n in &m.lib {
                if !s.lib.contains(&n.as_str()) && !s.hostlib.contains(&n.as_str()) {
                    self.remove_file(&lib.join(n));
                }
            }
            for f in BASH_BIN {
                self.remove_file(&self.rh.join("bin").join(f));
            }
        }
        if self.migrated {
            for n in s.hostlib.iter().chain(&s.retired_lib) {
                self.remove_file(&lib.join(n));
            }
        }
    }

    pub(super) fn install_binary(&self) -> Result<(), Stop> {
        let dst = self.rh.join("bin/radin");
        let exe = std::env::current_exe()?;
        if fs::canonicalize(&exe).ok() == fs::canonicalize(&dst).ok() {
            return Ok(());
        }
        fs::create_dir_all(dst.parent().unwrap())?;
        let tmp = dst.with_file_name(".radin.new");
        fs::copy(&exe, &tmp)?;
        fs::set_permissions(&tmp, fs::Permissions::from_mode(0o755))?;
        fs::rename(&tmp, &dst)?;
        Ok(())
    }

    pub(super) fn link_cli(&mut self) -> Result<(), Stop> {
        let target = self.rh.join("bin/radin");
        let link = self.home.join(".local/bin/radin");
        let now = fs::read_link(&link).ok();
        let ours = |t: &PathBuf| *t == target || *t == self.claude.join(".radin/bin/radin");
        if link.exists() && !now.as_ref().is_some_and(ours) {
            self.ui.warn(&format!(
                "{} exists and isn't radin's -- leaving it alone; skills use the full path.",
                link.display()
            ));
            return Ok(());
        }
        fs::create_dir_all(link.parent().unwrap())?;
        if path_taken(&link) {
            fs::remove_file(&link)?;
        }
        symlink(&target, &link)?;
        self.cli_on_path = true;
        self.ui.ok(&format!(
            "radin CLI linked at {}",
            self.ui.bold(&link.display().to_string())
        ));
        let local = self.home.join(".local/bin");
        let on_path = (self.c.env)("PATH")
            .unwrap_or_default()
            .split(':')
            .any(|d| Path::new(d) == local);
        if on_path {
            self.cli_value = "radin".into();
        } else {
            self.ui.warn(
                "$HOME/.local/bin is not on your PATH -- skills use the full path until it is.",
            );
        }
        Ok(())
    }

    /// Rewrites settings.json hook commands that run a removed bash script.
    pub(super) fn rewrite_hooks(&self) {
        let bin = self.rh.join("bin/radin").to_string_lossy().into_owned();
        let mut files = vec![self.claude.join("settings.json")];
        if let Some(d) = (self.c.env)("CLAUDE_CONFIG_DIR").filter(|d| !d.is_empty()) {
            let p = PathBuf::from(d).join("settings.json");
            if !files.contains(&p) {
                files.push(p);
            }
        }
        for f in files {
            let path = f.to_string_lossy().into_owned();
            let Parsed::Ok(mut root) = jsonedit::parse_file(&path) else {
                continue;
            };
            let mut changed = false;
            let groups = root
                .get_mut("hooks")
                .and_then(Value::as_object_mut)
                .into_iter()
                .flat_map(|h| h.values_mut())
                .filter_map(Value::as_array_mut)
                .flatten()
                .filter_map(|g| g.get_mut("hooks").and_then(Value::as_array_mut))
                .flatten();
            for hook in groups {
                let Some(cmd) = hook
                    .get("command")
                    .and_then(Value::as_str)
                    .map(str::to_string)
                else {
                    continue;
                };
                match map_hook(&cmd, &bin) {
                    Some(Some(new)) => {
                        self.ui.info(&format!("hook {cmd} -> {new}"));
                        hook["command"] = Value::String(new);
                        changed = true;
                    }
                    Some(None) => self
                        .ui
                        .warn(&format!("hook {cmd} still names a removed script")),
                    None => {}
                }
            }
            if changed {
                if let Err(e) = jsonedit::write_file(&path, &root) {
                    self.ui.warn(e.trim());
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn maps_known_scripts_and_flags_unknown_ones() {
        let m = |c| map_hook(c, "/h/.radin/bin/radin");
        assert_eq!(
            m("bash $HOME/.radin/lib/radin-doctor.sh"),
            Some(Some("/h/.radin/bin/radin doctor".into()))
        );
        assert_eq!(
            m("/h/.claude/.radin/lib/radin-cbm-hooks.sh claude-md"),
            Some(Some("/h/.radin/bin/radin hooks claude-md".into()))
        );
        assert_eq!(
            m("~/.radin/lib/radin-cbm-config.sh install"),
            Some(Some("/h/.radin/bin/radin wire".into()))
        );
        assert_eq!(m("$HOME/.radin/lib/radin-nope.sh"), Some(None));
        assert_eq!(m("echo foreign"), None);
        assert_eq!(m("$HOME/.radin/lib/radin-doctor.shx"), None);
    }
}

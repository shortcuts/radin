use super::plan::path_taken;
use super::{Session, Stop};
use std::fs;
use std::os::unix::fs::{symlink, PermissionsExt};
use std::path::{Path, PathBuf};

/// A radin home holds a manifest that names its install time and its companion tools.
pub fn radin_home_at(dir: &Path) -> bool {
    fs::read_to_string(dir.join("manifest.json"))
        .is_ok_and(|t| t.contains("\"installed_at\"") && t.contains("\"companion_tools\""))
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

    /// Removes the lib files a migrated home carried over from the old layout.
    pub(super) fn remove_orphans(&self) {
        let s = crate::shipped::shipped();
        let lib = self.rh.join("lib");
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
}

use super::{die, jctx, which_or_die, NAME};
use crate::{jsonedit, Ctx, Out};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

const P: &str = "radin-cbm-config";

#[derive(Default)]
struct Acc {
    out: String,
    err: String,
}

impl Acc {
    fn take(&mut self, o: Out) -> i32 {
        self.out.push_str(&o.1);
        self.err.push_str(&o.2);
        o.0
    }
    fn done(self, code: i32) -> Out {
        (code, self.out, self.err)
    }
}

struct Dirs {
    claude: PathBuf,
    real: PathBuf,
    backups: PathBuf,
    settings: String,
    claude_json: String,
    config_dir_override: Option<PathBuf>,
}

impl Dirs {
    fn new(c: &Ctx) -> Dirs {
        let claude = c.home.join(".claude");
        let real = if claude.is_dir() {
            fs::canonicalize(&claude).unwrap_or_else(|_| claude.clone())
        } else {
            claude.clone()
        };
        let unset = (c.env)("CLAUDE_CONFIG_DIR").is_none_or(|v| v.is_empty());
        let config_dir_override = (real != claude && unset).then(|| real.clone());
        Dirs {
            settings: s(&claude.join("settings.json")),
            claude_json: s(&c.home.join(".claude.json")),
            backups: c.home.join(".radin/backups"),
            claude,
            real,
            config_dir_override,
        }
    }
}

fn s(p: &Path) -> String {
    p.to_string_lossy().into_owned()
}

fn stamp() -> String {
    crate::telemetry::now_utc().replace(['-', ':'], "")
}

fn io<T>(r: std::io::Result<T>, what: &Path) -> Result<T, Out> {
    r.map_err(|e| die(P, &format!("{}: {e}", what.display())))
}

fn snapshot(d: &Dirs, a: &mut Acc) -> Result<(String, String), Out> {
    let stamp = stamp();
    io(fs::create_dir_all(&d.backups), &d.backups)?;
    let mut copy = |src: &str, name: &str| -> Result<String, Out> {
        if !Path::new(src).is_file() {
            a.out
                .push_str(&format!("ABSENT   {src} (nothing to snapshot)\n"));
            return Ok(String::new());
        }
        let dest = d.backups.join(format!("{name}.{stamp}.bak"));
        io(fs::copy(src, &dest), &dest)?;
        a.out.push_str(&format!("SNAPSHOT {}\n", dest.display()));
        Ok(s(&dest))
    };
    Ok((
        copy(&d.settings, "settings.json")?,
        copy(&d.claude_json, "claude.json")?,
    ))
}

fn newest_snapshot(d: &Dirs, prefix: &str) -> String {
    let want = format!("{prefix}.");
    let mut found: Vec<_> = fs::read_dir(&d.backups)
        .into_iter()
        .flatten()
        .flatten()
        .filter(|e| {
            let n = e.file_name().to_string_lossy().into_owned();
            n.starts_with(&want) && n.ends_with(".bak") && e.path().is_file()
        })
        .map(|e| e.path())
        .collect();
    found.sort();
    found.last().map(|p| s(p)).unwrap_or_default()
}

/// Upstream bakes this machine's $HOME into each hook script and keeps it on rerun; moving them forces a rewrite.
fn stash_hook_scripts(d: &Dirs, a: &mut Acc) -> Result<(), Out> {
    let dir = d.real.join("hooks");
    let mut found: Vec<_> = fs::read_dir(&dir)
        .into_iter()
        .flatten()
        .flatten()
        .filter(|e| e.file_name().to_string_lossy().starts_with("cbm-") && e.path().is_file())
        .map(|e| e.path())
        .collect();
    found.sort();
    let stamp = stamp();
    for f in found {
        let dest = d.backups.join(format!("hooks.{stamp}"));
        io(fs::create_dir_all(&dest), &dest)?;
        let target = dest.join(f.file_name().unwrap_or_default());
        // ~/.config/.claude is often on another filesystem than ~/.radin, where rename fails.
        if fs::rename(&f, &target).is_err() {
            io(fs::copy(&f, &target), &target)?;
            io(fs::remove_file(&f), &f)?;
        }
        a.out.push_str(&format!(
            "STASHED  {} -> {}/ (upstream rewrites it for this machine)\n",
            f.display(),
            dest.display()
        ));
    }
    Ok(())
}

/// Runs upstream's installer; the error is the last 20 lines of its output.
fn run_upstream(bin: &str, d: &Dirs, a: &mut Acc) -> Result<(), String> {
    let mut cmd = Command::new(bin);
    cmd.args(["install", "-y"]).env("SHELL", "/bin/sh");
    if let Some(dir) = &d.config_dir_override {
        a.out.push_str(&format!(
            "SYMLINK  {} resolves to {} -- passing it as CLAUDE_CONFIG_DIR (#1722)\n",
            d.claude.display(),
            d.real.display()
        ));
        cmd.env("CLAUDE_CONFIG_DIR", dir);
    }
    let o = cmd.output().map_err(|e| format!("{bin}: {e}\n"))?;
    if o.status.success() {
        return Ok(());
    }
    let log = format!(
        "{}{}",
        String::from_utf8_lossy(&o.stdout),
        String::from_utf8_lossy(&o.stderr)
    );
    let lines: Vec<&str> = log.lines().collect();
    let tail = lines[lines.len().saturating_sub(20)..].join("\n");
    Err(if tail.is_empty() { tail } else { tail + "\n" })
}

fn restore(c: &Ctx, d: &Dirs, snap_settings: &str, snap_claude_json: &str, a: &mut Acc) -> i32 {
    let o = jsonedit::restore(
        &jctx(c),
        &d.settings,
        snap_settings,
        &d.claude_json,
        snap_claude_json,
        NAME,
    );
    a.take(o)
}

/// With CLAUDE_CONFIG_DIR set upstream writes its MCP entry beside that dir; Claude Code reads ~/.claude.json.
fn adopt_staged_mcp(c: &Ctx, d: &Dirs, a: &mut Acc) -> i32 {
    let staged = d.real.join(".claude.json");
    if d.config_dir_override.is_none() || !staged.is_file() {
        return 0;
    }
    let o = jsonedit::adopt_mcp(&jctx(c), &s(&staged), &d.claude_json);
    a.take(o)
}

fn wired(d: &Dirs, a: &mut Acc) -> i32 {
    let o = jsonedit::wired(&d.settings, &d.claude_json, NAME);
    a.take(o)
}

fn restore_and_adopt(c: &Ctx, d: &Dirs, snaps: &(String, String), a: &mut Acc) -> i32 {
    match restore(c, d, &snaps.0, &snaps.1, a) {
        0 => adopt_staged_mcp(c, d, a),
        code => code,
    }
}

pub(super) fn install(c: &Ctx) -> Out {
    let bin = match which_or_die(c, P) {
        Ok(b) => b,
        Err(e) => return e,
    };
    let d = Dirs::new(c);
    let mut a = Acc::default();
    let prepared = snapshot(&d, &mut a).and_then(|snaps| {
        stash_hook_scripts(&d, &mut a)?;
        Ok(snaps)
    });
    let snaps = match prepared {
        Ok(v) => v,
        Err(e) => return (e.0, a.out, e.2),
    };
    if let Err(tail) = run_upstream(&bin, &d, &mut a) {
        a.err.push_str(&tail);
        a.err.push_str(&format!(
            "FAILED   {NAME} install -- restoring from the snapshot anyway\n"
        ));
        let code = restore_and_adopt(c, &d, &snaps, &mut a);
        if code != 0 {
            return a.done(code);
        }
        if wired(&d, &mut a) != 0 {
            return a.done(1);
        }
        // install.sh greps stderr for '^PARTIAL ' to tell this from a clean wiring.
        a.err.push_str(&format!("PARTIAL  {NAME} reported a failure after configuring Claude Code -- hooks and MCP entry are in place\n"));
        return a.done(0);
    }
    a.out.push_str(&format!("CONFIGURED {NAME} install -y\n"));
    let code = restore_and_adopt(c, &d, &snaps, &mut a);
    if code != 0 {
        return a.done(code);
    }
    // Upstream's 5 s hook timeout loses to a big graph; the 8000 ms deadline stays under 10 s.
    let o = jsonedit::ensure_hook_timeout(&d.settings, NAME, 10);
    a.take(o);
    let o = jsonedit::ensure_env(&d.settings, "CBM_HOOK_DEADLINE_MS", "8000");
    a.take(o);
    if wired(&d, &mut a) != 0 {
        a.err.push_str(&die(P, &format!("{NAME} exited 0 but configured no Claude Code hooks or MCP entry -- your own hooks are untouched. Use 'radin hooks all' for the merge-only wiring.")).2);
        return a.done(1);
    }
    a.done(0)
}

pub(super) fn repair(c: &Ctx) -> Out {
    let d = Dirs::new(c);
    let snaps = (
        newest_snapshot(&d, "settings.json"),
        newest_snapshot(&d, "claude.json"),
    );
    if snaps.0.is_empty() && snaps.1.is_empty() {
        return die(
            P,
            &format!(
                "no snapshot in {} -- nothing to repair from",
                d.backups.display()
            ),
        );
    }
    let mut a = Acc::default();
    for snap in [&snaps.0, &snaps.1].into_iter().filter(|p| !p.is_empty()) {
        a.out.push_str(&format!("FROM     {snap}\n"));
    }
    let code = restore_and_adopt(c, &d, &snaps, &mut a);
    if code != 0 {
        return a.done(code);
    }
    wired(&d, &mut a);
    a.done(0)
}

/// Both spellings, since Claude Code matches a Read rule against the path it is asked to read.
fn allow_rules(c: &Ctx) -> Vec<String> {
    let home = c.home.join(".radin");
    let real = if home.is_dir() {
        fs::canonicalize(&home).unwrap_or_else(|_| home.clone())
    } else {
        home.clone()
    };
    let mut v = vec![format!("Read(/{}/**)", home.display())];
    if real != home {
        v.push(format!("Read(/{}/**)", real.display()));
    }
    v
}

fn legacy_allow_rules(c: &Ctx) -> Vec<String> {
    let d = Dirs::new(c);
    let mut v = vec![format!("Read(/{}/.radin/**)", d.claude.display())];
    if d.real != d.claude {
        v.push(format!("Read(/{}/.radin/**)", d.real.display()));
    }
    v
}

fn edit(c: &Ctx, add: bool, rules: &[String]) -> Out {
    let refs: Vec<&str> = rules.iter().map(String::as_str).collect();
    jsonedit::edit_allow(&Dirs::new(c).settings, add, &refs)
}

pub fn allow(c: &Ctx) -> Out {
    edit(c, true, &allow_rules(c))
}

pub fn unallow(c: &Ctx) -> Out {
    edit(c, false, &[allow_rules(c), legacy_allow_rules(c)].concat())
}

pub fn unallow_legacy(c: &Ctx) -> Out {
    edit(c, false, &legacy_allow_rules(c))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Host;
    use std::os::unix::fs::symlink;

    fn with_home<T>(f: impl FnOnce(&Ctx, &Path) -> T) -> T {
        let t = tempfile::tempdir().unwrap();
        let home = t.path().canonicalize().unwrap();
        fs::create_dir_all(home.join(".claude")).unwrap();
        let env = |_: &str| None;
        let cli = |_: &Path, _: &[&str], _: &str| -> Out { panic!("nested call") };
        let c = Ctx {
            cwd: home.clone(),
            home: home.clone(),
            host: Host::Claude,
            stdin: String::new(),
            env: &env,
            cli: &cli,
        };
        f(&c, &home)
    }

    fn settings(h: &Path) -> PathBuf {
        h.join(".claude/settings.json")
    }

    #[test]
    fn allow_adds_once_keeps_foreign_rules_and_writes_through_a_symlink() {
        with_home(|c, h| {
            fs::create_dir_all(h.join("real")).unwrap();
            fs::write(
                h.join("real/settings.json"),
                r#"{"permissions": {"allow": ["Bash(make *)"], "deny": ["Bash(rm *)"]}, "env": {"A": "1"}}"#,
            )
            .unwrap();
            symlink(h.join("real/settings.json"), settings(h)).unwrap();
            assert_eq!(allow(c).0, 0);
            assert_eq!(allow(c).0, 0);
            let t = fs::read_to_string(h.join("real/settings.json")).unwrap();
            assert!(settings(h).is_symlink());
            let rule = format!("Read(/{}/.radin/**)", h.display());
            assert_eq!(t.matches(&rule).count(), 1);
            for kept in ["Bash(make *)", "Bash(rm *)", "\"A\": \"1\""] {
                assert!(t.contains(kept), "{kept}");
            }
        });
    }

    #[test]
    fn allow_writes_a_rule_per_spelling_of_a_symlinked_radin_home() {
        with_home(|c, h| {
            fs::create_dir_all(h.join("rcfg")).unwrap();
            symlink(h.join("rcfg"), h.join(".radin")).unwrap();
            fs::write(
                settings(h),
                r#"{"permissions": {"allow": ["Bash(make *)"]}}"#,
            )
            .unwrap();
            assert_eq!(allow(c).0, 0);
            let t = fs::read_to_string(settings(h)).unwrap();
            assert!(t.contains(&format!("Read(/{}/.radin/**)", h.display())));
            assert!(t.contains(&format!("Read(/{}/rcfg/**)", h.display())));
            assert_eq!(unallow(c).0, 0);
            let t = fs::read_to_string(settings(h)).unwrap();
            assert!(!t.contains(".radin") && !t.contains("rcfg") && t.contains("Bash(make *)"));
        });
    }

    #[test]
    fn unallow_removes_new_legacy_and_duplicate_rules_and_keeps_a_foreign_one() {
        with_home(|c, h| {
            let d = h.display();
            fs::write(
                settings(h),
                format!(
                    r#"{{"permissions": {{"allow": ["Read(//x/**)", "Read(/{d}/.claude/.radin/**)", "Read(/{d}/.radin/**)", "Read(/{d}/.radin/**)"]}}}}"#
                ),
            )
            .unwrap();
            assert_eq!(unallow(c).0, 0);
            let t = fs::read_to_string(settings(h)).unwrap();
            assert!(!t.contains(".radin") && t.contains("Read(//x/**)"));
        });
    }

    #[test]
    fn unallow_legacy_drops_both_claude_spellings_and_keeps_the_new_rule() {
        with_home(|c, h| {
            fs::remove_dir(h.join(".claude")).unwrap();
            fs::create_dir_all(h.join("realclaude")).unwrap();
            symlink(h.join("realclaude"), h.join(".claude")).unwrap();
            let d = h.display();
            fs::write(
                settings(h),
                format!(
                    r#"{{"permissions": {{"allow": ["Read(//x/**)", "Read(/{d}/.claude/.radin/**)", "Read(/{d}/realclaude/.radin/**)", "Read(/{d}/.radin/**)"]}}}}"#
                ),
            )
            .unwrap();
            assert_eq!(unallow_legacy(c).0, 0);
            let t = fs::read_to_string(settings(h)).unwrap();
            assert!(!t.contains("/.claude/.radin") && !t.contains("realclaude/.radin"));
            assert!(t.contains(&format!("Read(/{d}/.radin/**)")) && t.contains("Read(//x/**)"));
        });
    }

    #[test]
    fn allow_refuses_invalid_json_and_leaves_it_alone() {
        with_home(|c, h| {
            fs::write(settings(h), "{bad").unwrap();
            assert_ne!(allow(c).0, 0);
            assert_eq!(fs::read_to_string(settings(h)).unwrap(), "{bad");
        });
    }
}

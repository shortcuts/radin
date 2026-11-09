//! Offline cases run against a fake installed tree and stub CLIs. `real_clis_load_radins_files`
//! (`make verify-hosts`) installs radin for one host at a time and asks that host's own CLI what it sees.
//! `VERIFY_ONLY=opencode|codex` picks one host, `VERIFY_INSTALL_MISSING=1` installs a missing CLI with npm.
mod common;

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

const TOKENS: [&str; 8] = [
    "@@skill:",
    "RADIN_CLI",
    "RADIN_LIB",
    "RADIN_MODEL_",
    "RADIN_EFFORT_",
    "RADIN_AGENT_",
    "<!-- host:",
    "<!-- /host",
];
const KINDS: [&str; 7] = [
    "planning",
    "execution",
    "review",
    "debug",
    "factfind",
    "gate",
    "merge",
];
const SYSTEM_PATH: &str = "/usr/bin:/bin:/usr/sbin:/sbin";

struct Home {
    home: PathBuf,
}

impl Home {
    fn xdg(&self) -> PathBuf {
        self.home.join(".config")
    }
    fn codex(&self) -> PathBuf {
        self.home.join(".codex")
    }
    fn probe(&self, path: &str, cwd: &Path, program: &str, args: &[&str]) -> (bool, String) {
        let mut cmd = Command::new(program);
        cmd.args(args).current_dir(cwd);
        common::isolate(&mut cmd, &self.home);
        cmd.env("PATH", path).stdin(Stdio::null());
        match cmd.output() {
            Ok(o) => (
                o.status.success(),
                format!(
                    "{}{}",
                    String::from_utf8_lossy(&o.stdout),
                    String::from_utf8_lossy(&o.stderr)
                ),
            ),
            Err(e) => (false, e.to_string()),
        }
    }
}

fn skills() -> Vec<&'static str> {
    radin::shipped::shipped().skills
}

fn fail(out: &mut Vec<String>, host: &str, what: &str, detail: &str) {
    let mut line = format!("FAIL {host}: {what}");
    for l in detail.lines().filter(|l| !l.is_empty()) {
        line.push_str(&format!("\n  {l}"));
    }
    out.push(line);
}

fn md_files(p: &Path, found: &mut Vec<PathBuf>) {
    if p.is_dir() {
        let mut es: Vec<_> = fs::read_dir(p)
            .unwrap()
            .map(|e| e.unwrap().path())
            .collect();
        es.sort();
        for e in es {
            md_files(&e, found);
        }
    } else if p.extension().is_some_and(|e| e == "md") {
        found.push(p.to_path_buf());
    }
}

fn check_tokens(out: &mut Vec<String>, host: &str, paths: &[PathBuf]) {
    let mut files = Vec::new();
    for p in paths {
        md_files(p, &mut files);
    }
    let mut hits = String::new();
    for f in files {
        for (i, l) in fs::read_to_string(&f)
            .unwrap_or_default()
            .lines()
            .enumerate()
        {
            if TOKENS.iter().any(|t| l.contains(t)) {
                hits.push_str(&format!("{}:{}:{l}\n", f.display(), i + 1));
            }
        }
    }
    if !hits.is_empty() {
        fail(out, host, "unresolved token", &hits);
    }
}

fn check_skills(out: &mut Vec<String>, h: &Home, host: &str) {
    for s in skills() {
        let f = h.home.join(".agents/skills").join(s).join("SKILL.md");
        let text = fs::read_to_string(&f).unwrap_or_default();
        let ok =
            text.lines().next() == Some("---") && text.lines().any(|l| l == format!("name: {s}"));
        if !ok {
            fail(
                out,
                host,
                &format!("skill {s} missing or malformed"),
                &f.display().to_string(),
            );
        }
    }
}

fn verify_opencode(h: &Home, path: &str, proj: &Path) -> Vec<String> {
    let mut out = Vec::new();
    let (ok, text) = h.probe(path, proj, "opencode", &["debug", "agents", "--standalone"]);
    if !ok {
        fail(&mut out, "opencode", "debug agents exit", &text);
    }
    for k in KINDS {
        if !text.contains(&format!("\"id\": \"radin-{k}\"")) {
            fail(
                &mut out,
                "opencode",
                &format!("agent radin-{k} missing"),
                "",
            );
        }
    }
    let (ok, text) = h.probe(path, proj, "opencode", &["debug", "config", "--standalone"]);
    if !ok {
        fail(&mut out, "opencode", "debug config exit", &text);
    }
    if !text.contains(&format!("{}/.radin/**", h.home.display())) {
        fail(&mut out, "opencode", "external_directory rule missing", "");
    }
    check_skills(&mut out, h, "opencode");
    let oc = h.xdg().join("opencode");
    check_tokens(
        &mut out,
        "opencode",
        &[
            h.home.join(".agents/skills"),
            h.home.join(".radin/hosts/agents"),
            oc.join("agents"),
            oc.join("AGENTS.md"),
        ],
    );
    out
}

fn verify_codex(h: &Home, path: &str, proj: &Path) -> Vec<String> {
    let mut out = Vec::new();
    let (ok, text) = h.probe(path, proj, "codex", &["debug", "prompt-input"]);
    if !ok {
        fail(&mut out, "codex", "debug prompt-input exit", &text);
    }
    for s in skills() {
        if !text.contains(s) {
            fail(&mut out, "codex", &format!("skill {s} not listed"), "");
        }
    }
    if !text.contains("radin:begin") {
        fail(&mut out, "codex", "guidance block missing", "");
    }
    if TOKENS.iter().any(|t| text.contains(t)) {
        fail(&mut out, "codex", "unresolved token in prompt-input", "");
    }
    let radin = h.home.join(".radin/bin/radin");
    let (_, doctor) = h.probe(path, proj, radin.to_str().unwrap(), &["doctor"]);
    if !doctor.contains("OK       Codex lists radin skills") {
        fail(&mut out, "codex", "doctor: Codex skills listing", &doctor);
    }
    check_skills(&mut out, h, "codex");
    check_tokens(
        &mut out,
        "codex",
        &[
            h.home.join(".agents/skills"),
            h.home.join(".radin/hosts/agents"),
            h.codex().join("AGENTS.md"),
        ],
    );
    out
}

fn script(path: &Path, body: &str) {
    fs::write(path, format!("#!/bin/sh\n{body}\n")).unwrap();
    fs::set_permissions(path, fs::Permissions::from_mode(0o755)).unwrap();
}

fn stub_opencode(bin: &Path, kinds: &[&str], config: &str) {
    script(
        &bin.join("opencode"),
        &format!(
            "case \"$2\" in agents) for k in {}; do printf '  \"id\": \"radin-%s\"\\n' \"$k\"; done ;; config) echo '{config}' ;; esac",
            kinds.join(" ")
        ),
    );
}

fn stub_codex(bin: &Path, prompt: &str) {
    script(&bin.join("codex"), &format!("echo \"{prompt}\""));
}

struct Fake {
    _w: tempfile::TempDir,
    h: Home,
    bin: PathBuf,
    proj: PathBuf,
}

impl Fake {
    fn path(&self) -> String {
        format!("{}:{SYSTEM_PATH}", self.bin.display())
    }
    fn opencode(&self) -> Vec<String> {
        verify_opencode(&self.h, &self.path(), &self.proj)
    }
    fn codex(&self) -> Vec<String> {
        verify_codex(&self.h, &self.path(), &self.proj)
    }
}

fn fake() -> Fake {
    let w = tempfile::tempdir().unwrap();
    let root = w.path().canonicalize().unwrap();
    let h = Home {
        home: root.join("home"),
    };
    let (bin, proj) = (root.join("bin"), root.join("proj"));
    let oc = h.xdg().join("opencode");
    for d in [
        &bin,
        &proj,
        &h.home.join(".radin/bin"),
        &h.home.join(".radin/hosts/agents"),
        &oc.join("agents"),
        &h.codex(),
    ] {
        fs::create_dir_all(d).unwrap();
    }
    for s in skills() {
        let d = h.home.join(".agents/skills").join(s);
        fs::create_dir_all(&d).unwrap();
        fs::write(d.join("SKILL.md"), format!("---\nname: {s}\n---\nbody\n")).unwrap();
    }
    for k in KINDS {
        fs::write(
            oc.join(format!("agents/radin-{k}.md")),
            "---\nmode: subagent\n---\n",
        )
        .unwrap();
    }
    let block = "<!-- radin:begin -->\nx\n<!-- radin:end -->\n";
    fs::write(oc.join("AGENTS.md"), block).unwrap();
    fs::write(h.codex().join("AGENTS.md"), block).unwrap();
    script(
        &h.home.join(".radin/bin/radin"),
        "printf '  OK       Codex lists radin skills\\n'",
    );
    stub_opencode(&bin, &KINDS, &format!("{}/.radin/**", h.home.display()));
    stub_codex(&bin, &format!("{} radin:begin", skills().join(" ")));
    Fake {
        _w: w,
        h,
        bin,
        proj,
    }
}

#[test]
fn a_complete_tree_passes_both_hosts() {
    let f = fake();
    assert_eq!(f.opencode(), Vec::<String>::new());
    assert_eq!(f.codex(), Vec::<String>::new());
}

#[test]
fn a_missing_opencode_agent_fails_and_names_it() {
    let f = fake();
    let kinds: Vec<_> = KINDS.iter().copied().filter(|k| *k != "gate").collect();
    stub_opencode(&f.bin, &kinds, &format!("{}/.radin/**", f.h.home.display()));
    assert_eq!(f.opencode(), ["FAIL opencode: agent radin-gate missing"]);
}

#[test]
fn a_missing_external_directory_rule_fails_opencode() {
    let f = fake();
    stub_opencode(&f.bin, &KINDS, "nothing");
    assert_eq!(
        f.opencode(),
        ["FAIL opencode: external_directory rule missing"]
    );
}

#[test]
fn a_skill_missing_from_the_codex_listing_fails_and_names_it() {
    let f = fake();
    let listed: Vec<_> = skills()
        .into_iter()
        .filter(|s| *s != "radin-batch")
        .collect();
    stub_codex(&f.bin, &format!("{} radin:begin", listed.join(" ")));
    assert_eq!(f.codex(), ["FAIL codex: skill radin-batch not listed"]);
}

#[test]
fn an_unresolved_token_in_an_installed_skill_fails() {
    let f = fake();
    let skill = f.h.home.join(".agents/skills/radin-do/SKILL.md");
    let mut text = fs::read_to_string(&skill).unwrap();
    text.push_str("RADIN_CLI\n");
    fs::write(&skill, text).unwrap();
    let got = f.opencode();
    assert_eq!(got.len(), 1);
    assert!(got[0].starts_with("FAIL opencode: unresolved token"));
    assert!(got[0].contains("radin-do/SKILL.md:5:RADIN_CLI"));
}

#[test]
fn no_cli_on_path_fails_each_host() {
    let f = fake();
    fs::remove_file(f.bin.join("opencode")).unwrap();
    fs::remove_file(f.bin.join("codex")).unwrap();
    assert!(f.opencode()[0].starts_with("FAIL opencode: debug agents exit"));
    assert!(f.codex()[0].starts_with("FAIL codex: debug prompt-input exit"));
}

fn which(cli: &str, path: &str) -> Option<PathBuf> {
    path.split(':')
        .map(|d| Path::new(d).join(cli))
        .find(|p| p.is_file())
}

fn ensure_cli(
    work: &Path,
    host: &str,
    cli: &str,
    pkg: &str,
    path: &mut String,
) -> Result<bool, String> {
    if which(cli, path).is_some() {
        return Ok(true);
    }
    if std::env::var("VERIFY_INSTALL_MISSING").as_deref() != Ok("1") {
        println!("SKIP {host}: {cli} not on PATH");
        return Ok(false);
    }
    let o = Command::new("npm")
        .args(["install", "--prefix"])
        .arg(work.join("npm"))
        .args(["--no-audit", "--no-fund", pkg])
        .env("PATH", &*path)
        .output()
        .map_err(|e| format!("FAIL {host}: npm install {pkg}\n  {e}"))?;
    if !o.status.success() {
        return Err(format!(
            "FAIL {host}: npm install {pkg}\n  {}",
            String::from_utf8_lossy(&o.stderr)
        ));
    }
    *path = format!("{}:{path}", work.join("npm/node_modules/.bin").display());
    Ok(true)
}

fn install_host(h: &Home, path: &str, host: &str, proj: &Path) -> Result<(), String> {
    let mut cmd = Command::new(env!("CARGO_BIN_EXE_radin"));
    cmd.args(["install", "--yes", "--only", host])
        .current_dir(proj);
    common::isolate(&mut cmd, &h.home);
    let o = cmd.env("PATH", path).stdin(Stdio::null()).output().unwrap();
    if !o.status.success() {
        return Err(format!(
            "FAIL {host}: install\n  {}{}",
            String::from_utf8_lossy(&o.stdout),
            String::from_utf8_lossy(&o.stderr)
        ));
    }
    let manifest = fs::read_to_string(h.home.join(".radin/manifest.json")).unwrap_or_default();
    let v: serde_json::Value = serde_json::from_str(&manifest).unwrap_or_default();
    if !v["hosts"]
        .as_array()
        .is_some_and(|a| a.iter().any(|x| x == host))
    {
        return Err(format!("FAIL {host}: install (host missing from manifest)"));
    }
    Ok(())
}

#[test]
#[ignore = "drives the real opencode and codex CLIs"]
fn real_clis_load_radins_files() {
    let only = std::env::var("VERIFY_ONLY").unwrap_or_default();
    let hosts: Vec<&str> = match only.as_str() {
        "" => vec!["opencode", "codex"],
        "opencode" => vec!["opencode"],
        "codex" => vec!["codex"],
        other => panic!("unknown VERIFY_ONLY '{other}' (expected opencode|codex)"),
    };
    let work = tempfile::tempdir().unwrap();
    let base_path = std::env::var("PATH").unwrap_or_default();
    let (mut failures, mut ran) = (Vec::new(), 0);
    for host in hosts {
        let pkg = match host {
            "opencode" => format!(
                "@opencode/cli@{}",
                std::env::var("VERIFY_OPENCODE_VERSION").unwrap_or("2.2.5".into())
            ),
            _ => format!(
                "@openai/codex@{}",
                std::env::var("VERIFY_CODEX_VERSION").unwrap_or("0.166.0".into())
            ),
        };
        let mut path = base_path.clone();
        match ensure_cli(work.path(), host, host, &pkg, &mut path) {
            Ok(true) => {}
            Ok(false) => continue,
            Err(e) => {
                ran += 1;
                failures.push(e);
                continue;
            }
        }
        let cli_dir = which(host, &path).unwrap().parent().unwrap().to_path_buf();
        let node_dir = which("node", &path)
            .map(|p| p.parent().unwrap().display().to_string())
            .unwrap_or_default();
        let stubs = work.path().join(host).join("stubs");
        fs::create_dir_all(&stubs).unwrap();
        for c in [
            "curl", "wget", "brew", "mise", "npx", "npm", "gh", "pip", "pipx", "uv",
        ] {
            script(&stubs.join(c), "exit 1");
        }
        let run_path = format!(
            "{}:{}:{node_dir}:{SYSTEM_PATH}",
            stubs.display(),
            cli_dir.display()
        );
        let h = Home {
            home: work.path().join(host).join("home"),
        };
        let proj = work.path().join(host).join("proj");
        fs::create_dir_all(&h.home).unwrap();
        fs::create_dir_all(&proj).unwrap();
        assert!(common::git_in(&proj, &["init", "-q"]).status.success());
        ran += 1;
        if let Err(e) = install_host(&h, &run_path, host, &proj) {
            failures.push(e);
            continue;
        }
        let got = if host == "opencode" {
            verify_opencode(&h, &run_path, &proj)
        } else {
            verify_codex(&h, &run_path, &proj)
        };
        if got.is_empty() {
            println!("OK {host}");
        }
        failures.extend(got);
    }
    assert!(ran > 0, "no host ran");
    assert!(failures.is_empty(), "{}", failures.join("\n"));
}

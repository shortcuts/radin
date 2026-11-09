#[path = "common/cli.rs"]
mod cli;
mod common;

use radin::render::{render, Rules};
use radin::{Ctx, Host, Out};
use std::fs;
use std::path::{Path, PathBuf};

fn fixtures() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/prompt")
}

fn commit(p: &Path, args: &[&str], day: u32) {
    let date = format!("2020-01-0{day}T00:00:00Z");
    let o = std::process::Command::new("git")
        .args(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q"])
        .args(args)
        .env("GIT_AUTHOR_NAME", "t")
        .env("GIT_AUTHOR_EMAIL", "t@t")
        .env("GIT_COMMITTER_NAME", "t")
        .env("GIT_COMMITTER_EMAIL", "t@t")
        .env("GIT_AUTHOR_DATE", &date)
        .env("GIT_COMMITTER_DATE", &date)
        .current_dir(p)
        .output()
        .unwrap();
    assert!(o.status.success(), "{o:?}");
}

struct E {
    _t: tempfile::TempDir,
    home: PathBuf,
    proj: PathBuf,
    ns: PathBuf,
    host: Host,
    base: String,
}

fn render_libs(dir: &Path, host: Host) {
    let rules = Rules::embedded(host.as_str()).unwrap();
    fs::create_dir_all(dir).unwrap();
    let lib = Path::new(env!("CARGO_MANIFEST_DIR")).join("lib");
    for f in fs::read_dir(&lib).unwrap() {
        let p = f.unwrap().path();
        if p.extension().is_some_and(|e| e == "md") {
            let text = fs::read_to_string(&p).unwrap();
            let out = render(&text, &p.display().to_string(), &rules).unwrap();
            fs::write(
                dir.join(p.file_name().unwrap()),
                format!("{}\n", out.trim_end_matches('\n')),
            )
            .unwrap();
        }
    }
}

/// The repo the golden prompts were generated from by the retired bash script, built with the same commits and dates.
fn env(host: Host) -> E {
    let t = tempfile::tempdir().unwrap();
    let root = t.path().canonicalize().unwrap();
    let (home, proj) = (root.join("home"), root.join("proj"));
    render_libs(
        &home.join(format!(".radin/hosts/{}/lib", host.as_str())),
        host,
    );
    fs::create_dir_all(&proj).unwrap();
    cli::git(&proj, &["init", "-q", "-b", "main"]);
    fs::write(proj.join(".gitignore"), ".radin/\n").unwrap();
    cli::git(&proj, &["add", ".gitignore"]);
    commit(&proj, &["--allow-empty", "-m", "init"], 1);
    fs::write(proj.join("a.txt"), "1\n").unwrap();
    cli::git(&proj, &["add", "a.txt"]);
    commit(&proj, &["-m", "add a"], 2);
    let base = cli::git(&proj, &["rev-parse", "HEAD"]).trim().to_string();
    let ns = proj.join(".radin");
    fs::create_dir_all(ns.join("plans")).unwrap();
    fs::create_dir_all(ns.join("state/stash-claims")).unwrap();
    fs::write(ns.join("plans/t-one.head"), &base).unwrap();
    fs::write(ns.join("state/stash-claims/t-one"), "x\n").unwrap();
    fs::write(proj.join("a.txt"), "2\n").unwrap();
    cli::git(&proj, &["add", "a.txt"]);
    commit(&proj, &["-m", "touch a"], 3);
    cli::git(&proj, &["branch", "radin/t-one"]);
    E {
        _t: t,
        home,
        proj,
        ns,
        host,
        base,
    }
}

impl E {
    fn denorm(&self, s: &str) -> String {
        s.replace("@NS@", &self.ns.to_string_lossy())
            .replace("@ROOT@", &self.proj.to_string_lossy())
    }
    fn norm(&self, s: &str) -> String {
        s.replace(&*self.ns.to_string_lossy(), "@NS@")
            .replace(&*self.proj.to_string_lossy(), "@ROOT@")
    }
    fn fixture(&self, name: &str) -> Option<String> {
        fs::read_to_string(fixtures().join("fields").join(name))
            .ok()
            .map(|t| format!("{}\n", self.denorm(&t)))
    }
    fn go_with(&self, args: &[&str], fields: &dyn Fn(&str) -> Option<String>) -> Out {
        let cli = |_: &Path, a: &[&str], _: &str| -> Out {
            assert_eq!(a[..2], ["--host", self.host.as_str()]);
            match (a[2], a[3]) {
                ("backlog", "field") => match fields(a[5]) {
                    Some(v) => (0, v, String::new()),
                    None => (1, String::new(), String::new()),
                },
                ("backlog", "files") => (0, self.fixture("files").unwrap(), String::new()),
                ("state", "gate-map") => (
                    0,
                    "radin/t-one\tabc123def456\t/wt/path\t0123456789ab\n".into(),
                    String::new(),
                ),
                ("state", "leftovers") => {
                    (0, "base\tmain\nbranch\tradin/t-one\n".into(), String::new())
                }
                ("state", "task-dir") => (0, format!("{}\n", self.proj.display()), String::new()),
                _ => (1, String::new(), format!("unexpected {a:?}\n")),
            }
        };
        let h = self.home.to_string_lossy().into_owned();
        let envf = move |k: &str| (k == "HOME").then(|| h.clone());
        let c = Ctx {
            cwd: self.proj.clone(),
            home: self.home.clone(),
            host: self.host,
            stdin: String::new(),
            env: &envf,
            cli: &cli,
        };
        let a: Vec<String> = args.iter().map(|s| s.to_string()).collect();
        radin::prompt::run(&c, &a)
    }
    fn go(&self, args: &[&str]) -> Out {
        self.go_with(args, &|n| self.fixture(n))
    }
    fn prompt_of(&self, out: &Out) -> String {
        assert_eq!(out.0, 0, "{}", out.2);
        let path = out
            .1
            .lines()
            .find_map(|l| l.strip_prefix("prompt\t"))
            .unwrap();
        fs::read_to_string(path).unwrap()
    }
}

fn golden(host: Host) {
    let e = env(host);
    let h = host.as_str();
    let cases: [(&str, &[&str]); 6] = [
        ("planning", &["planning", "t-one"]),
        ("execution", &["execution", "t-one"]),
        ("debug", &["debug", "t-one", "the failure reason"]),
        ("factfind", &["factfind", "t-one", "the question?"]),
        ("gate", &["gate"]),
        ("merge", &["merge", "radin/t-one"]),
    ];
    for (kind, args) in cases {
        let out = e.go(args);
        let got = e.norm(&e.prompt_of(&out));
        let want = fs::read_to_string(fixtures().join(format!("{h}-{kind}.txt"))).unwrap();
        if got != want {
            let (g, w): (Vec<&str>, Vec<&str>) = (got.lines().collect(), want.lines().collect());
            let i = g
                .iter()
                .zip(&w)
                .position(|(a, b)| a != b)
                .unwrap_or(g.len().min(w.len()));
            panic!(
                "{h} {kind} differs from its golden prompt at line {}: got {:?}, want {:?}",
                i + 1,
                g.get(i),
                w.get(i)
            );
        }
    }
}

#[test]
fn claude_prompts_match_the_golden_files() {
    golden(Host::Claude);
}

#[test]
fn agents_prompts_match_the_golden_files() {
    golden(Host::Agents);
}

#[test]
fn the_dispatch_lines_follow_the_host() {
    let e = env(Host::Claude);
    let out = e.go(&["factfind", "t-one", "q"]);
    let keys: Vec<&str> = out
        .1
        .lines()
        .map(|l| l.split('\t').next().unwrap())
        .collect();
    assert_eq!(keys, ["model", "effort", "prompt"]);
    let text = e.prompt_of(&out);
    assert!(text.contains("ToolSearch") && text.contains("Monitor"));
    assert_eq!(
        out.1.lines().last().unwrap(),
        format!("prompt\t{}/state/prompts/t-one-factfind.md", e.ns.display())
    );
    let a = env(Host::Agents);
    let out = a.go(&["factfind", "t-one", "q"]);
    let keys: Vec<&str> = out
        .1
        .lines()
        .map(|l| l.split('\t').next().unwrap())
        .collect();
    assert_eq!(keys, ["prompt"]);
    let text = a.prompt_of(&out);
    for banned in ["<!-- host", "Monitor", "Workflow", "ToolSearch"] {
        assert!(!text.contains(banned), "{banned}");
    }
}

#[test]
fn a_complexity_low_task_runs_on_the_execution_model_on_claude_and_none_on_agents() {
    let low = |e: &E| {
        e.go_with(&["execution", "t-one"], &|n| {
            if n == "COMPLEXITY" {
                Some("low\n".into())
            } else {
                e.fixture(n)
            }
        })
    };
    let e = env(Host::Claude);
    let out = low(&e);
    let default = e.go(&["execution", "t-one"]);
    assert_eq!(out.1, default.1);
    assert!(out.1.starts_with("model\tRADIN_MODEL_EXECUTION\n"));
    let a = env(Host::Agents);
    let out = low(&a);
    assert_eq!(out.0, 0);
    assert_eq!(
        out.1
            .lines()
            .map(|l| l.split('\t').next().unwrap())
            .collect::<Vec<_>>(),
        ["prompt"]
    );
}

#[test]
fn the_installed_layout_falls_back_to_the_flat_lib_directory() {
    let e = env(Host::Claude);
    let hosts = e.home.join(".radin/hosts");
    fs::rename(hosts.join("claude/lib"), e.home.join(".radin/lib")).unwrap();
    fs::remove_dir_all(&hosts).unwrap();
    let out = e.go(&["execution", "t-one"]);
    assert_eq!(out.0, 0, "{}", out.2);
}

#[test]
fn a_claude_template_without_a_model_line_fails() {
    let e = env(Host::Claude);
    let t = e
        .home
        .join(".radin/hosts/claude/lib/radin-prompt-factfind.md");
    let text = fs::read_to_string(&t).unwrap();
    let kept: String = text
        .lines()
        .filter(|l| !l.starts_with("`model: \""))
        .map(|l| format!("{l}\n"))
        .collect();
    fs::write(&t, kept).unwrap();
    let out = e.go(&["factfind", "t-one", "q"]);
    assert_eq!(out.0, 1);
    assert_eq!(
        out.2,
        format!("radin-prompt: no model line in {}\n", t.display())
    );
}

#[test]
fn bad_input_exits_1_with_a_reason() {
    let e = env(Host::Claude);
    let err = |args: &[&str]| {
        let o = e.go(args);
        assert_eq!((o.0, o.1.as_str()), (1, ""), "{args:?}");
        o.2
    };
    assert!(err(&[]).starts_with("radin-prompt: usage: radin prompt"));
    assert!(err(&["planning"]).starts_with("radin-prompt: usage: radin prompt"));
    assert_eq!(
        err(&["bogus", "t-one"]),
        "radin-prompt: unknown prompt kind: bogus\n"
    );
    assert_eq!(
        err(&["debug", "t-one"]),
        "radin-prompt: the debug prompt needs the failure reason as its third argument\n"
    );
    assert_eq!(
        err(&["factfind", "t-one"]),
        "radin-prompt: the factfind prompt needs the question as its third argument\n"
    );
    assert_eq!(err(&["merge"]), "radin-prompt: usage: merge <branch>...\n");
    assert_eq!(
        err(&["merge", "nope"]),
        "radin-prompt: no such branch: nope\n"
    );
    let o = e.go_with(&["planning", "zzz"], &|_| None);
    assert_eq!(o.2, "radin-prompt: no backlog task matches: zzz\n");
    let o = e.go_with(&["planning", "t-one"], &|n| {
        if n == "TASK_BODY" {
            None
        } else {
            e.fixture(n)
        }
    });
    assert!(o
        .2
        .starts_with("radin-prompt: task file is empty or missing: "));
    fs::remove_file(e.home.join(".radin/hosts/claude/lib/radin-prompt-merge.md")).unwrap();
    assert!(err(&["merge", "radin/t-one"]).contains("no template file: "));
}

#[test]
fn a_stale_plan_names_the_commits_that_touched_its_files() {
    let e = env(Host::Claude);
    let text = e.prompt_of(&e.go(&["execution", "t-one"]));
    let short = cli::git(&e.proj, &["log", "-1", "--format=%h", "HEAD"]);
    assert!(
        text.contains(&format!("{} touch a | files: a.txt", short.trim())),
        "{}",
        e.base
    );
}

#[test]
fn an_unresolved_dependency_stops_the_execution_prompt() {
    let e = env(Host::Claude);
    fs::write(e.ns.join("state/BACKLOG_STEPS.json"), "[]\n").unwrap();
    let o = e.go(&["execution", "t-one"]);
    assert_eq!(o.0, 1);
    assert!(
        o.2.starts_with("radin-prompt: dependency of t-one is unresolved"),
        "{}",
        o.2
    );
}

#[test]
fn earlier_plans_reach_only_a_planning_prompt_that_names_them() {
    let e = env(Host::Claude);
    let alone = e.prompt_of(&e.go(&["planning", "t-one"]));
    assert!(!alone.contains("deferred"), "{alone}");
    let after = e.prompt_of(&e.go(&["planning", "t-one", "t-two"]));
    assert!(after.contains("deferred"), "{after}");
    assert!(
        after.contains(&format!("{}/plans/t-one.md", e.ns.display())),
        "{after}"
    );
}

#![allow(dead_code)]
use std::cell::{Cell, RefCell};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::OnceLock;

pub fn isolate(cmd: &mut Command, home: &Path) {
    cmd.env("HOME", home)
        .env("XDG_CONFIG_HOME", home.join(".config"))
        .env("CODEX_HOME", home.join(".codex"))
        .env("RADIN_DETAILS", "1")
        .env_remove("OPENCODE_CONFIG")
        .env_remove("CLAUDE_CONFIG_DIR")
        .env_remove("OPENCODE");
}

pub struct Run {
    pub code: i32,
    pub out: String,
    pub err: String,
}

impl Run {
    pub fn all(&self) -> String {
        format!("{}{}", self.out, self.err)
    }
}

pub fn git_in(dir: &Path, args: &[&str]) -> std::process::Output {
    Command::new("git")
        .args(["-c", "user.name=t", "-c", "user.email=t@t"])
        .args(args)
        .current_dir(dir)
        .output()
        .unwrap()
}

/// A repo with one empty commit, a backlog entry `t-one` and an untracked .gitignore holding `.radin/`, built once per test binary.
fn seed() -> &'static PathBuf {
    static SEED: OnceLock<PathBuf> = OnceLock::new();
    SEED.get_or_init(|| {
        let dir =
            Path::new(env!("CARGO_TARGET_TMPDIR")).join(format!("seed-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        let proj = dir.join("proj");
        fs::create_dir_all(&proj).unwrap();
        for args in [
            &["init", "-q"][..],
            &["config", "user.email", "t@t"],
            &["config", "user.name", "t"],
            &["commit", "-q", "--allow-empty", "-m", "init"],
        ] {
            assert!(git_in(&proj, args).status.success());
        }
        fs::write(proj.join(".gitignore"), ".radin/\n").unwrap();
        let w = W::at(proj.clone(), dir.clone());
        assert_eq!(w.bl(&["add", "fix", "t one"], "body\n").code, 0);
        proj
    })
}

pub struct W {
    _t: Option<tempfile::TempDir>,
    pub work: PathBuf,
    pub p: PathBuf,
    pub home: PathBuf,
    pub tele: RefCell<Vec<String>>,
    pub tele_fail: Cell<bool>,
    pub cap: Cell<Option<&'static str>>,
    pub hash: RefCell<String>,
}

impl W {
    fn at(p: PathBuf, work: PathBuf) -> W {
        let home = work.join("home");
        W {
            _t: None,
            work,
            p,
            home,
            tele: RefCell::new(vec![]),
            tele_fail: Cell::new(false),
            cap: Cell::new(Some("4")),
            hash: RefCell::new(String::new()),
        }
    }

    pub fn new() -> W {
        let t = tempfile::tempdir().unwrap();
        let work = t.path().canonicalize().unwrap();
        let p = work.join("proj");
        assert!(Command::new("cp")
            .arg("-a")
            .arg(seed())
            .arg(&p)
            .status()
            .unwrap()
            .success());
        let mut w = W::at(p, work);
        w._t = Some(t);
        w
    }

    pub fn run_in(&self, dir: &Path, cmd: &[&str], stdin: &str, cap: Option<&str>) -> Run {
        let home = self.home.to_string_lossy().into_owned();
        let cap = cap.map(String::from);
        let env = move |k: &str| match k {
            "HOME" => Some(home.clone()),
            "RADIN_WAVE_CAP" => cap.clone(),
            _ => None,
        };
        let cli = |d: &Path, a: &[&str], input: &str| -> radin::Out {
            match a[0] {
                "telemetry" if self.tele_fail.get() => {
                    (127, String::new(), "telemetry: not found\n".into())
                }
                "telemetry" => {
                    self.tele.borrow_mut().push(a[3..].join(" "));
                    (0, String::new(), String::new())
                }
                "prompt" => (0, format!("PROMPT {} {}\n", a[1], a[2]), String::new()),
                _ => {
                    let v: Vec<String> = a.iter().map(|s| s.to_string()).collect();
                    radin::run_in(&v, &env, false, d, Some(input))
                }
            }
        };
        let ctx = radin::state::Ctx {
            cwd: dir.to_path_buf(),
            home: self.home.clone(),
            stdin: stdin.to_string(),
            env: &env,
            cli: &cli,
        };
        let a: Vec<String> = cmd.iter().map(|s| s.to_string()).collect();
        let (code, out, err) = radin::state::run(&ctx, &a);
        Run { code, out, err }
    }

    pub fn state(&self, args: &[&str]) -> Run {
        self.run_in(&self.p, args, "", self.cap.get())
    }

    pub fn state_in(&self, args: &[&str], stdin: &str) -> Run {
        self.run_in(&self.p, args, stdin, self.cap.get())
    }

    pub fn state_cap(&self, args: &[&str], stdin: &str, cap: Option<&str>) -> Run {
        self.run_in(&self.p, args, stdin, cap)
    }

    pub fn bl(&self, args: &[&str], stdin: &str) -> Run {
        let home = self.home.to_string_lossy().into_owned();
        let env = move |k: &str| (k == "HOME").then(|| home.clone());
        let mut v = vec!["backlog".to_string()];
        v.extend(args.iter().map(|s| s.to_string()));
        let (code, out, err) = radin::run_in(&v, &env, false, &self.p, Some(stdin));
        Run { code, out, err }
    }

    pub fn git(&self, args: &[&str]) -> String {
        self.git_at(&self.p, args)
    }

    pub fn git_at(&self, dir: &Path, args: &[&str]) -> String {
        let o = git_in(dir, args);
        assert!(
            o.status.success(),
            "git {args:?}: {}",
            String::from_utf8_lossy(&o.stderr)
        );
        String::from_utf8_lossy(&o.stdout).trim_end().to_string()
    }

    pub fn git_ok(&self, args: &[&str]) -> bool {
        git_in(&self.p, args).status.success()
    }

    /// Commits the seed's untracked .gitignore so the tree reads clean.
    pub fn clean(&self) {
        self.git(&["add", ".gitignore"]);
        self.git(&["commit", "-q", "-m", "ignore"]);
    }

    pub fn base(&self) -> String {
        self.git(&["branch", "--show-current"])
    }

    pub fn write(&self, rel: &str, text: &str) {
        let f = self.p.join(rel);
        fs::create_dir_all(f.parent().unwrap()).unwrap();
        fs::write(f, text).unwrap();
    }

    pub fn read(&self, rel: &str) -> String {
        fs::read_to_string(self.p.join(rel)).unwrap_or_default()
    }

    pub fn exists(&self, rel: &str) -> bool {
        self.p.join(rel).exists()
    }

    pub fn task_file(&self, id: &str) -> String {
        self.bl(&["field", id, "TASK_FILE"], "")
            .out
            .trim()
            .to_string()
    }

    pub fn run_id(&self) -> String {
        let b = self.read(".radin/state/baseline.json");
        b.split("\"run_id\":\"")
            .nth(1)
            .unwrap()
            .split('"')
            .next()
            .unwrap()
            .into()
    }

    pub fn steps_init(&self, rows: &str) {
        assert_eq!(self.state_in(&["steps-init"], rows).code, 0);
    }

    pub fn plan_with(&self, paths: &[&str]) {
        let items: String = paths.iter().map(|x| format!("- `{x}` — x\n")).collect();
        self.write(
            ".radin/plans/t-one.md",
            &format!("# Plan\n\n## Changes\n\n{items}\n## Testing\n\n- [ ] x\n"),
        );
        let plan = self.p.join(".radin/plans/t-one.md");
        assert_eq!(
            self.bl(&["set-meta", "t-one", "plan", plan.to_str().unwrap()], "")
                .code,
            0
        );
        self.steps_init("t-one\t1\t\tpending\n");
    }

    pub fn commit_files(&self, files: &[&str]) {
        git_in(&self.p, &["add", ".gitignore"]);
        git_in(&self.p, &["commit", "-q", "-m", "ignore"]);
        for f in files {
            self.write(f, "x\n");
        }
        let mut add = vec!["add", "--"];
        add.extend(files);
        self.git(&add);
        self.git(&["commit", "-q", "-m", "c"]);
        *self.hash.borrow_mut() = self.git(&["rev-parse", "--short=12", "HEAD"]);
    }

    pub fn report_success(&self) -> Run {
        let h = self.hash.borrow().clone();
        self.state(&[
            "task-report",
            "t-one",
            &format!("STATUS: SUCCESS — {h}; built: x; checks: test=pass, lint=pass, review=pass"),
        ])
    }

    /// The first miss gets a debug pass; the second prints the failure reason.
    pub fn report_failed(&self) -> Run {
        self.report_success();
        self.report_success()
    }

    /// Adds a task whose plan lists `paths` under ## Changes.
    pub fn planned(&self, title: &str, paths: &[&str]) {
        assert_eq!(self.bl(&["add", "fix", title], "body\n").code, 0);
        if paths.is_empty() {
            return;
        }
        let items: String = paths.iter().map(|p| format!("- `{p}` — edit\n")).collect();
        let f = self.work.join(format!("{}.md", title.replace(' ', "-")));
        fs::write(&f, format!("## Changes\n\n{items}")).unwrap();
        assert_eq!(
            self.bl(&["set-meta", title, "plan", f.to_str().unwrap()], "")
                .code,
            0
        );
    }

    /// t-one done on radin/t-one (unmerged); t-two depends on it. Both write shared.txt.
    pub fn stack_setup(&self) -> String {
        let base = self.base();
        assert_eq!(
            self.bl(&["add", "fix", "t two", "--deps", "t-one"], "body\n")
                .code,
            0
        );
        self.write("shared.txt", "one\n");
        self.git(&["add", "shared.txt"]);
        self.git(&["commit", "-q", "-m", "add shared"]);
        self.git(&["checkout", "-q", "-b", "radin/t-one"]);
        self.write("shared.txt", "one\nfrom-one\n");
        self.git(&["commit", "-qam", "feat: t-one"]);
        self.git(&["checkout", "-q", &base]);
        let tip = self.git(&["rev-parse", "--short=12", "radin/t-one"]);
        self.write(".radin/state/unmerged/t-one", &format!("{tip}\n"));
        self.steps_init("t-one\t1\t\tpending\nt-two\t2\tt-one\tpending\n");
        assert_eq!(self.state(&["session-set", "yes", "no"]).code, 0);
        assert_eq!(self.state(&["group-set", "t-one", "t-two"]).code, 0);
        base
    }

    /// The last line `prepare` printed.
    pub fn prep_dir(&self, id: &str) -> String {
        self.state(&["prepare", id])
            .out
            .lines()
            .last()
            .unwrap_or("")
            .to_string()
    }

    pub fn wave_wp(&self, extra: &[&str]) -> Run {
        let wave = self.state(&["wave"]);
        let mut a = vec!["wave-partition"];
        a.extend(extra);
        self.state_in(&a, &wave.out)
    }
}

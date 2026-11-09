mod branches;
mod done;
mod git;
mod land;
mod leftover;
mod plan_cover;
mod queue;
mod report;
mod store;
mod task_report;

use crate::backlog::{Fail, Io, R};
use crate::manifest::Manifest;
use crate::paths::Namespace;
use crate::Out;
use std::path::{Path, PathBuf};

pub struct Ctx<'a> {
    pub cwd: PathBuf,
    pub home: PathBuf,
    pub stdin: String,
    pub env: &'a dyn Fn(&str) -> Option<String>,
    /// Runs another radin subcommand in `dir` with `stdin`: the seam to backlog, telemetry and prompt.
    pub cli: &'a dyn Fn(&Path, &[&str], &str) -> Out,
}

pub struct S<'a> {
    pub c: &'a Ctx<'a>,
    pub root: PathBuf,
    pub ns: PathBuf,
    pub state: PathBuf,
    pub steps: PathBuf,
    pub completed: PathBuf,
}

const HELP: &str = include_str!("help.txt");

const VERBS: &str = "teardown|steps-init|steps-list|wave|wave-partition|plan-discard|steps-open|steps-waiting|answered|retry|task-next|task-report|task-fact|task-diagnosis|task-done|set-status|stuck|preflight|resume|recover|recover-reject|report|session-set|session-get|group-set|prepare|dirty-check|trace|completed-show|completed-list|unlanded|session-commits|gate-map|leftovers|stash-triage|stash-claim|reconcile|gate-fix|gate-filed|gate-done|deps-check|task-dir|journal-tail|plan-covers|review-findings|finding-classes";

const ID_VERBS: &[&str] = &[
    "task-next",
    "task-report",
    "task-fact",
    "task-diagnosis",
    "task-done",
    "set-status",
    "answered",
    "retry",
    "recover",
    "recover-reject",
    "plan-discard",
    "prepare",
    "trace",
    "completed-show",
    "deps-check",
    "task-dir",
    "gate-filed",
];

fn verb_usage(verb: &str) -> String {
    HELP.lines()
        .filter(|l| l.split_whitespace().next() == Some(verb))
        .map(|l| format!("{}\n", l.trim_start()))
        .collect()
}

pub fn die(m: impl AsRef<str>) -> Fail {
    Fail {
        code: 1,
        msg: format!("radin-state: {}\n", m.as_ref()),
    }
}

pub fn mkdir(s: &S, rel: &str) {
    let _ = std::fs::create_dir_all(s.state.join(rel));
}

pub fn write(s: &S, rel: &str, text: &str) {
    let _ = std::fs::write(s.state.join(rel), text);
}

pub fn positive(s: &str) -> bool {
    !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit()) && !s.starts_with('0')
}

pub fn arg(a: &[String], i: usize) -> &str {
    a.get(i).map_or("", String::as_str)
}

impl<'a> S<'a> {
    pub fn new(c: &'a Ctx<'a>) -> S<'a> {
        let n = Namespace::locate(&c.cwd);
        let _ = n.ensure_dirs();
        S {
            c,
            state: n.namespace_dir.join("state"),
            steps: n.namespace_dir.join("state/BACKLOG_STEPS.json"),
            completed: n.namespace_dir.join("state/completed.json"),
            ns: n.namespace_dir,
            root: n.repo_root,
        }
    }

    pub fn bl(&self, args: &[&str], stdin: &str) -> Out {
        let mut v = vec!["backlog"];
        v.extend_from_slice(args);
        (self.c.cli)(&self.root, &v, stdin)
    }

    /// Stdout of a backlog call that exited 0.
    pub fn bl_ok(&self, args: &[&str]) -> Option<String> {
        let (code, out, _) = self.bl(args, "");
        (code == 0).then_some(out)
    }

    /// A backlog call whose failure ends the verb, as `set -e` did.
    pub fn bl_must(&self, args: &[&str], stdin: &str) -> Result<String, Fail> {
        let (code, out, err) = self.bl(args, stdin);
        if code == 0 {
            Ok(out)
        } else {
            Err(Fail { code, msg: err })
        }
    }

    pub fn field(&self, id: &str, name: &str) -> Result<String, String> {
        let (code, out, err) = self.bl(&["field", id, name], "");
        if code == 0 {
            Ok(out.trim_end_matches('\n').to_string())
        } else {
            Err(err)
        }
    }

    /// The backlog `find` row of exactly this id, split on TAB.
    pub fn find_row(&self, id: &str) -> Option<Vec<String>> {
        let out = self.bl_ok(&["find", id])?;
        out.lines()
            .map(|l| l.split('\t').map(String::from).collect::<Vec<_>>())
            .find(|f| f[0] == id)
    }

    pub fn find_deps(&self, id: &str) -> String {
        self.find_row(id)
            .and_then(|f| f.get(5).cloned())
            .unwrap_or_default()
    }

    pub fn task_title(&self, id: &str) -> String {
        self.bl_ok(&["find", id])
            .and_then(|o| {
                o.lines()
                    .next()
                    .map(|l| l.split('\t').nth(2).unwrap_or("").to_string())
            })
            .unwrap_or_default()
    }

    pub fn task_plans(&self, id: &str) -> String {
        let meta = self.bl_ok(&["meta", id]).unwrap_or_default();
        meta.lines()
            .filter_map(|l| l.strip_prefix("plan\t"))
            .collect::<Vec<_>>()
            .join(",")
    }

    pub fn plan_files(&self, id: &str) -> Vec<String> {
        self.bl_ok(&["files", id])
            .map(|o| o.lines().map(String::from).collect())
            .unwrap_or_default()
    }

    pub fn entry_note(&self, id: &str, text: &str) {
        self.bl(&["append", id], &format!("**Progress:** {text}\n"));
    }

    pub fn telemetry(&self, kind: &str, kv: &[String]) {
        let mut v = vec!["telemetry", "record", "parallel", kind];
        v.extend(kv.iter().map(String::as_str));
        (self.c.cli)(&self.root, &v, "");
    }

    pub fn wave_cap(&self) -> Result<u64, Fail> {
        let cap = (self.c.env)("RADIN_WAVE_CAP")
            .filter(|v| !v.is_empty())
            .or_else(|| {
                Manifest::read(&self.c.home.join(".radin/manifest.json"))
                    .ok()
                    .flatten()
                    .map(|m| m.wave_cap.to_string())
            })
            .unwrap_or_else(|| "2".into());
        if !positive(&cap) {
            return Err(die(format!(
                "wave cap needs a positive integer, got: {cap}"
            )));
        }
        Ok(cap.parse().unwrap_or(2))
    }

    pub fn prepared_field(&self, id: &str, key: &str) -> String {
        match std::fs::read_to_string(self.state.join(format!("prepared/{id}.json"))) {
            Ok(t) if !t.is_empty() => store::get(&t, key),
            _ => String::new(),
        }
    }

    pub fn session_get(&self) -> Option<(String, String)> {
        let t = std::fs::read_to_string(self.state.join("session.json")).ok()?;
        (!t.is_empty()).then(|| (store::get(&t, "worktree"), store::get(&t, "branch")))
    }

    pub fn rm(&self, rel: &str) {
        let _ = std::fs::remove_file(self.state.join(rel));
    }

    pub fn exists(&self, rel: &str) -> bool {
        self.state.join(rel).exists()
    }

    pub fn touch(&self, rel: &str) {
        let _ = std::fs::write(self.state.join(rel), "");
    }

    pub fn read(&self, rel: &str) -> String {
        std::fs::read_to_string(self.state.join(rel)).unwrap_or_default()
    }

    /// Regular files of a state subdirectory, sorted by name.
    pub fn files_in(&self, rel: &str) -> Vec<(String, PathBuf)> {
        let mut v: Vec<(String, PathBuf)> = std::fs::read_dir(self.state.join(rel))
            .into_iter()
            .flatten()
            .flatten()
            .filter(|e| e.path().is_file())
            .map(|e| (e.file_name().to_string_lossy().into_owned(), e.path()))
            .collect();
        v.sort();
        v
    }

    pub fn journal_lines(&self) -> Vec<String> {
        store::read_lines(&self.state.join("journal.jsonl"))
    }
}

pub fn run(c: &Ctx, args: &[String]) -> Out {
    let mut io = Io::default();
    let code = match dispatch(c, args, &mut io) {
        Ok(code) => code,
        Err(e) => {
            io.err.push_str(&e.msg);
            e.code
        }
    };
    (code, io.out, io.err)
}

fn dispatch(c: &Ctx, args: &[String], io: &mut Io) -> R {
    let verb = arg(args, 0);
    let a = args.get(1..).unwrap_or(&[]);
    if matches!(verb, "help" | "--help" | "-h") {
        io.out.push_str(HELP);
        return Ok(0);
    }
    if verb != "wave-cap" && !VERBS.split('|').any(|v| v == verb) {
        return Err(die(format!(
            "unknown command: {} ({VERBS})",
            if verb.is_empty() { "<none>" } else { verb }
        )));
    }
    if ID_VERBS.contains(&verb) && arg(a, 0).starts_with('-') {
        return match arg(a, 0) {
            "--help" | "-h" => {
                io.out.push_str(&verb_usage(verb));
                Ok(0)
            }
            _ => Err(die(format!("usage: {}", verb_usage(verb).trim_end()))),
        };
    }
    let s = S::new(c);
    match verb {
        "steps-init" => queue::steps_init(&s, io),
        "steps-list" => queue::steps_list(&s, io),
        "steps-open" => queue::steps_open(&s, io),
        "steps-waiting" => queue::steps_waiting(&s, io),
        "stuck" => queue::stuck(&s, io),
        "preflight" => queue::preflight(&s, io),
        "resume" => queue::resume(&s, io),
        "answered" => queue::answered(&s, a),
        "retry" => queue::retry(&s, a),
        "set-status" => queue::set_status(&s, a),
        "wave-cap" => queue::wave_cap(&s, io),
        "wave" => queue::wave(&s, io),
        "wave-partition" => queue::wave_partition(&s, a, io),
        "deps-check" => queue::deps_check_verb(&s, a, io),
        "teardown" => queue::teardown(&s),
        "task-next" => done::task_next(&s, arg(a, 0), io),
        "task-report" => task_report::task_report(&s, a, io),
        "task-fact" => done::task_fact(&s, a, io),
        "task-diagnosis" => done::task_diagnosis(&s, a, io),
        "task-done" => done::task_done(&s, arg(a, 0), arg(a, 1), io),
        "recover" => done::recover(&s, a, io),
        "recover-reject" => done::recover_reject(&s, a, io),
        "plan-discard" => done::plan_discard(&s, a, io),
        "prepare" => land::prepare(&s, a, io),
        "reconcile" => land::reconcile(&s, io),
        "leftovers" => branches::leftovers(&s, io),
        "stash-triage" => branches::stash_triage(&s, io),
        "stash-claim" => branches::stash_claim(&s, a),
        "unlanded" => branches::unlanded(&s, io),
        "gate-fix" => branches::gate_fix(&s, a),
        "gate-filed" => branches::gate_filed(&s, a),
        "gate-done" => branches::gate_done(&s),
        "gate-map" => branches::gate_map(&s, io),
        "session-commits" => branches::session_commits_verb(&s, io),
        "session-set" => branches::session_set(&s, a),
        "session-get" => branches::session_get(&s, io),
        "group-set" => branches::group_set(&s, a),
        "task-dir" => branches::task_dir_verb(&s, a, io),
        "dirty-check" => branches::dirty_check(&s, io),
        "trace" => branches::trace(&s, a, io),
        "completed-show" => branches::completed_show(&s, a, io),
        "completed-list" => branches::completed_list(&s, io),
        "report" => report::report(&s, io),
        "journal-tail" => report::journal_tail(&s, a, io),
        "plan-covers" => report::plan_covers(&s, a, io),
        "review-findings" => report::review_findings(&s, io),
        "finding-classes" => report::finding_classes(&s, a, io),
        _ => unreachable!("verb list and dispatch agree"),
    }
}

mod branches;
mod done;
mod gate;
mod git;
mod land;
mod lanes;
mod lanes_recover;
mod leftover;
mod mergeq;
mod park;
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

const VERBS: &str = "teardown|steps-init|steps-list|steps-open|steps-waiting|answered|retry|task-next|task-report|task-fact|task-diagnosis|task-done|base-failing|set-status|stuck|preflight|resume|recover|recover-reject|report|session-set|session-get|prepare|dirty-check|trace|completed-show|completed-list|unlanded|session-commits|gate-map|leftovers|stash-triage|stash-claim|reconcile|gate-fix|gate-filed|gate-done|deps-check|task-dir|journal-tail|plan-covers|review-findings|finding-classes|pattern-seen|lane-cap|lanes-init|lane-next|lane-done|lane-judge|lanes-show|lanes-view|lane-sync|lane-queue|lane-merge|lane-gate|lanes-recover";

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
    "prepare",
    "trace",
    "completed-show",
    "deps-check",
    "task-dir",
    "gate-filed",
    "lane-sync",
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
        let run = self.run_id();
        let run_kv = format!("run={run}");
        if !run.is_empty() {
            v.push(&run_kv);
        }
        (self.c.cli)(&self.root, &v, "");
    }

    pub fn lane_cap(&self) -> Result<u64, Fail> {
        let cap = (self.c.env)("RADIN_LANE_CAP")
            .filter(|v| !v.is_empty())
            .or_else(|| {
                Manifest::read(&self.c.home.join(".radin/manifest.json"))
                    .ok()
                    .flatten()
                    .map(|m| m.lane_cap.to_string())
            })
            .unwrap_or_else(|| "2".into());
        if !positive(&cap) {
            return Err(die(format!(
                "lane cap needs a positive integer, got: {cap}"
            )));
        }
        Ok(cap.parse().unwrap_or(2))
    }

    pub fn task_lane(&self, id: &str) -> String {
        if self.lane_mode() == "lanes" {
            lanes::task_epic(self, id).unwrap_or_default()
        } else {
            String::new()
        }
    }

    /// `radin/<lane>`, else a leftover `radin/<id>` branch, else empty (callers use `HEAD`).
    pub fn task_branch(&self, id: &str) -> String {
        let lane = self.task_lane(id);
        let legacy = format!("radin/{id}");
        if !lane.is_empty() {
            format!("radin/{lane}")
        } else if self.branch_exists(&legacy) {
            legacy
        } else {
            String::new()
        }
    }

    pub fn task_worktree(&self, id: &str) -> String {
        let lane = self.task_lane(id);
        let dir = self.lane_dir_path(&lane);
        if !lane.is_empty() && dir.is_dir() {
            dir.to_string_lossy().into_owned()
        } else {
            String::new()
        }
    }

    /// The switch defaults on: only an explicit `"parallel":false` turns it off.
    pub fn session_parallel(&self) -> bool {
        !self.read("session.json").contains("\"parallel\":false")
    }

    pub fn lane_mode(&self) -> String {
        match self.read("lane-mode").trim() {
            "lanes" => "lanes".into(),
            _ => "main".into(),
        }
    }

    pub fn rm(&self, rel: &str) {
        let _ = std::fs::remove_file(self.state.join(rel));
    }

    /// Writes a landing marker or run flag and journals the transition.
    pub fn set_marker(&self, id: &str, rel: &str, text: &str) {
        if let Some(dir) = Path::new(rel).parent() {
            mkdir(self, &dir.to_string_lossy());
        }
        write(self, rel, text);
        self.journal("marker-set", id, &format!("{rel} {}", text.trim()));
    }

    /// Removes a marker and journals it only when the file existed.
    pub fn clear_marker(&self, id: &str, rel: &str) {
        if self.exists(rel) {
            self.rm(rel);
            self.journal("marker-clear", id, rel);
        }
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
    if !VERBS.split('|').any(|v| v == verb) {
        return Err(die(format!(
            "unknown command: {} ({VERBS})",
            if verb.is_empty() { "<none>" } else { verb }
        )));
    }
    let lane_flag = verb == "task-next" && arg(a, 0) == "--lane";
    if ID_VERBS.contains(&verb) && arg(a, 0).starts_with('-') && !lane_flag {
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
        "lane-cap" => queue::lane_cap(&s, io),
        "lanes-init" => lanes::lanes_init(&s, io),
        "lane-next" => lanes::lane_next(&s, a, io),
        "lane-done" => lanes::lane_done(&s, a, io),
        "lane-judge" => lanes::lane_judge(&s, a, io),
        "lane-queue" => mergeq::lane_queue(&s, a, io),
        "lane-merge" => mergeq::lane_merge(&s, a, io),
        "lane-gate" => gate::lane_gate(&s, a, io),
        "lanes-recover" => lanes_recover::lanes_recover(&s, io),
        "lanes-show" => lanes::lanes_show(&s, io),
        "lanes-view" => lanes::lanes_view(&s, io),
        "lane-sync" => park::lane_sync(&s, a, io),
        "deps-check" => queue::deps_check_verb(&s, a, io),
        "teardown" => queue::teardown(&s),
        "task-next" if lane_flag => match a {
            [_, epic] => done::task_next(&s, "", Some(epic), io),
            _ => Err(die(format!("usage: {}", verb_usage(verb).trim_end()))),
        },
        "task-next" => done::task_next(&s, arg(a, 0), None, io),
        "task-report" => task_report::task_report(&s, a, io),
        "task-fact" => done::task_fact(&s, a, io),
        "task-diagnosis" => done::task_diagnosis(&s, a, io),
        "task-done" => done::task_done(&s, arg(a, 0), arg(a, 1), io),
        "base-failing" => done::base_failing(&s, a, io),
        "recover" => done::recover(&s, a, io),
        "recover-reject" => done::recover_reject(&s, a, io),
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
        "task-dir" => branches::task_dir_verb(&s, a, io),
        "dirty-check" => branches::dirty_check(&s, io),
        "trace" => branches::trace(&s, a, io),
        "completed-show" => branches::completed_show(&s, a, io),
        "completed-list" => branches::completed_list(&s, a, io),
        "report" => report::report(&s, a, io),
        "journal-tail" => report::journal_tail(&s, a, io),
        "plan-covers" => report::plan_covers(&s, a, io),
        "review-findings" => report::review_findings(&s, io),
        "finding-classes" => report::finding_classes(&s, a, io),
        "pattern-seen" => report::pattern_seen(&s, a, io),
        _ => unreachable!("verb list and dispatch agree"),
    }
}

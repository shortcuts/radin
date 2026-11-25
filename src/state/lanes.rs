use super::git::ok;
use super::land::drop_branch;
use super::park::{conflicted, merge_in_progress};
use super::store::{deps_csv, get, num, read_lines};
use super::{arg, die, mkdir, write, S};
use crate::backlog::{Fail, Io, R};
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::fmt::Write;

pub(super) const FALLBACK_EPIC: &str = "maintenance";

pub struct Task {
    pub id: String,
    pub epic: String,
    pub order: u64,
    pub status: String,
    pub deps: Vec<String>,
}

/// Epic -> the epics it waits for, reduced to epics that are in the run.
type Deps = BTreeMap<String, BTreeSet<String>>;

fn epics_of(tasks: &[Task]) -> BTreeSet<String> {
    tasks.iter().map(|t| t.epic.clone()).collect()
}

/// Edges come from `epic-set-deps` and from any single task dependency between two run epics.
fn epic_deps(tasks: &[Task], declared: &[(String, String)]) -> Deps {
    let run = epics_of(tasks);
    let mut d: Deps = run.iter().map(|e| (e.clone(), BTreeSet::new())).collect();
    let mut add = |b: &str, a: &str| {
        if a != b && run.contains(a) && run.contains(b) {
            d.entry(b.to_string()).or_default().insert(a.to_string());
        }
    };
    for (b, a) in declared {
        add(b, a);
    }
    let epic_of: HashMap<&str, &str> = tasks
        .iter()
        .map(|t| (t.id.as_str(), t.epic.as_str()))
        .collect();
    for t in tasks {
        for dep in &t.deps {
            if let Some(a) = epic_of.get(dep.as_str()) {
                add(&t.epic, a);
            }
        }
    }
    d
}

fn reaches(d: &Deps, from: &str, to: &str) -> bool {
    let (mut seen, mut stack) = (BTreeSet::new(), vec![from.to_string()]);
    while let Some(e) = stack.pop() {
        for n in d.get(&e).into_iter().flatten() {
            if n == to {
                return true;
            }
            if seen.insert(n.clone()) {
                stack.push(n.clone());
            }
        }
    }
    false
}

/// The shortest chain of epic waits that returns to its start, as a message naming each edge's cause.
fn cycle_message(tasks: &[Task], d: &Deps) -> Option<String> {
    let start = d.keys().find(|e| reaches(d, e, e))?;
    let mut parent: BTreeMap<&str, &str> = BTreeMap::new();
    let mut queue = std::collections::VecDeque::from([start.as_str()]);
    let last = 'bfs: loop {
        let e = queue.pop_front()?;
        for n in &d[e] {
            if n == start {
                break 'bfs e;
            }
            if parent.insert(n, e).is_none() {
                queue.push_back(n);
            }
        }
    };
    let mut chain = vec![last];
    while let Some(p) = parent.get(chain[chain.len() - 1]) {
        chain.push(p);
    }
    chain.reverse();
    let epic_of: HashMap<&str, &str> = tasks
        .iter()
        .map(|t| (t.id.as_str(), t.epic.as_str()))
        .collect();
    let mut edges = Vec::new();
    for (i, waiter) in chain.iter().enumerate() {
        let target = chain.get(i + 1).copied().unwrap_or(start.as_str());
        let cause = tasks
            .iter()
            .filter(|t| t.epic == *waiter)
            .flat_map(|t| t.deps.iter().map(move |dep| (t, dep)))
            .find(|(_, dep)| epic_of.get(dep.as_str()) == Some(&target))
            .map_or("declared by epic-set-deps".to_string(), |(t, dep)| {
                format!("task {} depends on {dep}", t.id)
            });
        edges.push(format!("{waiter} waits for {target} ({cause})"));
    }
    Some(format!("epic dependency cycle: {}", edges.join("; ")))
}

/// `lanes` when two run epics can ever run at once, else `main`.
fn mode(parallel: bool, cap: u64, tasks: &[Task], d: &Deps) -> &'static str {
    let run: Vec<String> = epics_of(tasks).into_iter().collect();
    let free_pair = run.iter().enumerate().any(|(i, a)| {
        run[i + 1..]
            .iter()
            .any(|b| !reaches(d, a, b) && !reaches(d, b, a))
    });
    if parallel && cap >= 2 && free_pair {
        "lanes"
    } else {
        "main"
    }
}

/// A pending task whose dependencies inside its own epic are completed or excluded.
fn ready(t: &Task, tasks: &[Task], done: &dyn Fn(&str) -> bool) -> bool {
    t.status == "pending"
        && t.deps
            .iter()
            .all(|dep| match tasks.iter().find(|x| &x.id == dep) {
                Some(x) if x.epic != t.epic => true,
                Some(x) if x.status == "excluded" => true,
                _ => done(dep),
            })
}

/// Lowest `order` of an epic's ready tasks.
fn first_ready(epic: &str, tasks: &[Task], done: &dyn Fn(&str) -> bool) -> Option<u64> {
    tasks
        .iter()
        .filter(|t| t.epic == epic && ready(t, tasks, done))
        .map(|t| t.order)
        .min()
}

/// Run epics, lowest ready order first; epics with no ready task follow by their lowest order.
fn ordered(tasks: &[Task], done: &dyn Fn(&str) -> bool) -> Vec<String> {
    let mut v: Vec<(u64, u64, String)> = epics_of(tasks)
        .into_iter()
        .map(|e| {
            let any = tasks.iter().filter(|t| t.epic == e).map(|t| t.order).min();
            (
                first_ready(&e, tasks, done).unwrap_or(u64::MAX),
                any.unwrap_or(u64::MAX),
                e,
            )
        })
        .collect();
    v.sort();
    v.into_iter().map(|(_, _, e)| e).collect()
}

/// Epics that could start now: not started, every dependency epic done, one ready task or more.
fn candidates(
    tasks: &[Task],
    d: &Deps,
    state: &dyn Fn(&str) -> &'static str,
    done: &dyn Fn(&str) -> bool,
) -> Vec<String> {
    ordered(tasks, done)
        .into_iter()
        .filter(|e| state(e) == "waiting")
        .filter(|e| d[e].iter().all(|a| state(a) == "done"))
        .filter(|e| first_ready(e, tasks, done).is_some())
        .collect()
}

#[derive(Debug, PartialEq)]
enum Next {
    Nothing,
    Start(String),
    Judge(Vec<String>),
}

fn next(
    mode: &str,
    limit: usize,
    running: &[String],
    cands: &[String],
    cleared: &[String],
) -> Next {
    if running.len() >= limit || cands.is_empty() {
        return Next::Nothing;
    }
    match cands.iter().find(|c| {
        mode == "main" || running.is_empty() || cleared.contains(c) || c.starts_with("hotfix-")
    }) {
        Some(c) => Next::Start(c.clone()),
        None => Next::Judge(cands.to_vec()),
    }
}

struct Run<'a, 'b> {
    s: &'a S<'b>,
    tasks: Vec<Task>,
    deps: Deps,
}

impl<'a, 'b> Run<'a, 'b> {
    fn load(s: &'a S<'b>) -> Result<Self, Fail> {
        if !s.state.is_dir() {
            return Err(die(format!("no state dir: {}", s.state.display())));
        }
        if !s.steps.is_file() {
            return Err(die(format!("no state file: {}", s.steps.display())));
        }
        let epics = epic_map(s)?;
        let tasks: Vec<Task> = read_lines(&s.steps)
            .iter()
            .filter(|l| get(l, "status") != "excluded")
            .map(|l| {
                let id = get(l, "id");
                Task {
                    epic: epics
                        .get(&id)
                        .cloned()
                        .unwrap_or_else(|| FALLBACK_EPIC.into()),
                    order: num(l, "order"),
                    status: get(l, "status"),
                    deps: deps_csv(l)
                        .split(',')
                        .filter(|d| !d.is_empty())
                        .map(String::from)
                        .collect(),
                    id,
                }
            })
            .collect();
        let mut declared = Vec::new();
        for l in backlog(s, &["epics", "--deps"])?.lines() {
            let (b, csv) = l.split_once('\t').unwrap_or((l, ""));
            for a in csv.split(',').filter(|a| !a.is_empty()) {
                declared.push((b.to_string(), a.to_string()));
            }
        }
        let deps = epic_deps(&tasks, &declared);
        Ok(Run { s, tasks, deps })
    }

    fn lane_state(&self, epic: &str) -> &'static str {
        match self.s.read(&format!("lanes/{epic}")).trim() {
            "running" => "running",
            "done" => "done",
            _ => "waiting",
        }
    }

    fn done(&self) -> impl Fn(&str) -> bool + '_ {
        |id| self.s.completed_get(id).is_some()
    }

    fn running(&self) -> Vec<String> {
        self.deps
            .keys()
            .filter(|e| self.lane_state(e) == "running")
            .cloned()
            .collect()
    }

    fn limit(&self, mode: &str) -> Result<usize, Fail> {
        Ok(if mode == "lanes" {
            self.s.lane_cap()? as usize
        } else {
            1
        })
    }

    /// One `wait\t<epic>\t<reason>` line per epic that has not started.
    fn write_waiting(&self, io: &mut Io) {
        let done = self.done();
        for (e, deps) in &self.deps {
            if self.lane_state(e) != "waiting" {
                continue;
            }
            let reason = match deps.iter().find(|a| self.lane_state(a) != "done") {
                Some(a) => format!("waits for epic {a} ({})", self.lane_state(a)),
                None if first_ready(e, &self.tasks, &done).is_none() => "no ready task".into(),
                None => continue,
            };
            let _ = writeln!(io.out, "wait\t{e}\t{reason}");
        }
    }

    fn count(&self, epic: &str) -> usize {
        self.tasks.iter().filter(|t| t.epic == epic).count()
    }
}

fn backlog(s: &S, args: &[&str]) -> Result<String, Fail> {
    let (code, out, err) = s.bl(args, "");
    if code == 0 {
        Ok(out)
    } else {
        Err(die(format!("backlog {} failed: {}", args[0], err.trim())))
    }
}

/// Task id -> epic from one `backlog list`; an id the list lacks is `maintenance` at the caller.
pub fn epic_map(s: &S) -> Result<HashMap<String, String>, Fail> {
    let mut map: HashMap<String, String> = backlog(s, &["list", "--order", "created"])?
        .lines()
        .filter_map(|l| {
            let f: Vec<&str> = l.split('\x1f').collect();
            let epic = crate::backlog::epic_of(f.get(3)?);
            Some((
                f[0].to_string(),
                if epic.is_empty() {
                    FALLBACK_EPIC.into()
                } else {
                    epic
                },
            ))
        })
        .collect();
    for (id, _) in s.files_in("hotfix") {
        map.insert(id.clone(), format!("hotfix-{id}"));
    }
    Ok(map)
}

/// Epic names on the backlog.
pub(super) fn lane_names(s: &S) -> Result<Vec<String>, Fail> {
    Ok(backlog(s, &["epics"])?.lines().map(String::from).collect())
}

/// True when `radin/<name>` is a lane branch rather than a legacy task branch.
pub(super) fn is_lane(s: &S, names: &[String], name: &str) -> bool {
    name.starts_with("hotfix-")
        || name == FALLBACK_EPIC
        || names.iter().any(|n| n == name)
        || s.exists(&format!("lanes/{name}"))
}

pub fn task_epic(s: &S, id: &str) -> Result<String, Fail> {
    Ok(epic_map(s)?
        .remove(id)
        .unwrap_or_else(|| FALLBACK_EPIC.into()))
}

fn lane_lines(r: &Run, io: &mut Io, order: &[String]) {
    for e in order {
        let _ = writeln!(io.out, "lane\t{e}\t{}\t{}", r.lane_state(e), r.count(e));
    }
}

pub fn lanes_init(s: &S, io: &mut Io) -> R {
    for dir in ["gate", "hotfix"] {
        for (_, p) in s.files_in(dir) {
            let _ = std::fs::remove_file(p);
        }
    }
    let r = Run::load(s)?;
    if r.tasks.is_empty() {
        return Err(die("no tasks in the run"));
    }
    if let Some(t) = r
        .tasks
        .iter()
        .find(|t| t.epic == "wip" || t.epic.starts_with("hotfix-"))
    {
        return Err(die(format!("epic {} is reserved", t.epic)));
    }
    if let Some(msg) = cycle_message(&r.tasks, &r.deps) {
        return Err(die(msg));
    }
    let cap = s.lane_cap()?;
    let m = mode(s.session_parallel(), cap, &r.tasks, &r.deps);
    for (_, p) in s.files_in("lanes") {
        let _ = std::fs::remove_file(p);
    }
    for (_, p) in s.files_in("lane-base") {
        let _ = std::fs::remove_file(p);
    }
    s.rm("merge-queue");
    mkdir(s, "lanes");
    write(s, "lane-mode", &format!("{m}\n"));
    let order = ordered(&r.tasks, &r.done());
    let _ = writeln!(io.out, "mode\t{m}\ncap\t{cap}");
    lane_lines(&r, io, &order);
    s.journal(
        "lanes-init",
        "",
        &format!("mode={m} cap={cap} epics={}", order.join(",")),
    );
    Ok(0)
}

pub fn lane_next(s: &S, a: &[String], io: &mut Io) -> R {
    let usage = || die("usage: lane-next [--cleared <csv>]");
    let cleared: Vec<String> = match (arg(a, 0), a.len()) {
        ("", 0) => Vec::new(),
        ("--cleared", 2) => a[1].split(',').map(String::from).collect(),
        _ => return Err(usage()),
    };
    let r = Run::load(s)?;
    let m = s.lane_mode();
    let cands = candidates(&r.tasks, &r.deps, &|e| r.lane_state(e), &r.done());
    let running = r.running();
    match next(&m, r.limit(&m)?, &running, &cands, &cleared) {
        Next::Nothing => {
            if cands.is_empty() {
                r.write_waiting(io);
            }
            Ok(1)
        }
        Next::Start(e) => {
            mkdir(s, "lanes");
            write(s, &format!("lanes/{e}"), "running\n");
            s.journal("lane-start", "", &e);
            let _ = writeln!(io.out, "start\t{e}");
            Ok(0)
        }
        Next::Judge(c) => {
            let auto: Vec<String> = c
                .iter()
                .filter(|e| auto_clear(s, e, &running))
                .cloned()
                .collect();
            if !auto.is_empty() {
                let all: Vec<String> = cleared.iter().chain(&auto).cloned().collect();
                return lane_next(s, &["--cleared".into(), all.join(",")], io);
            }
            for e in c {
                let _ = writeln!(io.out, "judge\t{e}\t{}", running.join(","));
            }
            Ok(2)
        }
    }
}

/// Clears a candidate against every running epic when `overlap` shows both sides name files and share none.
fn auto_clear(s: &S, candidate: &str, running: &[String]) -> bool {
    let known = |out: &str| {
        out.lines()
            .find_map(|l| l.strip_prefix("known\ta="))
            .and_then(|l| l.split_once("\tb="))
            .is_some_and(|(a, b)| a != "0" && b != "0")
    };
    let seen: Vec<(String, i32, String, String)> = running
        .iter()
        .map(|r| {
            let (code, out, err) = s.bl(&["overlap", candidate, r], "");
            (r.clone(), code, out, err)
        })
        .collect();
    let clear = seen.iter().all(|(_, code, out, _)| {
        *code == 0 && out.contains("tiers\tfile=0\tsymbol=0\t") && known(out)
    });
    if clear {
        for (r, _, out, err) in &seen {
            record_judged(
                s,
                candidate,
                r,
                "yes",
                "no shared file or symbol",
                &flatten(out, err),
            );
        }
    }
    clear
}

fn flatten(out: &str, err: &str) -> String {
    format!("{out}{err}")
        .lines()
        .filter(|l| !l.is_empty())
        .collect::<Vec<_>>()
        .join("; ")
        .chars()
        .take(2000)
        .collect()
}

fn record_judged(s: &S, c: &str, r: &str, verdict: &str, reason: &str, evidence: &str) {
    s.telemetry(
        "judged",
        &[
            format!("epic={c}"),
            format!("with={r}"),
            format!("verdict={verdict}"),
            format!("reason={reason}"),
            format!("evidence={evidence}"),
        ],
    );
    s.journal(
        "lane-judge",
        "",
        &format!("{c} vs {r}: {verdict}: {reason}"),
    );
}

/// Records the overlap judge's decision for one candidate and running lane.
pub fn lane_judge(s: &S, a: &[String], io: &mut Io) -> R {
    let usage =
        || die("usage: lane-judge <candidate-epic> <running-epic> \"<STATUS: PARALLEL line>\"");
    let (c, r) = (arg(a, 0), arg(a, 1));
    if c.is_empty() || r.is_empty() || a.len() != 3 {
        return Err(usage());
    }
    let line = arg(a, 2);
    let (verdict, reason) = if let Some(why) = line.strip_prefix("STATUS: PARALLEL — yes: ") {
        ("yes", why.to_string())
    } else if let Some(why) = line.strip_prefix("STATUS: PARALLEL — no: ") {
        ("no", why.to_string())
    } else {
        ("no", format!("no PARALLEL line: {line}"))
    };
    let (_, out, err) = s.bl(&["overlap", c, r], "");
    record_judged(s, c, r, verdict, &reason, &flatten(&out, &err));
    let _ = writeln!(io.out, "judged\t{c}\t{r}\t{verdict}");
    Ok(0)
}

/// Why a running lane cannot enter the merge queue yet, or `None`.
pub(super) fn queue_blocker(s: &S, epic: &str) -> Result<Option<String>, Fail> {
    let r = Run::load(s)?;
    if r.lane_state(epic) != "running" {
        return Ok(Some(format!("lane {epic} is not running")));
    }
    if r.tasks
        .iter()
        .any(|t| t.epic == epic && t.status == "in_progress")
    {
        return Ok(Some(format!("lane {epic} has a task in progress")));
    }
    // Teardown starts no task, so a ready one must not keep finished work off the base.
    let ready = !s.exists("teardown") && first_ready(epic, &r.tasks, &r.done()).is_some();
    Ok(ready.then(|| format!("lane {epic} has a ready task")))
}

pub fn lane_done(s: &S, a: &[String], io: &mut Io) -> R {
    let e = arg(a, 0);
    if e.is_empty() {
        return Err(die("usage: lane-done <epic>"));
    }
    if s.read(&format!("lanes/{e}")).trim() != "running" {
        return Err(die(format!("lane {e} is not running")));
    }
    if s.lane_mode() == "lanes" {
        if super::mergeq::status(s, e) != "merged" {
            return Err(die(format!("lane {e} has not merged")));
        }
        let gate = super::gate::state_of(s, e);
        if !matches!(gate, "green" | "red") {
            return Err(die(format!("lane {e} gate is {gate}")));
        }
        if let (Some(id), "green") = (e.strip_prefix("hotfix-"), gate) {
            super::gate::close_hotfix(s, id);
        }
        super::mergeq::remove(s, e);
        let (branch, wt) = (format!("radin/{e}"), s.lane_dir_path(e));
        if wt.is_dir() || s.branch_exists(&branch) {
            drop_branch(s, "", &branch, &wt.to_string_lossy(), io);
        }
    }
    write(s, &format!("lanes/{e}"), "done\n");
    s.journal("lane-done", "", e);
    Ok(0)
}

pub fn lanes_show(s: &S, io: &mut Io) -> R {
    let m = s.lane_mode();
    if !s.exists("lane-mode") {
        let _ = writeln!(io.out, "mode\tmain");
        return Ok(0);
    }
    let r = Run::load(s)?;
    let _ = writeln!(io.out, "mode\t{m}\ncap\t{}", r.limit(&m)?);
    let mut order = ordered(&r.tasks, &r.done());
    order.sort_by_key(|e| r.lane_state(e) == "waiting");
    let mut started: Vec<String> = order
        .iter()
        .filter(|e| r.lane_state(e) != "waiting")
        .cloned()
        .collect();
    started.sort();
    let waiting = order.into_iter().filter(|e| r.lane_state(e) == "waiting");
    lane_lines(
        &r,
        io,
        &started.into_iter().chain(waiting).collect::<Vec<_>>(),
    );
    Ok(0)
}

fn sync_state(s: &S, epic: &str) -> &'static str {
    let dir = s.lane_dir_path(epic);
    let base = s.resolve_base();
    if !dir.is_dir() {
        "none"
    } else if base.is_empty() {
        "unknown"
    } else if merge_in_progress(&dir) {
        if conflicted(&dir) {
            "conflict"
        } else {
            "merging"
        }
    } else if ok(&dir, &["merge-base", "--is-ancestor", &base, "HEAD"]) {
        "current"
    } else {
        "behind"
    }
}

/// One line per running lane: `lane<TAB>epic<TAB>task<TAB>sync<TAB>queue`; nothing in `main` mode.
pub fn lanes_view(s: &S, io: &mut Io) -> R {
    if s.lane_mode() != "lanes" {
        return Ok(0);
    }
    let r = Run::load(s)?;
    let queue = super::mergeq::read(s);
    for e in r.running() {
        let task = r
            .tasks
            .iter()
            .filter(|t| t.epic == e && t.status == "in_progress")
            .min_by_key(|t| t.order)
            .map_or("-", |t| t.id.as_str());
        let pos = match queue.iter().position(|(q, _)| *q == e) {
            Some(i) if queue[i].1 == "queued" => (i + 1).to_string(),
            Some(i) if queue[i].1 == "merged" => "merged".into(),
            _ => "-".into(),
        };
        let _ = writeln!(io.out, "lane\t{e}\t{task}\t{}\t{pos}", sync_state(s, &e));
    }
    Ok(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn t(id: &str, epic: &str, order: u64, deps: &[&str]) -> Task {
        Task {
            id: id.into(),
            epic: epic.into(),
            order,
            status: "pending".into(),
            deps: deps.iter().map(|d| d.to_string()).collect(),
        }
    }

    fn none(_: &str) -> bool {
        false
    }

    fn mode_of(
        parallel: bool,
        cap: u64,
        tasks: &[Task],
        declared: &[(&str, &str)],
    ) -> &'static str {
        let declared: Vec<(String, String)> = declared
            .iter()
            .map(|(b, a)| (b.to_string(), a.to_string()))
            .collect();
        mode(parallel, cap, tasks, &epic_deps(tasks, &declared))
    }

    #[test]
    fn mode_is_lanes_only_for_two_epics_that_can_run_at_once() {
        let two = [t("a1", "a", 1, &[]), t("b1", "b", 2, &[])];
        assert_eq!(mode_of(true, 2, &two, &[]), "lanes");
        assert_eq!(mode_of(false, 2, &two, &[]), "main");
        assert_eq!(mode_of(true, 1, &two, &[]), "main");
        assert_eq!(mode_of(true, 2, &two, &[("b", "a")]), "main");
        let task_dep = [t("a1", "a", 1, &[]), t("b1", "b", 2, &["a1"])];
        assert_eq!(mode_of(true, 2, &task_dep, &[]), "main");
        assert_eq!(mode_of(true, 2, &[t("a1", "a", 1, &[])], &[]), "main");
        let chain = [
            t("a1", "a", 1, &[]),
            t("b1", "b", 2, &[]),
            t("c1", "c", 3, &[]),
        ];
        assert_eq!(mode_of(true, 2, &chain, &[("b", "a"), ("c", "b")]), "main");
        assert_eq!(mode_of(true, 2, &chain, &[("b", "a")]), "lanes");
    }

    #[test]
    fn a_cycle_names_each_epic_and_the_task_dependency_behind_each_edge() {
        let tasks = [t("a1", "a", 1, &["b1"]), t("b1", "b", 2, &["a1"])];
        let d = epic_deps(&tasks, &[]);
        assert_eq!(
            cycle_message(&tasks, &d).unwrap(),
            "epic dependency cycle: a waits for b (task a1 depends on b1); b waits for a (task b1 depends on a1)"
        );
        let free = [t("a1", "a", 1, &[]), t("b1", "b", 2, &["a1"])];
        assert_eq!(cycle_message(&free, &epic_deps(&free, &[])), None);
    }

    #[test]
    fn an_epic_outside_the_run_adds_no_edge() {
        let two = [t("a1", "a", 1, &[]), t("b1", "b", 2, &[])];
        assert_eq!(mode_of(true, 2, &two, &[("b", "gone")]), "lanes");
    }

    #[test]
    fn candidates_sort_by_lowest_ready_order_and_skip_started_and_blocked_epics() {
        let tasks = [
            t("a1", "a", 5, &[]),
            t("b1", "b", 2, &[]),
            t("c1", "c", 1, &["c0"]),
            t("c0", "c", 9, &["zz"]),
            t("d1", "d", 3, &[]),
        ];
        let d = epic_deps(&tasks, &[]);
        let st = |e: &str| if e == "d" { "running" } else { "waiting" };
        assert_eq!(candidates(&tasks, &d, &st, &none), ["b", "a"]);
        let done = |id: &str| id == "zz";
        assert_eq!(candidates(&tasks, &d, &st, &done), ["b", "a", "c"]);
    }

    #[test]
    fn a_dependent_epic_waits_until_its_dependency_epic_is_done() {
        let tasks = [t("a1", "a", 5, &[]), t("b1", "b", 1, &["a1"])];
        let d = epic_deps(&tasks, &[]);
        let st = |_: &str| "waiting";
        assert_eq!(candidates(&tasks, &d, &st, &none), ["a"]);
        let st = |e: &str| if e == "a" { "done" } else { "waiting" };
        assert_eq!(candidates(&tasks, &d, &st, &none), ["b"]);
    }

    fn names(v: &[&str]) -> Vec<String> {
        v.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn next_starts_the_first_epic_and_asks_for_clearance_beside_a_running_lane() {
        let c = names(&["b", "c"]);
        assert_eq!(next("lanes", 2, &[], &c, &[]), Next::Start("b".into()));
        let run = names(&["a"]);
        assert_eq!(next("lanes", 2, &run, &c, &[]), Next::Judge(c.clone()));
        assert_eq!(
            next("lanes", 2, &run, &c, &names(&["c"])),
            Next::Start("c".into())
        );
        assert_eq!(
            next("lanes", 2, &run, &c, &names(&["zz"])),
            Next::Judge(c.clone())
        );
        assert_eq!(next("lanes", 1, &run, &c, &names(&["c"])), Next::Nothing);
        let hot = names(&["hotfix-x", "b"]);
        assert_eq!(
            next("lanes", 2, &run, &hot, &[]),
            Next::Start("hotfix-x".into())
        );
        assert_eq!(next("lanes", 2, &[], &[], &[]), Next::Nothing);
        assert_eq!(next("main", 1, &[], &c, &[]), Next::Start("b".into()));
    }
}

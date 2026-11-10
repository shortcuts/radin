use super::git::{branch_worktree, dirty_files, g};
use super::store::{self, get, json_escape, num, read_lines};
use super::{arg, die, mkdir, positive, write, S};
use crate::backlog::{Io, R};
use std::fmt::Write;
use std::path::Path;
use std::process::{Command, Stdio};

pub fn task_dir_verb(s: &S, a: &[String], io: &mut Io) -> R {
    if arg(a, 0).is_empty() {
        return Err(die("usage: task-dir <id>"));
    }
    let _ = writeln!(io.out, "{}", s.task_dir(arg(a, 0)).display());
    Ok(0)
}

pub fn dirty_check(s: &S, io: &mut Io) -> R {
    io.out.push_str(
        &g(
            &s.c.cwd,
            &["status", "--porcelain", "--", ".", ":(exclude).radin"],
        )
        .unwrap_or_default(),
    );
    Ok(0)
}

pub fn session_set(s: &S, a: &[String]) -> R {
    let (w, b) = (arg(a, 0), arg(a, 1));
    if w.is_empty() || b.is_empty() {
        return Err(die("usage: session-set <yes|no> <yes|no>"));
    }
    if !s.state.is_dir() {
        return Err(die(format!("no state dir: {}", s.state.display())));
    }
    for m in [w, b] {
        if !matches!(m, "yes" | "no") {
            return Err(die(format!("modes must be yes|no, got: {m}")));
        }
    }
    write(
        s,
        "session.json",
        &format!("{{\"worktree\":\"{w}\",\"branch\":\"{b}\"}}\n"),
    );
    s.journal("session", "", &format!("worktree={w} branch={b}"));
    Ok(0)
}

pub fn session_get(s: &S, io: &mut Io) -> R {
    match s.session_get() {
        Some((w, b)) => {
            let _ = writeln!(io.out, "worktree\t{w}\nbranch\t{b}");
            Ok(0)
        }
        None => Ok(1),
    }
}

pub fn group_set(s: &S, a: &[String]) -> R {
    let mut a = a;
    let mut wave = String::new();
    if arg(a, 0) == "--wave" {
        wave = arg(a, 1).to_string();
        if !positive(&wave) {
            return Err(die(format!(
                "group-set: --wave needs a positive integer, got: {wave}"
            )));
        }
        a = &a[2.min(a.len())..];
    }
    let usage = || die("usage: group-set [--wave N] <id>...");
    if a.is_empty() {
        return Err(usage());
    }
    if !s.state.is_dir() {
        return Err(die(format!("no state dir: {}", s.state.display())));
    }
    if a.iter().any(|g| {
        g.is_empty()
            || !g
                .bytes()
                .all(|c| c.is_ascii_alphanumeric() || matches!(c, b'.' | b'_' | b'-'))
    }) {
        return Err(usage());
    }
    let ids = a.join(",");
    let mut detail = format!("ids={ids}");
    if !wave.is_empty() {
        mkdir(s, "wave-of");
        for id in a {
            write(s, &format!("wave-of/{id}"), &wave);
        }
        detail += &format!("; wave={wave}");
    }
    s.journal_ctx("group", "", &detail, &[("wave", wave.clone())]);
    let mut kv = vec![format!("ids={ids}"), format!("size={}", a.len())];
    if !wave.is_empty() {
        kv.push(format!("wave={wave}"));
    }
    s.telemetry("dispatched", &kv);
    Ok(0)
}

pub fn gate_done(s: &S) -> R {
    s.touch("gate-done");
    s.journal("gate-done", "", "");
    Ok(0)
}

pub fn gate_fix(s: &S, a: &[String]) -> R {
    if a.is_empty() {
        return Err(die("usage: gate-fix <hash>..."));
    }
    if !s.state.is_dir() {
        return Err(die(format!("no state dir: {}", s.state.display())));
    }
    let mut fixes = String::new();
    for rev in a {
        let short = s.gt(&[
            "rev-parse",
            "--verify",
            "--quiet",
            "--short=12",
            &format!("{rev}^{{commit}}"),
        ]);
        if short.is_empty() {
            return Err(die(format!("not a commit: {rev}")));
        }
        fixes += &format!("{short}\n");
    }
    store::append(&s.state.join("gate-fixes"), &fixes);
    s.journal("gate-fix", "", &a.join(" "));
    Ok(0)
}

pub fn gate_filed(s: &S, a: &[String]) -> R {
    if a.is_empty() {
        return Err(die("usage: gate-filed <id>..."));
    }
    if !s.steps.is_file() {
        return Err(die(format!("no state file: {}", s.steps.display())));
    }
    if s.exists("gate-reviewed") {
        return Err(die("the gate's review round is already used"));
    }
    let mut next = read_lines(&s.steps)
        .iter()
        .map(|l| num(l, "order"))
        .max()
        .unwrap_or(0);
    for id in a {
        if s.field(id, "TASK_ID").is_err() {
            return Err(die(format!("no backlog task matches: {id}")));
        }
        next += 1;
        let deps = store::deps_json(&s.find_deps(id));
        store::append(
            &s.steps,
            &format!(
                "{}\n",
                store::entry_json(id, next, "pending", &deps, 0, 0, "")
            ),
        );
    }
    s.touch("gate-reviewed");
    s.journal("gate-filed", "", &a.join(" "));
    Ok(0)
}

fn completed_after_baseline(s: &S) -> Vec<String> {
    let base = num(&s.read("baseline.json"), "completed_count") as usize;
    read_lines(&s.completed).into_iter().skip(base).collect()
}

pub fn session_commits(s: &S) -> Option<String> {
    let mut out: Vec<String> = completed_after_baseline(s)
        .iter()
        .map(|l| get(l, "commit"))
        .collect();
    for (_, p) in s.files_in("unmerged") {
        out.push(
            std::fs::read_to_string(p)
                .unwrap_or_default()
                .trim_end_matches('\n')
                .to_string(),
        );
    }
    let fixes = s.read("gate-fixes");
    if !fixes.is_empty() {
        out.push(fixes.trim_end_matches('\n').to_string());
    }
    if out.is_empty() {
        return None;
    }
    let mut seen: Vec<String> = Vec::new();
    for l in out.join("\n").lines() {
        if !seen.iter().any(|x| x == l) {
            seen.push(l.to_string());
        }
    }
    Some(seen.join("\n"))
}

pub fn session_commits_verb(s: &S, io: &mut Io) -> R {
    match session_commits(s) {
        Some(t) => {
            let _ = writeln!(io.out, "{t}");
            Ok(0)
        }
        None => Ok(1),
    }
}

pub fn gate_map(s: &S, io: &mut Io) -> R {
    let Some(commits) = session_commits(s) else {
        return Ok(1);
    };
    let mut map: Vec<(String, String)> = Vec::new();
    for l in completed_after_baseline(s) {
        let p = s.read(&format!("prepared/{}.json", get(&l, "id")));
        if !p.is_empty() {
            map.push((get(&l, "commit"), get(&p, "branch")));
        }
    }
    for (name, path) in s.files_in("unmerged") {
        let p = s.read(&format!("prepared/{name}.json"));
        if !p.is_empty() {
            map.push((
                std::fs::read_to_string(path)
                    .unwrap_or_default()
                    .trim_end()
                    .to_string(),
                get(&p, "branch"),
            ));
        }
    }
    let worktrees = s.gt(&["worktree", "list", "--porcelain"]);
    let mut seen: Vec<String> = Vec::new();
    for chash in commits.lines() {
        let mut branch = map
            .iter()
            .find(|(h, _)| h == chash)
            .map(|(_, b)| b.clone())
            .unwrap_or_default();
        if branch.is_empty() {
            let contains = s.gt(&["branch", "--contains", chash, "--format=%(refname:short)"]);
            branch = contains
                .lines()
                .find(|l| !l.starts_with('('))
                .unwrap_or("")
                .to_string();
        }
        if branch.is_empty() {
            branch = "HEAD".into();
        }
        if seen.contains(&branch) {
            continue;
        }
        seen.push(branch.clone());
        let tip = s.gt(&["rev-parse", "--short=12", &branch]);
        if tip.is_empty() {
            continue;
        }
        let wt = branch_worktree(&worktrees, &branch);
        let wt = if wt.is_empty() {
            s.root.display().to_string()
        } else {
            wt
        };
        let _ = writeln!(io.out, "{branch}\t{tip}\t{wt}\t{chash}");
    }
    Ok(0)
}

fn last_event(s: &S, id: &str, events: &[&str]) -> Option<String> {
    let key = format!("\"id\":\"{}\"", json_escape(id));
    s.journal_lines()
        .iter()
        .filter(|l| l.contains(&key))
        .map(|l| get(l, "event"))
        .rfind(|e| events.contains(&e.as_str()))
}

fn worktree_blocks(porcelain: &str) -> Vec<Vec<&str>> {
    let mut blocks: Vec<Vec<&str>> = Vec::new();
    let mut cur: Vec<&str> = Vec::new();
    for l in porcelain.lines() {
        if l.is_empty() {
            if !cur.is_empty() {
                blocks.push(std::mem::take(&mut cur));
            }
        } else {
            cur.push(l);
        }
    }
    if !cur.is_empty() {
        blocks.push(cur);
    }
    blocks
}

fn patch_id(dir: &Path, commit: &str) -> String {
    let Some(diff) = g(dir, &["diff-tree", "-p", commit]) else {
        return String::new();
    };
    let Ok(mut child) = Command::new("git")
        .args(["patch-id", "--stable"])
        .current_dir(dir)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
    else {
        return String::new();
    };
    if let Some(mut si) = child.stdin.take() {
        use std::io::Write as _;
        let _ = si.write_all(diff.as_bytes());
    }
    let out = child
        .wait_with_output()
        .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
        .unwrap_or_default();
    out.split(' ').next().unwrap_or("").trim().to_string()
}

pub fn leftovers(s: &S, io: &mut Io) -> R {
    let base = s.resolve_base();
    if base.is_empty() {
        return Err(die("no base branch"));
    }
    let porcelain = s.gt(&["worktree", "list", "--porcelain"]);
    let blocks = worktree_blocks(&porcelain);
    let mut rows: Vec<(String, String)> = Vec::new();
    let mut keys: Vec<(String, Vec<String>)> = Vec::new();
    let mut key_add = |key: String, b: &str| {
        if let Some((_, v)) = keys.iter_mut().find(|(k, _)| *k == key) {
            if !v.iter().any(|x| x == b) {
                v.push(b.to_string());
            }
        } else {
            keys.push((key, vec![b.to_string()]));
        }
    };
    for b in s.radin_branches() {
        let cherry = s.gt(&["cherry", &base, &b]);
        let ahead = cherry.lines().filter(|l| l.starts_with('+')).count();
        if ahead == 0 {
            continue;
        }
        let want = format!("branch refs/heads/{b}");
        let blk = blocks.iter().find(|bl| bl.contains(&want.as_str()));
        let wpath = blk
            .and_then(|bl| bl.iter().find_map(|l| l.strip_prefix("worktree ")))
            .unwrap_or("");
        let prunable = blk.is_some_and(|bl| bl.iter().any(|l| l.starts_with("prunable")));
        let (wp, state) = if wpath.is_empty() {
            ("-", "none")
        } else if prunable {
            (wpath, "prunable")
        } else if !dirty_files(Path::new(wpath)).is_empty() {
            (wpath, "dirty")
        } else {
            (wpath, "clean")
        };
        let status = last_event(
            s,
            b.trim_start_matches("radin/"),
            &["done-unmerged", "done", "unproven", "failed"],
        )
        .unwrap_or_else(|| "none".into());
        rows.push((b.clone(), format!("{b}\t{ahead}\t{wp}\t{state}\t{status}")));
        for c in s.gt(&["rev-list", &format!("{base}..{b}")]).lines() {
            key_add(format!("s:{}", s.gt(&["log", "-1", "--format=%s", c])), &b);
            let pid = patch_id(&s.root, c);
            if !pid.is_empty() {
                key_add(format!("p:{pid}"), &b);
            }
        }
    }
    let mut parts: Vec<String> = Vec::new();
    for (b, row) in &rows {
        let mut others: Vec<&str> = Vec::new();
        for (_, brs) in keys.iter().filter(|(_, brs)| brs.contains(b)) {
            for o in brs.iter().filter(|o| *o != b) {
                if !others.contains(&o.as_str()) {
                    others.push(o);
                }
            }
        }
        let o = if others.is_empty() {
            "-".to_string()
        } else {
            others.join(",")
        };
        parts.push(format!("branch\t{row}\t{o}"));
    }
    let mut stashes: Vec<String> = Vec::new();
    for l in radin_batch_stashes(s) {
        let (h, msg) = l.split_once('\t').unwrap_or((&l, ""));
        let id = msg
            .rfind("before task ")
            .map_or("-", |i| &msg[i + "before task ".len()..]);
        stashes.push(format!(
            "stash\t{h}\t{}\t{msg}",
            if id.is_empty() { "-" } else { id }
        ));
    }
    let root = blocks
        .first()
        .and_then(|b| b[0].strip_prefix("worktree "))
        .unwrap_or("");
    let mut foreign: Vec<String> = Vec::new();
    for bl in blocks.iter().skip(1) {
        let w = bl
            .iter()
            .find_map(|l| l.strip_prefix("worktree "))
            .unwrap_or("");
        let br = bl
            .iter()
            .find_map(|l| l.strip_prefix("branch "))
            .unwrap_or("");
        let own = br
            .strip_prefix("refs/heads/radin/")
            .is_some_and(|id| w == format!("{root}-{id}"));
        if !own {
            let name =
                br.strip_prefix("refs/heads/")
                    .unwrap_or(if br.is_empty() { "-" } else { br });
            foreign.push(format!("foreign\t{w}\t{name}"));
        }
    }
    if parts.is_empty() && stashes.is_empty() && foreign.is_empty() {
        return Ok(1);
    }
    let _ = writeln!(io.out, "base\t{base}");
    for l in parts.iter().chain(&stashes).chain(&foreign) {
        let _ = writeln!(io.out, "{l}");
    }
    Ok(0)
}

fn radin_batch_stashes(s: &S) -> Vec<String> {
    s.gt(&["stash", "list", "--format=%H%x09%gs"])
        .lines()
        .filter(|l| l.contains("radin-batch: "))
        .map(String::from)
        .collect()
}

fn triaged(s: &S, h: &str) -> Vec<String> {
    let d = format!("\"detail\":\"{h}\"");
    s.journal_lines()
        .into_iter()
        .filter(|l| l.contains("\"event\":\"stash-triage\"") && l.contains(&d))
        .collect()
}

pub fn stash_triage(s: &S, io: &mut Io) -> R {
    let mut rows: Vec<(String, String)> = Vec::new();
    let mut left = 0;
    for l in radin_batch_stashes(s) {
        let h = l.split('\t').next().unwrap_or("").to_string();
        let t = triaged(s, &h);
        if t.iter().any(|x| !x.contains("\"id\":\"\"")) {
            continue;
        }
        left += 1;
        if !t.is_empty() {
            continue;
        }
        for p in s
            .gt(&["stash", "show", "--include-untracked", "--name-only", &h])
            .lines()
        {
            rows.push((h.clone(), p.to_string()));
        }
    }
    if left == 0 {
        return Ok(0);
    }
    let mut seen: Vec<(String, String)> = Vec::new();
    for l in s.bl_ok(&["list"]).unwrap_or_default().lines() {
        let id = l.split('\u{1f}').next().unwrap_or("");
        let mut hay = s
            .field(id, "TASK_FILE")
            .ok()
            .and_then(|f| std::fs::read_to_string(f).ok())
            .unwrap_or_default();
        hay += &s.bl_ok(&["files", id]).unwrap_or_default();
        for (h, p) in rows.iter().filter(|(_, p)| !p.is_empty()) {
            if seen.iter().any(|(sh, si)| sh == h && si == id) || !hay.contains(p.as_str()) {
                continue;
            }
            seen.push((h.clone(), id.to_string()));
            let _ = writeln!(io.out, "candidate\t{h}\t{id}");
        }
    }
    let _ = writeln!(io.out, "left\t{left}");
    Ok(0)
}

pub fn stash_claim(s: &S, a: &[String]) -> R {
    let (h, cid) = (arg(a, 0), arg(a, 1));
    if h.is_empty() || cid.is_empty() {
        return Err(die("usage: stash-claim <hash> <id|->"));
    }
    if !triaged(s, h).is_empty() {
        return Err(die(format!("already triaged: {h}")));
    }
    if !s.gt(&["stash", "list", "--format=%H"]).contains(h) {
        return Err(die(format!("no such stash: {h}")));
    }
    if cid == "-" {
        s.journal("stash-triage", "", h);
    } else {
        mkdir(s, "stash-claims");
        write(s, &format!("stash-claims/{cid}"), &format!("{h}\n"));
        s.journal("stash-triage", cid, h);
    }
    Ok(0)
}

pub fn unlanded(s: &S, io: &mut Io) -> R {
    let base = s.resolve_base();
    if base.is_empty() {
        return Ok(1);
    }
    let mut rows: Vec<String> = Vec::new();
    for (name, p) in s.files_in("unmerged") {
        let h = std::fs::read_to_string(p)
            .unwrap_or_default()
            .trim_end_matches('\n')
            .to_string();
        rows.push(format!("{name}\t{h}\tradin/{name}\tpending"));
    }
    for l in read_lines(&s.completed) {
        let b = get(&l, "branch");
        if b.starts_with("radin/")
            && s.branch_exists(&b)
            && s.gt(&["cherry", &base, &b])
                .lines()
                .any(|c| c.starts_with('+'))
        {
            rows.push(format!(
                "{}\t{}\t{b}\torphan",
                get(&l, "id"),
                get(&l, "commit")
            ));
        }
    }
    for r in &rows {
        let _ = writeln!(io.out, "{r}");
    }
    Ok(i32::from(rows.is_empty()))
}

pub fn completed_list(s: &S, io: &mut Io) -> R {
    let lines = read_lines(&s.completed);
    for l in &lines {
        let _ = writeln!(io.out, "{}\t{}", get(l, "id"), get(l, "commit"));
    }
    Ok(i32::from(lines.is_empty()))
}

pub fn completed_show(s: &S, a: &[String], io: &mut Io) -> R {
    let id = arg(a, 0);
    if id.is_empty() {
        return Err(die("usage: completed-show <id>"));
    }
    let Some(l) = read_lines(&s.completed)
        .into_iter()
        .find(|l| get(l, "id") == id)
    else {
        return Ok(1);
    };
    for k in [
        "id", "commit", "title", "branch", "worktree", "plan", "ts", "created",
    ] {
        let _ = writeln!(io.out, "{k}\t{}", get(&l, k));
    }
    Ok(0)
}

fn trace_block(
    s: &S,
    id: &str,
    commit: &str,
    branch: &str,
    wt: &str,
    plan: &str,
    status: &str,
) -> String {
    let facts = s.state.join(format!("facts/{id}.md"));
    let facts = if facts.is_file() {
        facts.display().to_string()
    } else {
        String::new()
    };
    format!("task\t{id}\ncommit\t{commit}\nbranch\t{branch}\nworktree\t{wt}\nplan\t{plan}\nfacts\t{facts}\nstatus\t{status}\n")
}

pub fn trace(s: &S, a: &[String], io: &mut Io) -> R {
    let arg0 = arg(a, 0);
    if arg0.is_empty() {
        return Err(die("usage: trace <id|commit|branch>"));
    }
    let completed = read_lines(&s.completed);
    let done_block = |l: &str, c: &str, b: &str| {
        trace_block(
            s,
            &get(l, "id"),
            c,
            b,
            &get(l, "worktree"),
            &get(l, "plan"),
            "done",
        )
    };
    let mut id_read = String::new();
    if let Some(l) = completed.iter().find(|l| get(l, "id") == arg0) {
        id_read = done_block(l, &get(l, "commit"), &get(l, "branch"));
    } else if !s.read(&format!("prepared/{arg0}.json")).is_empty()
        || s.read("journal.jsonl")
            .contains(&format!("\"id\":\"{}\"", json_escape(arg0)))
    {
        let status = last_event(s, arg0, &["pending", "in_progress", "failed", "blocked"])
            .unwrap_or_default();
        id_read = trace_block(
            s,
            arg0,
            "",
            &s.prepared_field(arg0, "branch"),
            &s.prepared_field(arg0, "worktree"),
            &s.task_plans(arg0),
            &status,
        );
    }
    let mut commit_read = String::new();
    if arg0.chars().count() >= 7 {
        for l in &completed {
            let c = get(l, "commit");
            if c.chars().count() >= 7 && (c.starts_with(arg0) || arg0.starts_with(&c)) {
                commit_read += &done_block(l, &c, &get(l, "branch"));
            }
        }
    }
    let mut branch_read = String::new();
    let mut seen: Vec<String> = Vec::new();
    for l in completed.iter().filter(|l| get(l, "branch") == arg0) {
        seen.push(get(l, "id"));
        branch_read += &done_block(l, &get(l, "commit"), arg0);
    }
    let mut prepared: Vec<String> = s
        .files_in("prepared")
        .into_iter()
        .filter_map(|(n, _)| n.strip_suffix(".json").map(String::from))
        .collect();
    prepared.sort();
    for id in prepared.iter().filter(|id| !seen.contains(id)) {
        if s.prepared_field(id, "branch") != arg0 {
            continue;
        }
        let status =
            last_event(s, id, &["pending", "in_progress", "failed", "blocked"]).unwrap_or_default();
        branch_read += &trace_block(
            s,
            id,
            "",
            arg0,
            &s.prepared_field(id, "worktree"),
            &s.task_plans(id),
            &status,
        );
    }
    let reads = [id_read, commit_read, branch_read];
    let found: Vec<&String> = reads.iter().filter(|r| !r.is_empty()).collect();
    match found.len() {
        1 => {
            io.out.push_str(found[0]);
            Ok(0)
        }
        0 => Err(die(format!(
            "\"{arg0}\" is not a traced task, commit or branch in {}",
            s.ns.display()
        ))),
        n => {
            let _ = writeln!(
                io.err,
                "radin-state: \"{arg0}\" is ambiguous, {n} candidate readings:"
            );
            for r in found {
                let _ = writeln!(io.err, "{r}---");
            }
            Ok(2)
        }
    }
}

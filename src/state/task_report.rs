use super::done::task_done;
use super::git::{dirty_files, wip_commit};
use super::plan_cover::plan_extras;
use super::store::{get, json_escape, num, MAX_ATTEMPTS};
use super::{arg, die, S};
use crate::backlog::{Fail, Io, R};
use std::fmt::Write;

fn order_title(s: &S, id: &str) -> (u64, String) {
    let order = s.entry(id).map_or(0, |e| num(&e, "order"));
    let title = s.task_title(id);
    (
        order,
        if title.is_empty() {
            id.to_string()
        } else {
            title
        },
    )
}

/// The FAILED route: None the first time (the router sends the debug prompt), the report line after that.
fn task_fail(s: &S, id: &str, reason: &str) -> Result<Option<String>, Fail> {
    let entry = s.need_entry(id)?;
    let (order, title) = order_title(s, id);
    if num(&entry, "debugged") == 0 {
        s.write_entry(
            id,
            &get(&entry, "status"),
            num(&entry, "attempts"),
            &get(&entry, "note"),
            Some(1),
        )?;
        s.dispatch_new(id, "debug");
        s.journal_ctx("debug", id, reason, &s.dispatch_extras(id, Some("debug")));
        return Ok(None);
    }
    let lines = s.journal_lines();
    let diagnosed = lines
        .iter()
        .any(|l| l.contains(&format!("\"event\":\"diagnosis\",\"id\":\"{id}\"")));
    let debug_key = format!("\"event\":\"debug\",\"id\":\"{id}\"");
    let reported = format!("\"detail\":\"{}\"}}", json_escape(reason));
    if !diagnosed
        && !s.exists(&format!("prompts/{id}-debug.md"))
        && lines
            .iter()
            .rfind(|l| l.contains(&debug_key))
            .is_some_and(|l| !l.ends_with(&reported))
    {
        return Err(die(format!(
            "{id} already reported a failure and awaits its debug pass; re-run with the line from the first report"
        )));
    }
    let note = if diagnosed {
        format!("{reason} (a diagnosis was recorded on the task file under **Root cause:**)")
    } else {
        reason.to_string()
    };
    s.write_entry(id, "failed", num(&entry, "attempts"), &note, None)?;
    s.entry_note(id, &format!("failed after its debug pass: {note}"));
    Ok(Some(format!(
        "❌ Task {order} '{title}' failed: {reason}. Kept on the backlog with a note, moving on.\n"
    )))
}

/// Commits a dirty tree of task `id` as a wip commit and sends the task back to pending; None when the tree is clean.
fn dirty_recover(s: &S, id: &str, word: &str) -> Result<Option<String>, Fail> {
    let dir = s.task_dir(id);
    if dirty_files(&dir).is_empty() {
        return Ok(None);
    }
    let (order, title) = order_title(s, id);
    let hash = wip_commit(
        &dir,
        id,
        &format!("Left uncommitted by the sub-agent (reported {word}). The task is not complete."),
    );
    let d = dir.display();
    let attempts = s.entry(id).map_or(0, |e| num(&e, "attempts"));
    s.write_entry(
        id,
        "pending",
        attempts,
        &format!("retrying: sub-agent left work uncommitted, saved as wip commit {hash} in {d}"),
        None,
    )?;
    s.entry_note(id, &format!("an earlier attempt left unfinished work, saved as wip commit {hash}. Build on it, verify it, and commit the rest."));
    s.journal(
        "wip",
        id,
        &format!("{hash} in {d} -- task {order} '{title}' left uncommitted"),
    );
    Ok(Some(format!("⚠️ Task {order} '{title}': sub-agent reported {word} but left a dirty tree. Committed as wip {hash}, back to pending for a retry.\n")))
}

fn infra_error(text: &str) -> bool {
    let t = text.to_lowercase();
    let literals = [
        "api error",
        "overloaded",
        "429",
        "529",
        "timed out",
        "timeout",
        "econnreset",
        "socket hang up",
        "network error",
        "connection reset",
        "connection refused",
        "connection error",
        "connection closed",
        "ratelimit",
    ];
    literals.iter().any(|l| t.contains(l))
        || t.match_indices("rate").any(|(i, _)| {
            let r = &t[i + 4..];
            r.starts_with("limit")
                || r.chars()
                    .next()
                    .is_some_and(|c| r[c.len_utf8()..].starts_with("limit"))
        })
}

fn first_hash(text: &str) -> Option<String> {
    let b = text.as_bytes();
    let mut i = 0;
    while i < b.len() {
        let n = b[i..]
            .iter()
            .take_while(|c| matches!(c, b'0'..=b'9' | b'a'..=b'f'))
            .count();
        if n >= 7 {
            return Some(text[i..i + n.min(40)].to_string());
        }
        i += n.max(1);
    }
    None
}

const EXEC_CHECKS: [(&str, bool); 3] = [("test", true), ("lint", true), ("review", false)];
const PLAN_CHECKS: [(&str, bool); 1] = [("plan-review", false)];

/// Required keys the last `; checks:` clause of `line` lacks; the bool allows `na`.
fn missing_checks(line: &str, required: &[(&'static str, bool)]) -> Vec<&'static str> {
    let clause = line.rsplit_once("; checks:").map_or("", |x| x.1);
    let got: Vec<(&str, &str)> = clause
        .split(',')
        .filter_map(|i| i.split_once('='))
        .map(|(k, v)| (k.trim(), v.trim()))
        .collect();
    required
        .iter()
        .filter(|(k, na)| {
            !got.iter()
                .any(|(gk, gv)| gk == k && (*gv == "pass" || (*na && *gv == "na")))
        })
        .map(|(k, _)| *k)
        .collect()
}

fn usage_ok(u: &str) -> bool {
    let f: Vec<&str> = u.split(' ').collect();
    f.len() == 4
        && matches!(f[0], "planning" | "execution" | "debug" | "factfind")
        && f[1..]
            .iter()
            .all(|n| !n.is_empty() && n.bytes().all(|c| c.is_ascii_digit()))
        && f[1..].iter().any(|n| n.bytes().any(|c| c != b'0'))
}

pub fn task_report(s: &S, a: &[String], io: &mut Io) -> R {
    let (mut fuse, mut usages, mut rest) = (false, Vec::new(), Vec::new());
    let mut it = a.iter();
    while let Some(x) = it.next() {
        match x.as_str() {
            "--next" => fuse = true,
            "--usage" => usages.push(
                it.next()
                    .ok_or_else(|| die("--usage needs a value"))?
                    .clone(),
            ),
            _ => rest.push(x.clone()),
        }
    }
    if fuse && s.session_get().is_some_and(|(w, _)| w == "yes") {
        return Err(die(
            "--next is refused in wave mode (session worktree is yes): drop --next, a wave never claims a task outside its group",
        ));
    }
    if !fuse {
        return report_inner(s, &rest, &usages, io);
    }
    let mut child = Io::default();
    let r = report_inner(s, &rest, &usages, &mut child);
    io.out.push_str(&child.out);
    io.err.push_str(&child.err);
    let rc = r?;
    if rc != 0 || child.out.lines().last() != Some("next\tcontinue") {
        return Ok(rc);
    }
    super::done::task_next(s, "", io)
}

fn next_continue(io: &mut Io) -> R {
    io.out.push_str("next\tcontinue\n");
    Ok(0)
}

fn report_inner(s: &S, a: &[String], usages: &[String], io: &mut Io) -> R {
    let (id, third) = (arg(a, 0), arg(a, 1));
    if id.is_empty() || third.is_empty() {
        return Err(die(
            "usage: task-report <id> <STATUS line>  |  task-report <id> --no-status <last line>",
        ));
    }
    let entry = s.need_entry(id)?;
    for u in usages {
        if usage_ok(u) {
            let kind = u.split(' ').next();
            s.journal_ctx("usage", id, u, &s.dispatch_extras(id, kind));
        } else {
            let _ = writeln!(io.err, "radin-state: ignoring malformed --usage: {u}");
        }
    }
    let attempts = num(&entry, "attempts");
    let note = get(&entry, "note");
    if third == "--no-status" {
        let last = arg(a, 2);
        let (order, title) = order_title(s, id);
        if note.starts_with("planning dispatch") {
            s.write_entry(id, "pending", attempts, &note, None)?;
            let _ = writeln!(io.out, "⚠️ Task {order} '{title}': planning sub-agent returned no STATUS line (attempt {attempts} of {MAX_ATTEMPTS}). Back to pending for a retry.");
            return next_continue(io);
        }
        if infra_error(last) {
            s.write_entry(
                id,
                "pending",
                attempts,
                &format!("infra error, retrying: {last}"),
                None,
            )?;
            let _ = writeln!(io.out, "⚠️ Task {order} '{title}': sub-agent died on an infra error ({last}). Back to pending for a retry (attempt {attempts} of {MAX_ATTEMPTS} so far).");
            return next_continue(io);
        }
        if let Some(m) = dirty_recover(s, id, "no STATUS line")? {
            io.out.push_str(&m);
            return next_continue(io);
        }
        s.write_entry(
            id,
            "pending",
            attempts,
            &format!("retrying: sub-agent returned no STATUS line; last words: {last}"),
            None,
        )?;
        let _ = writeln!(io.out, "⚠️ Task {order} '{title}': sub-agent returned no STATUS line (attempt {attempts} of {MAX_ATTEMPTS}). Back to pending for a retry.");
        return next_continue(io);
    }
    let line = third;
    // A summary may quote another status word, so only the word after `STATUS:` counts.
    let head = line
        .split_once("STATUS:")
        .map_or(line, |x| x.1)
        .trim_start();
    let (mut word, mut tag) = ("", "");
    if head.starts_with("PLANNED") {
        word = "PLANNED";
    } else if head.starts_with("BLOCKED (FACT)") {
        (word, tag) = ("BLOCKED", "FACT");
    } else if head.starts_with("BLOCKED (DECISION)") {
        (word, tag) = ("BLOCKED", "DECISION");
    } else if head.starts_with("INCONCLUSIVE") {
        word = "INCONCLUSIVE";
    } else if head.starts_with("SUCCESS") {
        word = "SUCCESS";
    } else if head.starts_with("FAILED") {
        word = "FAILED";
    }
    if word.is_empty() {
        return Err(die(format!("no SUCCESS/FAILED/INCONCLUSIVE/BLOCKED in that line: {line} -- pass --no-status when the sub-agent produced none")));
    }
    let required: &[(&'static str, bool)] = match word {
        "SUCCESS" => &EXEC_CHECKS,
        "PLANNED"
            if !matches!(
                line.split_once('—').map_or(line, |x| x.1),
                d if d.starts_with(" none needed") || d.starts_with(" deferred")
            ) =>
        {
            &PLAN_CHECKS
        }
        _ => &[],
    };
    let lacks = missing_checks(line, required);
    let mut forced = None;
    if !lacks.is_empty() {
        forced = Some(format!(
            "reported {word} without a passing check: {}",
            lacks.join(", ")
        ));
        word = "INCONCLUSIVE";
    }
    if word == "PLANNED" {
        let detail = line.split_once('—').map_or(line, |x| x.1);
        if detail.starts_with(" deferred") {
            let _ = writeln!(io.out, "task-report: deferred {id}");
            return next_continue(io);
        }
        if detail.starts_with(" none needed") {
            s.bl_must(&["set-meta", id, "planning", "--none"], "")?;
        }
        let size = if detail.contains("complexity low:") {
            "low"
        } else if detail.contains("complexity high:") {
            "high"
        } else {
            ""
        };
        if size.is_empty() {
            let _ = writeln!(
                io.err,
                "radin-state: PLANNED line for {id} has no \"complexity low|high:\"; left unsized"
            );
        } else {
            s.bl_must(&["set-meta", id, "complexity", size], "")?;
        }
        if detail.contains("; exclusive:") {
            s.bl_must(&["set-meta", id, "exclusive", "yes"], "")?;
        }
        s.journal(
            "planned",
            id,
            &format!(
                "complexity={} exclusive={} plan={}",
                if size.is_empty() { "unsized" } else { size },
                if detail.contains("; exclusive:") {
                    "yes"
                } else {
                    "no"
                },
                if detail.starts_with(" none needed") {
                    "none"
                } else {
                    "yes"
                }
            ),
        );
        let _ = writeln!(io.out, "task-report: planned {id}");
        return next_continue(io);
    }
    if let Some(m) = dirty_recover(s, id, word)? {
        io.out.push_str(&m);
        return next_continue(io);
    }
    let detail = if let Some((_, d)) = line.split_once('—') {
        d
    } else if let Some((_, d)) = line.split_once(" -- ") {
        d
    } else {
        line
    };
    let mut detail =
        forced.unwrap_or_else(|| detail.strip_prefix(' ').unwrap_or(detail).to_string());
    if word == "BLOCKED" {
        if tag == "FACT" {
            s.dispatch_new(id, "factfind");
        }
        s.write_entry_as(id, "blocked", &tag.to_lowercase(), attempts, &detail, None)?;
        let _ = writeln!(io.out, "next\tclarify {tag}");
        return Ok(0);
    }
    if word == "INCONCLUSIVE" {
        s.write_entry_as(
            id,
            "blocked",
            "inconclusive",
            attempts,
            &format!("inconclusive: {detail}"),
            None,
        )?;
        let (order, title) = order_title(s, id);
        s.entry_note(id, &format!("inconclusive: {detail}"));
        let _ = writeln!(io.out, "⚠️ Task {order} '{title}' inconclusive: {detail}. Not counted as a pass. Kept on the backlog with a note, moving on.");
        return next_continue(io);
    }
    if word == "SUCCESS" {
        match first_hash(&detail) {
            Some(hash) => {
                let unproven = unproven_criteria(s, id);
                let plan = s.plan_files(id);
                let extras = plan_extras(&s.task_dir(id), &hash, &plan);
                if !extras.is_empty() {
                    let csv = plan.join(",");
                    s.telemetry(
                        "out-of-bounds",
                        &[
                            format!("task={id}"),
                            format!("commit={hash}"),
                            format!("plan={csv}"),
                            format!("extra={extras}"),
                        ],
                    );
                }
                let mut d = Io::default();
                let r = task_done(s, id, &hash, &mut d);
                let done_out = format!(
                    "{}{}",
                    d.out,
                    d.err + &r.as_ref().err().map_or(String::new(), |e| e.msg.clone())
                );
                if matches!(r, Ok(0)) {
                    io.out.push_str(&done_out);
                    let body = detail
                        .rsplit_once("; checks:")
                        .map_or(detail.as_str(), |x| x.0);
                    if let Some((_, sum)) = body.split_once(';') {
                        let sum = sum.trim_start_matches(' ');
                        if !sum.is_empty() {
                            s.journal("summary", id, sum);
                        }
                    }
                    for c in &unproven {
                        s.journal("unproven", id, c);
                    }
                    return next_continue(io);
                }
                detail = format!(
                    "reported SUCCESS at {hash}, which does not validate: {}",
                    done_out.trim_end_matches('\n')
                );
            }
            None => detail = "reported SUCCESS with no commit hash in the line".into(),
        }
    }
    match task_fail(s, id, &detail)? {
        Some(m) => {
            io.out.push_str(&m);
            next_continue(io)
        }
        None => {
            let (order, title) = order_title(s, id);
            let _ = writeln!(
                io.out,
                "⚠️ Task {order} '{title}' failed: {detail}. Its one debug pass is next."
            );
            io.out.push_str("next\tdebug\n");
            Ok(0)
        }
    }
}

/// Acceptance criteria no `**Fact:** [measured]` line starts with; read before task-done deletes the task file.
fn unproven_criteria(s: &S, id: &str) -> Vec<String> {
    let facts: Vec<String> = s
        .field(id, "TASK_FILE")
        .ok()
        .and_then(|f| std::fs::read_to_string(f).ok())
        .map(|t| {
            t.lines()
                .filter(|l| l.contains("**Fact:** [measured] "))
                .map(String::from)
                .collect()
        })
        .unwrap_or_default();
    let meta = s.bl_ok(&["meta", id]).unwrap_or_default();
    meta.lines()
        .filter_map(|l| l.strip_prefix("acceptance\t"))
        .filter(|c| {
            !facts
                .iter()
                .any(|f| f.starts_with(&format!("**Fact:** [measured] {c}")))
        })
        .map(String::from)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn missing_checks_applies_the_value_matrix() {
        let ok = "x; checks: test=pass, lint=na, review=pass";
        assert!(missing_checks(ok, &EXEC_CHECKS).is_empty());
        assert_eq!(
            missing_checks("x", &EXEC_CHECKS),
            ["test", "lint", "review"]
        );
        let na = "x; checks: test=na, lint=na, review=na";
        assert_eq!(missing_checks(na, &EXEC_CHECKS), ["review"]);
        let fail = "x; checks: test=fail, lint=pass, review=pass";
        assert_eq!(missing_checks(fail, &EXEC_CHECKS), ["test"]);
        let extra = "x; checks: test=pass, lint=pass, review=pass, other=skipped";
        assert!(missing_checks(extra, &EXEC_CHECKS).is_empty());
        let quoted = "a; checks: test=pass; built: y; checks: test=pass, lint=pass, review=pass";
        assert!(missing_checks(quoted, &EXEC_CHECKS).is_empty());
        assert_eq!(
            missing_checks("x; checks: plan-review=na", &PLAN_CHECKS),
            ["plan-review"]
        );
        assert!(missing_checks("x; checks: plan-review=pass", &PLAN_CHECKS).is_empty());
    }
}

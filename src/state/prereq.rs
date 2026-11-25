use super::store::{self, deps_json, entry_json, get, read_lines};
use super::{die, mkdir, write, S};
use crate::backlog::Fail;
use std::path::Path;

const MAX_FILED: usize = 3;
const CATEGORIES: [&str; 4] = ["feat", "fix", "chore", "refactor"];

fn idents_of(head: &str) -> Vec<String> {
    head.split('`')
        .skip(1)
        .step_by(2)
        .filter_map(|span| {
            let span = span.trim_end_matches("()");
            let tail = span.rsplit(|c: char| !(c.is_ascii_alphanumeric() || c == '_'));
            let id = tail
                .into_iter()
                .next()?
                .trim_start_matches(|c: char| c.is_ascii_digit());
            (!id.is_empty()).then(|| id.to_string())
        })
        .collect()
}

/// Identifiers of the `## Reach and reuse` bullets: `true` for a symbol the plan creates (`reuse:`), `false` for one it cites by `path:line`.
pub fn plan_symbols(text: &str) -> Vec<(String, bool)> {
    let mut out = Vec::new();
    let mut inside = false;
    for l in text.lines() {
        if let Some(h) = l.strip_prefix("## ") {
            inside = h.trim() == "Reach and reuse";
        } else if inside && l.starts_with("- `") {
            let head = l.split(" — ").next().unwrap_or(l);
            let new = l.contains("reuse:");
            let cited = l
                .as_bytes()
                .windows(2)
                .any(|w| w[0] == b':' && w[1].is_ascii_digit());
            if new || cited {
                out.extend(idents_of(head).into_iter().map(|i| (i, new)));
            }
        }
    }
    out
}

fn plan_text(s: &S, id: &str) -> String {
    s.task_plans(id)
        .split(',')
        .filter(|p| !p.is_empty())
        .map(|p| std::fs::read_to_string(s.root.join(Path::new(p))).unwrap_or_default())
        .collect::<Vec<_>>()
        .join("\n")
}

/// Revisions a plan symbol may live on: HEAD, the task's lane branch and every other lane branch.
fn revs(s: &S, id: &str) -> Vec<String> {
    let mut v = vec!["HEAD".to_string()];
    v.extend(Some(s.task_branch(id)).filter(|b| !b.is_empty()));
    v.extend(s.radin_branches());
    v
}

/// Existing symbols the plan cites that no revision holds. Empty when git cannot answer.
fn unmet(s: &S, id: &str, text: &str) -> Vec<String> {
    if !s.git_ok(&["rev-parse", "--verify", "-q", "HEAD"]) {
        return Vec::new();
    }
    let revs = revs(s, id);
    let mut out: Vec<String> = Vec::new();
    for (ident, new) in plan_symbols(text) {
        if new || ident.len() < 4 || out.contains(&ident) {
            continue;
        }
        if !revs.iter().any(|r| s.git_ok(&["grep", "-qwF", &ident, r])) {
            out.push(ident);
        }
    }
    out
}

/// Makes `dependent` wait on `dep` as a dependency block; the wait costs no attempt.
fn wait_on(s: &S, dependent: &str, dep: &str, note: &str) -> Result<(), Fail> {
    let entry = s.need_entry(dependent)?;
    let mut deps = s.live_deps(dependent, &entry);
    if !deps.split(',').any(|d| d == dep) {
        if !deps.is_empty() {
            deps.push(',');
        }
        deps.push_str(dep);
    }
    s.bl_must(&["set-deps", dependent, &deps], "")?;
    s.write_entry_as(dependent, "blocked", "dependency", 0, note, None)
}

/// Files a task for what `dependent` needs, in its epic and first in line; a `decision` blocks the new task. Returns the new id.
pub fn file(
    s: &S,
    dependent: &str,
    category: &str,
    title: &str,
    needs: &str,
    decision: &str,
) -> Result<String, Fail> {
    let rel = format!("prereq/{dependent}");
    let filed = s.read(&rel);
    if filed.lines().count() >= MAX_FILED {
        return Err(die(format!(
            "{dependent} already filed {MAX_FILED} prerequisites ({}); a human settles the next",
            filed.lines().collect::<Vec<_>>().join(", ")
        )));
    }
    let mut body = format!("Prerequisite of {dependent}.\n\n{needs}\n");
    if !decision.is_empty() {
        body.push_str(&format!("\n**Open decision:** {decision}\n"));
    }
    let epic = super::lanes::task_epic(s, dependent)?;
    let mut args = vec!["add", category, title, "--origin", dependent];
    if !epic.starts_with("hotfix-") {
        args.extend(["--epic", &epic]);
    }
    let id = s.bl_must(&args, &body)?.trim().to_string();
    if let Err(e) = wait_on(
        s,
        dependent,
        &id,
        &format!("waiting on prerequisite {id}: {title}"),
    ) {
        let _ = s.bl(&["remove", &id], "");
        return Err(e);
    }
    let (status, reason) = if decision.is_empty() {
        ("pending", "")
    } else {
        ("blocked", "decision")
    };
    store::append(
        &s.steps,
        &format!(
            "{}\n",
            entry_json(&id, 0, status, reason, &deps_json(""), 0, 0, decision)
        ),
    );
    mkdir(s, "prereq");
    write(s, &rel, &format!("{filed}{id}\n"));
    s.journal("prerequisite", dependent, &format!("{id} {title}"));
    Ok(id)
}

/// Another open task whose plan creates `ident`, linked as a dependency of `id`.
fn owner(s: &S, id: &str, ident: &str) -> Option<String> {
    for l in read_lines(&s.steps) {
        let other = get(&l, "id");
        if other == id
            || !matches!(
                get(&l, "status").as_str(),
                "pending" | "blocked" | "in_progress"
            )
        {
            continue;
        }
        let creates = plan_symbols(&plan_text(s, &other))
            .into_iter()
            .any(|(i, new)| new && i == ident);
        if creates
            && wait_on(
                s,
                id,
                &other,
                &format!("waiting on {other}: it adds {ident}"),
            )
            .is_ok()
        {
            return Some(other);
        }
    }
    None
}

/// Before dispatch: when the plan cites a symbol the tree lacks, waits on the task that adds it, else files one. Returns the block message.
pub fn guard(s: &S, id: &str) -> Result<Option<String>, Fail> {
    let text = plan_text(s, id);
    let missing = unmet(s, id, &text);
    if missing.is_empty() {
        return Ok(None);
    }
    for ident in &missing {
        if let Some(o) = owner(s, id, ident) {
            return Ok(Some(format!("waits on {o}, which adds {ident}")));
        }
    }
    let list = missing
        .iter()
        .take(3)
        .cloned()
        .collect::<Vec<_>>()
        .join(", ");
    let needs = format!(
        "Plan {} names symbols the tree lacks: {}. Checked HEAD, the task's lane branch and every radin/* branch.",
        s.task_plans(id),
        missing.join(", ")
    );
    match file(
        s,
        id,
        "feat",
        &format!("Add {list} that task {id} needs"),
        &needs,
        "",
    ) {
        Ok(new) => Ok(Some(format!(
            "waits on new prerequisite {new}: plan names {list}, which the tree lacks"
        ))),
        Err(e) => {
            let note = e.msg.trim().to_string();
            s.set_blocked(id, "fact", &note)?;
            Ok(Some(note))
        }
    }
}

/// Splits a leaf line detail into category, title, needs and decision.
pub fn parse_line(detail: &str) -> (String, String, String, String) {
    let (rest, decision) = detail
        .split_once("; decision:")
        .map_or((detail, ""), |(a, b)| (a, b.trim()));
    let (head, needs) = rest
        .split_once("; needs:")
        .map_or((rest, rest), |(a, b)| (a, b.trim()));
    let head = head.trim();
    let (cat, title) = head
        .split_once(": ")
        .filter(|(c, _)| CATEGORIES.contains(c))
        .map_or(("feat", head), |(c, t)| (c, t.trim()));
    (cat.into(), title.into(), needs.into(), decision.into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plan_symbols_reads_cited_and_new_bullets() {
        let t = "## Changes\n- `ignored` — src/x.rs:1\n## Reach and reuse\n\nprose `skip`\n- `Seed.rollSeason()` — `src/seed.rs:9` → in Changes\n- `abc` — src/a.rs:2\n- `no_cite` — nothing here\n- `fresh_fn` — reuse: none — searched x; sibling: `src/y.rs:3`\n## Order\n- `late` — src/z.rs:1\n";
        assert_eq!(
            plan_symbols(t),
            vec![
                ("rollSeason".to_string(), false),
                ("abc".to_string(), false),
                ("fresh_fn".to_string(), true)
            ]
        );
    }

    #[test]
    fn parse_line_defaults_category_and_splits_decision() {
        let (c, t, n, d) = parse_line(
            "fix: add rollSeason; needs: Seed.rollSeason in src/seed.rs; decision: which? a or b",
        );
        assert_eq!(
            (c.as_str(), t.as_str(), n.as_str(), d.as_str()),
            (
                "fix",
                "add rollSeason",
                "Seed.rollSeason in src/seed.rs",
                "which? a or b"
            )
        );
        let (c, t, n, d) = parse_line("Add a thing");
        assert_eq!(
            (c.as_str(), t.as_str(), n.as_str(), d.as_str()),
            ("feat", "Add a thing", "Add a thing", "")
        );
    }
}

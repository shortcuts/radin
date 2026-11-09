use super::index::slugify;
use super::order::ambiguous;
use super::{arg, die, usage_die, Ctx, Io, R};
use std::collections::{HashMap, HashSet};
use std::fmt::Write as _;
use std::fs;

const PLAN_SECTIONS: &str = "Outcome|Decisions|Alternatives rejected|Changes|Reach and reuse|Rubrics triggered|Modes and states|Order|Testing|Risks|Out of scope";

fn blank(l: &str) -> bool {
    l.trim_matches([' ', '\t']).is_empty()
}

fn bullet_path(l: &str) -> Option<&str> {
    let rest = l.strip_prefix("- `")?;
    let (p, _) = rest.split_once('`')?;
    (!p.is_empty()).then_some(p)
}

pub fn lint(text: &str) -> Vec<String> {
    let mut out = vec![];
    let (mut fence, mut sec, mut got) = (false, String::new(), vec![]);
    let mut body: HashMap<String, u32> = HashMap::new();
    let (mut chg, mut seen_you, mut nchg, mut boxes) = (String::new(), false, 0, 0);
    let close = |chg: &mut String, seen: bool, out: &mut Vec<String>| {
        if !chg.is_empty() && !seen {
            out.push(format!("changes: `{chg}` has no You see: line"));
        }
        chg.clear();
    };
    for l in text.lines() {
        if l.starts_with("```") {
            fence = !fence;
            continue;
        }
        if fence {
            continue;
        }
        if let Some(h) = l.strip_prefix("## ") {
            close(&mut chg, seen_you, &mut out);
            sec = h.trim_end_matches([' ', '\t']).to_string();
            got.push(sec.clone());
            body.insert(sec.clone(), 0);
            continue;
        }
        if !sec.is_empty() && !blank(l) {
            *body.entry(sec.clone()).or_default() += 1;
        }
        if sec == "Changes" {
            if let Some(p) = bullet_path(l) {
                close(&mut chg, seen_you, &mut out);
                chg = p.to_string();
                seen_you = false;
                nchg += 1;
            }
            let rest = l.trim_start_matches([' ', '\t']);
            if rest.len() < l.len() && rest.starts_with("You see: ") {
                seen_you = true;
            }
        }
        if sec == "Testing" && l.starts_with("- [ ] ") {
            boxes += 1;
        }
    }
    close(&mut chg, seen_you, &mut out);
    let mut i = 0;
    for want in PLAN_SECTIONS.split('|') {
        match got.iter().skip(i).position(|g| g == want) {
            None => out.push(format!("missing or out of order: ## {want}")),
            Some(off) => {
                i += off;
                if body[want] == 0 {
                    out.push(format!("empty: ## {want} (write n/a: <reason>)"));
                }
            }
        }
    }
    if nchg == 0 {
        out.push("changes: no `path` entry".into());
    }
    if boxes == 0 {
        out.push("testing: no - [ ] check box".into());
    }
    out
}

fn changes_of(text: &str) -> Vec<String> {
    let (mut fence, mut inchg, mut out) = (false, false, vec![]);
    for l in text.lines() {
        if l.starts_with("```") {
            fence = !fence;
        } else if fence {
        } else if l.starts_with("## ") {
            inchg = l.trim_end_matches([' ', '\t']) == "## Changes";
        } else if inchg {
            out.extend(bullet_path(l).map(str::to_string));
        }
    }
    out
}

pub fn plan_lint(cx: &Ctx, a: &[String], io: &mut Io) -> R {
    let p = cx.env.cwd.join(arg(a, 0));
    if arg(a, 0).is_empty() || !p.is_file() {
        return Err(usage_die("plan-lint", "plan-lint needs a plan file"));
    }
    let defects = lint(&fs::read_to_string(p).unwrap_or_default());
    defects
        .iter()
        .for_each(|d| io.out.push_str(&format!("{d}\n")));
    Ok(i32::from(!defects.is_empty()))
}

pub fn files(cx: &Ctx, a: &[String], io: &mut Io) -> R {
    let q = arg(a, 0);
    if q.is_empty() {
        return Err(usage_die("files", "files needs an id, title or plan file"));
    }
    if a.len() > 1 {
        return Err(usage_die(
            "files",
            &format!("files takes one id, title or plan file, got: {}", a[1]),
        ));
    }
    let direct = cx.env.cwd.join(q);
    let mut paths = vec![];
    if direct.is_file() {
        paths = changes_of(&fs::read_to_string(direct).unwrap_or_default());
    } else {
        let idx = cx.require()?;
        for pf in idx.entries[idx.single(q)?].arr("plan") {
            match fs::read_to_string(cx.env.cwd.join(&pf)) {
                Ok(t) => paths.extend(changes_of(&t)),
                Err(_) => io
                    .err
                    .push_str(&format!("radin-backlog: plan file not found: {pf}\n")),
            }
        }
    }
    let mut seen = HashSet::new();
    paths.retain(|p| !blank(p) && seen.insert(p.clone()));
    paths
        .iter()
        .for_each(|p| io.out.push_str(&format!("{p}\n")));
    Ok(i32::from(paths.is_empty()))
}

pub fn plan_target(cx: &Ctx, a: &[String], io: &mut Io) -> R {
    let q = arg(a, 0);
    if q.is_empty() {
        return Err(usage_die("plan-target", "plan-target needs an id or title"));
    }
    if a.len() > 2 {
        return Err(usage_die(
            "plan-target",
            &format!(
                "plan-target takes an id or title and at most one sub-task title, got: {}",
                a[2]
            ),
        ));
    }
    let idx = cx.require()?;
    let hits = idx.matches(q);
    match hits.as_slice() {
        [] => return Err(die(format!("no entry matches: {q}"))),
        [_] => {}
        _ => return Err(ambiguous(&idx, &hits, q)),
    }
    let e = &idx.entries[hits[0]];
    let (id, sub) = (e.id(), slugify(arg(a, 1)));
    let name = if sub.is_empty() {
        id.clone()
    } else {
        format!("{id}-{sub}")
    };
    let _ = write!(
        io.out,
        "id\t{id}\ntitle\t{}\ntask_file\t{}\nplan_file\t{}\n",
        e.title(),
        idx.entry_path(e).display(),
        cx.ns
            .namespace_dir
            .join("plans")
            .join(format!("{name}.md"))
            .display()
    );
    let meta = e.meta_lines();
    for l in meta.iter().filter(|l| l.starts_with("facts\t")) {
        let _ = writeln!(io.out, "{l}");
    }
    let plans: Vec<_> = meta.iter().filter(|l| l.starts_with("plan\t")).collect();
    plans.iter().for_each(|l| {
        let _ = writeln!(io.out, "{l}");
    });
    Ok(if plans.is_empty() { 0 } else { 3 })
}

pub fn open_decisions(cx: &Ctx, a: &[String], io: &mut Io) -> R {
    if arg(a, 0).is_empty() {
        return Err(usage_die(
            "open-decisions",
            "open-decisions needs an id or title",
        ));
    }
    let idx = cx.require()?;
    let p = idx.entry_path(&idx.entries[idx.single(&a[0])?]);
    let text = fs::read_to_string(&p).map_err(|_| die(format!("cannot read {}", p.display())))?;
    let mut open: Vec<&str> = vec![];
    for l in text.lines() {
        if l.starts_with("**Decision:**") {
            open.clear();
        } else if let Some(q) = l.strip_prefix("**Open decision:**") {
            open.push(q.strip_prefix(' ').unwrap_or(q));
        }
    }
    open.iter().for_each(|q| io.out.push_str(&format!("{q}\n")));
    Ok(i32::from(open.is_empty()))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn plan(parts: &[&str]) -> String {
        parts.join("\n") + "\n"
    }

    const FULL: [&str; 20] = [
        "## Outcome",
        "x",
        "## Decisions",
        "n/a",
        "## Alternatives rejected",
        "n/a",
        "## Changes",
        "- `a.txt` - edit",
        "  You see: a",
        "## Reach and reuse",
        "n/a",
        "## Rubrics triggered",
        "n/a",
        "## Modes and states",
        "n/a",
        "## Order",
        "n/a",
        "## Testing",
        "- [ ] run it",
        "## Risks",
    ];

    fn complete() -> String {
        plan(&[&FULL[..], &["n/a", "## Out of scope", "n/a"]].concat())
    }

    #[test]
    fn a_complete_plan_has_no_defect() {
        assert_eq!(lint(&complete()), Vec::<String>::new());
    }

    #[test]
    fn only_outcome_misses_every_later_section() {
        let d = lint("## Outcome\nonly this\n");
        assert_eq!(d[0], "missing or out of order: ## Decisions");
        assert!(d.contains(&"changes: no `path` entry".to_string()));
        assert!(d.contains(&"testing: no - [ ] check box".to_string()));
    }

    #[test]
    fn a_change_without_you_see_is_named() {
        let t = complete().replace("  You see: a\n", "");
        assert_eq!(lint(&t), vec!["changes: `a.txt` has no You see: line"]);
    }

    #[test]
    fn an_empty_section_and_a_missing_box_are_named() {
        let t = complete()
            .replace("## Risks\nn/a\n", "## Risks\n")
            .replace("- [ ] run it", "- run it");
        assert_eq!(
            lint(&t),
            vec![
                "empty: ## Risks (write n/a: <reason>)".to_string(),
                "testing: no - [ ] check box".to_string()
            ]
        );
    }

    #[test]
    fn fenced_lines_never_count() {
        let t = complete().replace("## Order\nn/a", "## Order\n```\n## Changes\n```\nn/a");
        assert!(lint(&t).is_empty());
    }

    #[test]
    fn changes_of_skips_fences_nesting_and_other_sections() {
        let t = "## Outcome\n- `no`\n## Changes\n- `a` - x\n  - `nested`\n```\n- `fence`\n```\n- `b` - y\n## Order\n- `late`\n";
        assert_eq!(changes_of(t), vec!["a", "b"]);
    }
}

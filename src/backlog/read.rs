use super::epic::epic_deps;
use super::index::{epic_of, Entry, Index, CATEGORIES};
use super::{arg, die, usage_die, Ctx, Env, Io, R};
use std::fmt::Write as _;
use std::fs;
use std::path::PathBuf;

const US: &str = "\x1f";

fn nonempty(p: &std::path::Path) -> bool {
    fs::metadata(p).is_ok_and(|m| m.len() > 0)
}

fn bash_q(s: &str) -> String {
    if s.is_empty() {
        return "''".into();
    }
    if s.chars().any(char::is_control) {
        let mut o = String::from("$'");
        for c in s.chars() {
            match c {
                '\t' => o.push_str("\\t"),
                '\n' => o.push_str("\\n"),
                '\r' => o.push_str("\\r"),
                '\'' | '\\' => {
                    o.push('\\');
                    o.push(c);
                }
                c if c.is_control() => {
                    let _ = write!(o, "\\{:03o}", c as u32);
                }
                c => o.push(c),
            }
        }
        o.push('\'');
        return o;
    }
    let mut o = String::new();
    for c in s.chars() {
        if !(c.is_ascii_alphanumeric() || "_/.:@%+=~-".contains(c) || !c.is_ascii()) {
            o.push('\\');
        }
        o.push(c);
    }
    o
}

pub fn env(cx: &Ctx, a: &[String], io: &mut Io) -> R {
    match arg(a, 0) {
        "" | "--export" => {}
        v => {
            return Err(usage_die(
                "env",
                &format!("env takes only --export, got: {v}"),
            ))
        }
    }
    if a.len() > 1 {
        return Err(usage_die(
            "env",
            &format!("env takes at most one argument, got: {}", a[1]),
        ));
    }
    let prefix = if a.is_empty() { "" } else { "export " };
    let ns = cx.ns;
    for (k, v) in [
        ("REPO_ROOT", &ns.repo_root),
        ("NAMESPACE_DIR", &ns.namespace_dir),
        ("BACKLOG_INDEX", &ns.backlog_index),
        ("BACKLOG_TASKS_DIR", &ns.backlog_tasks_dir),
    ] {
        let _ = writeln!(io.out, "{prefix}{k}={}", bash_q(&v.to_string_lossy()));
    }
    Ok(0)
}

fn read_task(idx: &Index, e: &Entry) -> Result<String, super::Fail> {
    let p = idx.entry_path(e);
    fs::read_to_string(&p).map_err(|_| die(format!("cannot read {}", p.display())))
}

pub fn show(cx: &Ctx, a: &[String], io: &mut Io) -> R {
    let idx = cx.require()?;
    let cat = arg(a, 0);
    if !cat.is_empty() && !CATEGORIES.contains(&cat) {
        return Err(usage_die(
            "show",
            &format!("category must be feat|fix|chore|refactor, got: {cat}"),
        ));
    }
    if a.len() > 1 {
        return Err(usage_die(
            "show",
            &format!("show takes at most one category, got: {}", a[1]),
        ));
    }
    io.out.push_str("# Backlog\n");
    let cats: Vec<&str> = if cat.is_empty() {
        CATEGORIES.to_vec()
    } else {
        vec![cat]
    };
    for c in cats {
        let mut section: Vec<&Entry> = idx
            .entries
            .iter()
            .filter(|e| e.str("category") == c)
            .collect();
        if section.is_empty() {
            continue;
        }
        section.sort_by_key(|e| e.epic());
        let edeps = epic_deps(&cx.ns.backlog_tasks_dir);
        let _ = write!(io.out, "\n## {c}\n");
        let mut cur = String::new();
        for e in section {
            let epic = e.epic();
            if epic != cur {
                let _ = write!(io.out, "\n### epic: {epic}\n");
                if let Some(d) = edeps.get(&epic) {
                    let _ = writeln!(io.out, "depends on epics: {}", d.join(", "));
                }
                let desc = cx.ns.backlog_tasks_dir.join(&epic).join("DESCRIPTION.md");
                if nonempty(&desc) {
                    io.out
                        .push_str(&fs::read_to_string(desc).unwrap_or_default());
                }
                cur = epic;
            }
            let level = if cur.is_empty() { "###" } else { "####" };
            let _ = write!(io.out, "\n{level} {}\n", e.title());
            for l in e.meta_lines() {
                let _ = writeln!(io.out, "{l}");
            }
            let body = read_task(&idx, e)?;
            io.out.push_str(&body);
        }
    }
    Ok(0)
}

pub fn list(cx: &Ctx, a: &[String], io: &mut Io) -> R {
    let idx = cx.require()?;
    let (mut planned, mut meta, mut created, mut unset, mut order) =
        (false, false, false, false, "priority");
    let mut i = 0;
    while i < a.len() {
        match a[i].as_str() {
            "--order" => {
                order = match arg(a, i + 1) {
                    "created" => "created",
                    "priority" => "priority",
                    v => {
                        let v = if v.is_empty() { "<none>" } else { v };
                        return Err(usage_die(
                            "list",
                            &format!("--order must be created|priority, got: {v}"),
                        ));
                    }
                };
                i += 2;
                continue;
            }
            "--planned" => planned = true,
            "--meta" => meta = true,
            "--created" => created = true,
            "--unset-priority" => unset = true,
            o => return Err(usage_die("list", &format!("unknown list option: {o}"))),
        }
        i += 1;
    }
    let mut rows: Vec<&Entry> = idx
        .entries
        .iter()
        .filter(|e| !unset || e.priority().is_none())
        .collect();
    if order == "priority" {
        let key = |e: &Entry| e.priority().map(|p| p.parse::<f64>().unwrap_or(0.0));
        rows.sort_by(|x, y| match (key(x), key(y)) {
            (Some(p), Some(q)) => q.total_cmp(&p),
            (a, b) => a.is_none().cmp(&b.is_none()),
        });
    }
    for e in rows {
        let mut row = e.row(US);
        if planned {
            row.push_str(US);
            if e.has("plan") {
                row.push('P');
            }
        }
        if meta {
            let _ = write!(row, "{US}{}", e.meta_lines().join("\x1e"));
        }
        if created {
            let _ = write!(row, "{US}{}", e.str("created"));
        }
        let _ = writeln!(io.out, "{row}");
    }
    Ok(0)
}

pub fn borrowed_index(cx: &Ctx) -> PathBuf {
    let own = cx.ns.backlog_index.clone();
    let (d, c) = (&cx.ns.git_dir, &cx.ns.git_common_dir);
    let main = PathBuf::from(format!(
        "{}/.radin/backlog/index.jsonl",
        c.strip_suffix("/.git").unwrap_or(c)
    ));
    if nonempty(&own) || d == c || !nonempty(&main) {
        own
    } else {
        main
    }
}

pub fn find(cx: &Ctx, a: &[String], io: &mut Io) -> R {
    if arg(a, 0).is_empty() {
        return Err(usage_die("find", "find needs an id or title"));
    }
    let idx = Index::require(borrowed_index(cx))?;
    let hits = idx.matches(&a[0]);
    if hits.is_empty() {
        return Err(die(format!("no entry matches: {}", a[0])));
    }
    io.out.push_str(&idx.rows(&hits, ""));
    Ok(0)
}

pub fn count(cx: &Ctx, a: &[String], io: &mut Io) -> R {
    if !a.is_empty() {
        return Err(usage_die(
            "count",
            &format!("count takes no argument, got: {}", a[0]),
        ));
    }
    let text = fs::read_to_string(&cx.ns.backlog_index).unwrap_or_default();
    let _ = writeln!(io.out, "{}", text.lines().filter(|l| !l.is_empty()).count());
    Ok(0)
}

pub fn meta(cx: &Ctx, a: &[String], io: &mut Io) -> R {
    if arg(a, 0).is_empty() {
        return Err(usage_die("meta", "meta needs an id or title"));
    }
    let idx = cx.require()?;
    let e = &idx.entries[idx.single(&a[0])?];
    for l in e.meta_lines() {
        let _ = writeln!(io.out, "{l}");
    }
    Ok(0)
}

fn skill_token(inst: &str) -> &str {
    let Some((_, rest)) = inst.split_once('/') else {
        return "";
    };
    let end = rest
        .find(|c: char| !(c.is_ascii_lowercase() || c.is_ascii_digit() || ":_-".contains(c)))
        .unwrap_or(rest.len());
    &rest[..end]
}

fn skill_denied(env: &Env, repo_root: &std::path::Path, inst: &str) -> bool {
    let name = skill_token(inst);
    if name.is_empty() {
        return false;
    }
    let host = |n: &str| env.host.skill_name(n).unwrap_or_default();
    let (g, r) = (host("grilling"), host("research"));
    let fixed = ["deep-research", "radin-batch", "radin-plan", "radin-review"];
    let flow = |base: &std::path::Path| base.join(".claude/workflows").join(format!("{name}.md"));
    name == g.trim_start_matches('/')
        || name == r.trim_start_matches('/')
        || fixed.contains(&name)
        || flow(repo_root).is_file()
        || flow(&env.home).is_file()
}

pub fn field(cx: &Ctx, a: &[String], io: &mut Io) -> R {
    let (query, name) = (arg(a, 0), arg(a, 1));
    if name.is_empty() {
        return Err(usage_die(
            "field",
            "field needs an id or title and a placeholder name",
        ));
    }
    let idx = Index::require(borrowed_index(cx))?;
    let e = &idx.entries[idx.single(query)?];
    let line = |io: &mut Io, s: &str| {
        let _ = writeln!(io.out, "{s}");
    };
    match name {
        "TASK_ID" => line(io, &e.id()),
        "CATEGORY" => line(io, &e.str("category")),
        "TASK_FILE" => line(io, &idx.entry_path(e).to_string_lossy()),
        "TASK_BODY" => {
            let p = idx.entry_path(e);
            if !nonempty(&p) {
                return Ok(1);
            }
            io.out
                .push_str(&fs::read_to_string(p).map_err(|e| die(e.to_string()))?);
        }
        "EPIC_CONTEXT" => {
            let p = cx
                .ns
                .backlog_tasks_dir
                .join(epic_of(&e.file()))
                .join("DESCRIPTION.md");
            if e.epic().is_empty() || !nonempty(&p) {
                return Ok(1);
            }
            io.out
                .push_str(&fs::read_to_string(p).map_err(|e| die(e.to_string()))?);
        }
        "FACTS" | "LOCATION" | "PLANNING" | "COMPLEXITY" => {
            let v = e.str(&name.to_ascii_lowercase());
            if v.is_empty() {
                return Ok(1);
            }
            line(io, &v);
        }
        "PLAN_PATHS" => {
            let plans = e.arr("plan");
            if plans.is_empty() {
                line(io, "none — implement directly from the entry");
                return Ok(1);
            }
            line(io, &plans.join(", "));
        }
        "SKILLS" | "SKILLS_DROPPED" => {
            let (dropped, kept): (Vec<_>, Vec<_>) = e
                .arr("skills")
                .into_iter()
                .partition(|s| skill_denied(cx.env, &cx.ns.repo_root, s));
            let (list, none) = if name == "SKILLS" {
                (kept, "none")
            } else {
                (dropped, "")
            };
            if list.is_empty() {
                if none.is_empty() {
                    return Ok(1);
                }
                line(io, none);
            }
            list.iter().for_each(|s| line(io, s));
        }
        "ACCEPTANCE" => {
            let crits = e.arr("acceptance");
            if crits.is_empty() {
                return Ok(1);
            }
            line(
                io,
                "1b. This task states its own acceptance criteria. They are the bar it is",
            );
            line(io, "   measured against, so satisfy every one of them:");
            crits.iter().for_each(|c| line(io, &format!("   - {c}")));
        }
        _ => return Err(usage_die("field", &format!("unknown field name: {name}"))),
    }
    Ok(0)
}

pub fn duplicates(cx: &Ctx, a: &[String], io: &mut Io) -> R {
    let idx = cx.require()?;
    if !a.is_empty() {
        return Err(usage_die(
            "duplicates",
            &format!("duplicates takes no argument, got: {}", a[0]),
        ));
    }
    let mut hit = false;
    for (kind, f) in [
        ("id", Entry::id as fn(&Entry) -> String),
        ("title", Entry::title),
    ] {
        let mut groups: Vec<(String, Vec<String>)> = vec![];
        for e in &idx.entries {
            let v = f(e);
            match groups.iter_mut().find(|(k, _)| *k == v) {
                Some((_, ids)) => ids.push(e.id()),
                None => groups.push((v, vec![e.id()])),
            }
        }
        for (v, ids) in groups.iter().filter(|(_, ids)| ids.len() > 1) {
            hit = true;
            let _ = writeln!(io.out, "{kind}\t{v}\t{}", ids.join(","));
        }
    }
    Ok(i32::from(!hit))
}

pub fn stamps(cx: &Ctx, a: &[String], io: &mut Io) -> R {
    if a.len() > 1 {
        return Err(usage_die(
            "stamps",
            &format!("stamps takes at most one branch, got: {}", a[1]),
        ));
    }
    if !nonempty(&cx.ns.backlog_index) {
        return Ok(0);
    }
    let idx = Index::load(cx.ns.backlog_index.clone())?;
    let want = arg(a, 0);
    for e in &idx.entries {
        let b = e.str("branch");
        if want.is_empty() || b == want {
            let _ = writeln!(io.out, "{}\t{}\t{b}", e.id(), e.str("created"));
        }
    }
    Ok(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bash_q_follows_bash_3_2() {
        for (i, o) in [
            ("", "''"),
            ("/a/b-c_d.e", "/a/b-c_d.e"),
            ("a b", "a\\ b"),
            ("it's", "it\\'s"),
            ("a,b^c", "a\\,b\\^c"),
            ("é", "é"),
            ("a\tb", "$'a\\tb'"),
            ("a\nb c", "$'a\\nb c'"),
            ("\x01", "$'\\001'"),
        ] {
            assert_eq!(bash_q(i), o, "{i:?}");
        }
    }

    #[test]
    fn skill_token_reads_the_first_slash_name() {
        assert_eq!(
            skill_token("Invoke /mattpocock-skills:grilling to tackle this task."),
            "mattpocock-skills:grilling"
        );
        assert_eq!(skill_token("Invoke grilling"), "");
        assert_eq!(skill_token("see /a_b-9 now"), "a_b-9");
    }
}

use super::index::{epic_of, slugify, Index};
use super::{arg, die, usage_die, Ctx, Io, R};
use serde_json::Value;
use std::collections::HashMap;
use std::fs;
use std::path::Path;

fn is_empty_epic(dir: &Path) -> bool {
    !fs::read_dir(dir).is_ok_and(|rd| {
        rd.flatten().any(|e| {
            let n = e.file_name().to_string_lossy().into_owned();
            n.ends_with(".md") && n != "DESCRIPTION.md"
        })
    })
}

pub fn prune_empty_epic(tasks: &Path, epic: &str) {
    let dir = tasks.join(epic);
    if !epic.is_empty() && dir.is_dir() && is_empty_epic(&dir) {
        let _ = fs::remove_file(dir.join("DESCRIPTION.md"));
        let _ = fs::remove_file(dir.join(DEPS_FILE));
        let _ = fs::remove_dir(&dir);
        scrub_epic(tasks, epic);
    }
}

fn require_epic_id(cx: &Ctx, id: &str) -> Result<(), super::Fail> {
    if slugify(id) != id {
        return Err(die(format!(
            "epic id must be a slug (lowercase, dashes), got: {id}"
        )));
    }
    if !cx.ns.backlog_tasks_dir.join(id).is_dir() {
        return Err(die(format!("no such epic: {id}")));
    }
    Ok(())
}

pub fn epics(cx: &Ctx, a: &[String], io: &mut Io) -> R {
    if !a.is_empty() {
        return Err(usage_die(
            "epics",
            &format!("epics takes no argument, got: {}", a[0]),
        ));
    }
    let mut names: Vec<String> = fs::read_dir(&cx.ns.backlog_tasks_dir)
        .into_iter()
        .flatten()
        .flatten()
        .filter(|e| e.path().is_dir())
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .filter(|n| !n.starts_with('.'))
        .collect();
    names.sort();
    names
        .iter()
        .for_each(|n| io.out.push_str(&format!("{n}\n")));
    Ok(0)
}

pub fn epic_add(cx: &Ctx, a: &[String], io: &mut Io) -> R {
    let epic = arg(a, 0);
    if epic.is_empty() {
        return Err(usage_die(
            "epic-add",
            "epic-add needs an epic id, with the description on stdin",
        ));
    }
    if slugify(epic) != epic {
        return Err(die(format!(
            "epic id must be a slug (lowercase, dashes), got: {epic}"
        )));
    }
    let dir = cx.ns.backlog_tasks_dir.join(epic);
    if dir.is_dir() {
        return Err(die(format!("epic already exists: {epic}")));
    }
    if Index::load(cx.ns.backlog_index.clone())?.has_id(epic) {
        return Err(die(format!("a task already uses that id: {epic}")));
    }
    fs::create_dir_all(&dir)
        .and_then(|()| fs::write(dir.join("DESCRIPTION.md"), cx.body()))
        .map_err(|e| die(e.to_string()))?;
    io.out.push_str(&format!("created epic {epic}\n"));
    Ok(0)
}

pub fn epic_set(cx: &Ctx, a: &[String], io: &mut Io) -> R {
    let epic = arg(a, 0);
    if epic.is_empty() {
        return Err(usage_die(
            "epic-set",
            "epic-set needs an epic id, with the new description on stdin",
        ));
    }
    require_epic_id(cx, epic)?;
    fs::write(
        cx.ns.backlog_tasks_dir.join(epic).join("DESCRIPTION.md"),
        cx.body(),
    )
    .map_err(|e| die(e.to_string()))?;
    io.out.push_str(&format!("updated epic {epic}\n"));
    Ok(0)
}

pub fn epic_show(cx: &Ctx, a: &[String], io: &mut Io) -> R {
    let epic = arg(a, 0);
    if epic.is_empty() {
        return Err(usage_die("epic-show", "epic-show needs an epic id"));
    }
    require_epic_id(cx, epic)?;
    io.out.push_str(
        &fs::read_to_string(cx.ns.backlog_tasks_dir.join(epic).join("DESCRIPTION.md"))
            .unwrap_or_default(),
    );
    Ok(0)
}

pub fn epic_move(cx: &Ctx, a: &[String], io: &mut Io) -> R {
    let (q, target) = (arg(a, 0), arg(a, 1));
    if target.is_empty() {
        return Err(usage_die(
            "epic-move",
            "epic-move needs an id or title and an epic id or --none",
        ));
    }
    let mut idx = cx.require()?;
    let i = idx.single(q)?;
    let id = idx.entries[i].id();
    let old = idx.entries[i].file();
    let new = if target == "--none" {
        format!("tasks/{id}.md")
    } else {
        require_epic_id(cx, target)?;
        format!("tasks/{target}/{id}.md")
    };
    if old == new {
        return Err(die(format!("already there: {old}")));
    }
    let mut moved = Index {
        path: idx.path.clone(),
        entries: idx.entries.clone(),
    };
    moved.entries[i].set("file", Some(Value::String(new.clone())));
    if tasks_cyclic(&moved, &epic_deps(&cx.ns.backlog_tasks_dir)) {
        return Err(die(format!("epic-move would create a cycle through {id}")));
    }
    fs::rename(idx.task_path(&old), idx.task_path(&new))
        .map_err(|e| die(format!("cannot move {old} to {new}: {e}")))?;
    idx.entries[i].set("file", Some(Value::String(new.clone())));
    idx.write()?;
    prune_empty_epic(&cx.ns.backlog_tasks_dir, &epic_of(&old));
    io.out.push_str(&format!("moved {id} to {new}\n"));
    Ok(0)
}

pub fn epic_remove(cx: &Ctx, a: &[String], io: &mut Io) -> R {
    let epic = arg(a, 0);
    if epic.is_empty() {
        return Err(usage_die("epic-remove", "epic-remove needs an epic id"));
    }
    require_epic_id(cx, epic)?;
    let dir = cx.ns.backlog_tasks_dir.join(epic);
    if !is_empty_epic(&dir) {
        return Err(die(format!(
            "epic {epic} still holds child tasks; epic-move them out first"
        )));
    }
    let _ = fs::remove_file(dir.join("DESCRIPTION.md"));
    let _ = fs::remove_file(dir.join(DEPS_FILE));
    fs::remove_dir(&dir).map_err(|e| die(e.to_string()))?;
    scrub_epic(&cx.ns.backlog_tasks_dir, epic);
    io.out.push_str(&format!("removed epic {epic}\n"));
    Ok(0)
}

const DEPS_FILE: &str = "DEPENDS_ON";

fn stored_deps(tasks: &Path, epic: &str) -> Vec<String> {
    fs::read_to_string(tasks.join(epic).join(DEPS_FILE))
        .unwrap_or_default()
        .lines()
        .map(str::trim)
        .filter(|d| !d.is_empty())
        .map(String::from)
        .collect()
}

fn epic_names(tasks: &Path) -> Vec<String> {
    fs::read_dir(tasks)
        .into_iter()
        .flatten()
        .flatten()
        .filter(|e| e.path().is_dir())
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .collect()
}

/// Epic id to the epics it depends on, keeping only edges between existing epics.
pub fn epic_deps(tasks: &Path) -> HashMap<String, Vec<String>> {
    epic_names(tasks)
        .into_iter()
        .filter_map(|epic| {
            let deps: Vec<String> = stored_deps(tasks, &epic)
                .into_iter()
                .filter(|d| *d != epic && tasks.join(d).is_dir())
                .collect();
            (!deps.is_empty()).then_some((epic, deps))
        })
        .collect()
}

fn write_epic_deps(tasks: &Path, epic: &str, deps: &[String]) -> std::io::Result<()> {
    let p = tasks.join(epic).join(DEPS_FILE);
    if deps.is_empty() {
        return fs::remove_file(&p).or_else(|e| match e.kind() {
            std::io::ErrorKind::NotFound => Ok(()),
            _ => Err(e),
        });
    }
    fs::write(p, deps.iter().map(|d| format!("{d}\n")).collect::<String>())
}

/// Drops the edges that point at a removed epic, so a later epic of the same name starts with no dependents.
fn scrub_epic(tasks: &Path, epic: &str) {
    for from in epic_names(tasks) {
        let deps = stored_deps(tasks, &from);
        if deps.iter().any(|d| d == epic) {
            let kept: Vec<String> = deps.into_iter().filter(|d| d != epic).collect();
            let _ = write_epic_deps(tasks, &from, &kept);
        }
    }
}

/// Every task's effective dependencies: its own `depends_on`, then each task of every epic its epic depends on.
pub fn task_graph(idx: &Index, edeps: &HashMap<String, Vec<String>>) -> Vec<(String, Vec<String>)> {
    let mut by_epic: HashMap<String, Vec<String>> = HashMap::new();
    for e in &idx.entries {
        by_epic.entry(e.epic()).or_default().push(e.id());
    }
    idx.entries
        .iter()
        .map(|e| {
            let mut d = e.depends_on();
            for dep_epic in edeps.get(&e.epic()).into_iter().flatten() {
                for t in by_epic.get(dep_epic).into_iter().flatten() {
                    if !d.contains(t) {
                        d.push(t.clone());
                    }
                }
            }
            (e.id(), d)
        })
        .collect()
}

pub fn cyclic(g: &HashMap<String, Vec<String>>) -> bool {
    fn visit(v: &str, g: &HashMap<String, Vec<String>>, st: &mut HashMap<String, u8>) -> bool {
        match st.get(v) {
            Some(1) => return true,
            Some(_) => return false,
            None => {}
        }
        st.insert(v.into(), 1);
        if g.get(v).into_iter().flatten().any(|d| visit(d, g, st)) {
            return true;
        }
        st.insert(v.into(), 2);
        false
    }
    let mut st = HashMap::new();
    g.keys().any(|k| visit(k, g, &mut st))
}

pub fn tasks_cyclic(idx: &Index, edeps: &HashMap<String, Vec<String>>) -> bool {
    cyclic(&task_graph(idx, edeps).into_iter().collect())
}

pub fn epic_set_deps(cx: &Ctx, a: &[String], io: &mut Io) -> R {
    let (epic, v) = (arg(a, 0), arg(a, 1));
    if v.is_empty() {
        return Err(usage_die(
            "epic-set-deps",
            "epic-set-deps needs an epic id and a csv of epic ids or --none",
        ));
    }
    require_epic_id(cx, epic)?;
    let tasks = &cx.ns.backlog_tasks_dir;
    let mut deps: Vec<String> = vec![];
    if v != "--none" {
        for d in v.split(',').map(str::trim).filter(|d| !d.is_empty()) {
            require_epic_id(cx, d)?;
            if !deps.iter().any(|x| x == d) {
                deps.push(d.to_string());
            }
        }
        let mut edeps = epic_deps(tasks);
        if deps.iter().any(|d| d == epic) || {
            edeps.insert(epic.to_string(), deps.clone());
            cyclic(&edeps) || tasks_cyclic(&Index::load(cx.ns.backlog_index.clone())?, &edeps)
        } {
            return Err(die(format!(
                "epic depends_on would create a cycle through {epic}"
            )));
        }
    }
    write_epic_deps(tasks, epic, &deps).map_err(|e| die(e.to_string()))?;
    io.out
        .push_str(&format!("depends_on of epic {epic} set to {v}\n"));
    Ok(0)
}

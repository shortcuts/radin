use super::index::{epic_of, slugify, Index};
use super::{arg, die, usage_die, Ctx, Io, R};
use serde_json::Value;
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
        let _ = fs::remove_dir(&dir);
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
    fs::remove_dir(&dir).map_err(|e| die(e.to_string()))?;
    io.out.push_str(&format!("removed epic {epic}\n"));
    Ok(0)
}

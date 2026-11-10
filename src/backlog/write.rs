use super::epic::prune_empty_epic;
use super::index::{
    iso_utc, require_meta_value, require_no_moved_label, require_plain_title, require_priority,
    slugify, strs, Entry, Index, CATEGORIES, PRIORITY_SCALE,
};
use super::{arg, die, opt_val, plan, usage_die, Ctx, Fail, Io, R};
use crate::paths::git;
use serde_json::{Map, Value};
use std::collections::HashSet;
use std::fs;
use std::io::Write as _;
use std::path::Path;

fn skill_instruction(name: &str) -> String {
    format!("Invoke {name} to tackle this task.")
}

fn jstr(s: &str) -> Option<Value> {
    Some(Value::String(s.to_string()))
}

fn body_of(cx: &Ctx, what: &str) -> Result<String, Fail> {
    let body = cx.body();
    let body = body.trim_end_matches('\n');
    if body.is_empty() {
        return Err(die(format!("{what} is empty (pass it on stdin)")));
    }
    require_no_moved_label(body)?;
    Ok(body.to_string())
}

fn append_to(path: &Path, text: &str) -> Result<(), Fail> {
    fs::OpenOptions::new()
        .append(true)
        .open(path)
        .and_then(|mut f| f.write_all(text.as_bytes()))
        .map_err(|e| die(format!("{}: {e}", path.display())))
}

fn resolve_deps(idx: &Index, csv: &str) -> Result<Vec<String>, Fail> {
    let mut ids = vec![];
    for item in csv.split(',').map(str::trim).filter(|s| !s.is_empty()) {
        ids.push(idx.entries[idx.single(item)?].id());
    }
    Ok(ids)
}

pub fn add(cx: &Ctx, a: &[String], io: &mut Io) -> R {
    let (category, title) = (arg(a, 0), arg(a, 1));
    if title.is_empty() {
        return Err(usage_die(
            "add",
            "add needs a category and a title, with the body on stdin",
        ));
    }
    if !CATEGORIES.contains(&category) {
        return Err(usage_die(
            "add",
            &format!("category must be feat|fix|chore|refactor, got: {category}"),
        ));
    }
    let (mut skills, mut accept) = (vec![], vec![]);
    let (mut planning, mut complexity, mut location, mut origin, mut deps) = ("", "", "", "", "");
    let mut i = 2;
    while i < a.len() {
        let o = a[i].as_str();
        let need = match o {
            "--skill" => "--skill needs a name",
            "--acceptance" => "--acceptance needs a criterion",
            "--planning" => "--planning needs a value",
            "--complexity" => "--complexity needs a value",
            "--location" => "--location needs a path:line",
            "--origin" => "--origin needs a task id",
            "--deps" => "--deps needs a csv of ids or titles",
            _ => return Err(usage_die("add", &format!("unknown add option: {o}"))),
        };
        let v = opt_val(a, i, "add", need)?;
        match o {
            "--skill" => skills.push(skill_instruction(v)),
            "--acceptance" => accept.push(v.to_string()),
            "--planning" => planning = v,
            "--complexity" => complexity = v,
            "--location" => location = v,
            "--origin" => origin = v,
            _ => deps = v,
        }
        i += 2;
    }
    require_plain_title(title)?;
    let body = body_of(cx, "entry body")?;
    for v in &accept {
        require_meta_value("acceptance", v)?;
    }
    for (k, v) in [
        ("planning", planning),
        ("complexity", complexity),
        ("location", location),
        ("origin", origin),
    ] {
        if !v.is_empty() {
            require_meta_value(k, v)?;
        }
    }
    let mut idx = Index::load(cx.ns.backlog_index.clone())?;
    let deps = resolve_deps(&idx, deps)?;
    let base = slugify(title);
    if base.is_empty() {
        return Err(die(format!("title produced an empty id: {title}")));
    }
    let mut id = base.clone();
    let mut n = 2;
    while idx.has_id(&id) {
        id = format!("{base}-{n}");
        n += 1;
    }
    let rel = format!("tasks/{id}.md");
    fs::write(idx.task_path(&rel), format!("{body}\n")).map_err(|e| die(e.to_string()))?;
    let mut obj = Map::new();
    for (k, v) in [
        ("id", id.as_str()),
        ("category", category),
        ("title", title),
        ("file", &rel),
    ] {
        obj.insert(k.into(), Value::String(v.into()));
    }
    if !skills.is_empty() {
        obj.insert("skills".into(), strs(&skills));
    }
    obj.insert("created".into(), Value::String(iso_utc(cx.env.now)));
    if let Some(b) = git(&cx.ns.repo_root, &["symbolic-ref", "--short", "-q", "HEAD"]) {
        let b = b.trim_end();
        if !b.is_empty() {
            obj.insert("branch".into(), Value::String(b.into()));
        }
    }
    if !accept.is_empty() {
        obj.insert("acceptance".into(), strs(&accept));
    }
    for (k, v) in [
        ("planning", planning),
        ("complexity", complexity),
        ("location", location),
        ("origin", origin),
    ] {
        if !v.is_empty() {
            obj.insert(k.into(), Value::String(v.into()));
        }
    }
    if !deps.is_empty() {
        obj.insert("depends_on".into(), strs(&deps));
    }
    let file = location.rsplit_once(':').map_or(location, |(f, _)| f);
    if !file.is_empty() {
        for e in &idx.entries {
            if e.str("location").rsplit_once(':').map_or("", |(f, _)| f) == file {
                io.err.push_str(&format!(
                    "warning: open entry \"{}\" (id: {}) has the same location file {file}; append to it with `append` unless the cause differs\n",
                    e.title(),
                    e.id()
                ));
            }
        }
    }
    idx.entries.push(Entry::new(obj));
    idx.write()?;
    io.err.push_str(&format!(
        "added \"{title}\" (id: {id}) under {category} in {}\n",
        idx.path.display()
    ));
    io.out.push_str(&format!("{id}\n"));
    Ok(0)
}

pub fn append(cx: &Ctx, a: &[String], io: &mut Io) -> R {
    if arg(a, 0).is_empty() {
        return Err(usage_die(
            "append",
            "append needs an id or title, with the text on stdin",
        ));
    }
    let idx = cx.require()?;
    let e = &idx.entries[idx.single(&a[0])?];
    let body = body_of(cx, "append text")?;
    append_to(&idx.entry_path(e), &format!("\n{body}\n"))?;
    io.out.push_str(&format!("appended to \"{}\"\n", e.title()));
    Ok(0)
}

pub fn fact(cx: &Ctx, a: &[String], io: &mut Io) -> R {
    let (q, label, line) = (arg(a, 0), arg(a, 1), arg(a, 2));
    if q.is_empty() || label.is_empty() {
        return Err(usage_die(
            "fact",
            "fact needs an id or title, a label and the line",
        ));
    }
    if !["measured", "inferred", "guess"].contains(&label) {
        return Err(usage_die(
            "fact",
            &format!("label must be measured|inferred|guess, got: {label}"),
        ));
    }
    if line.is_empty() {
        return Err(die("fact line is empty (pass it as the fourth argument)"));
    }
    let long = match arg(a, 3) {
        "" => "",
        "--long" => match arg(a, 4) {
            "" => return Err(usage_die("fact", "--long needs a path")),
            p => p,
        },
        o => return Err(usage_die("fact", &format!("unknown argument: {o}"))),
    };
    let mut idx = cx.require()?;
    let i = idx.single(q)?;
    let text = format!("**Fact:** [{label}] {line}");
    require_no_moved_label(&text)?;
    if !long.is_empty() {
        require_meta_value("facts", long)?;
    }
    append_to(&idx.entry_path(&idx.entries[i]), &format!("\n{text}\n"))?;
    let title = idx.entries[i].title();
    if !long.is_empty() {
        idx.entries[i].set("facts", jstr(long));
        idx.write()?;
    }
    io.out.push_str(&format!("fact recorded on \"{title}\"\n"));
    Ok(0)
}

pub fn add_plan(cx: &Ctx, a: &[String], io: &mut Io) -> R {
    let (q, path) = (arg(a, 0), arg(a, 1));
    if path.is_empty() {
        return Err(usage_die(
            "add-plan",
            "add-plan needs an id or title and a plan path",
        ));
    }
    let mut idx = cx.require()?;
    let i = idx.single(q)?;
    require_meta_value("plan", path)?;
    let file = cx.env.cwd.join(path);
    if !file.is_file() {
        return Err(die(format!("add-plan: no plan file at {path}")));
    }
    let defects = plan::lint(&fs::read_to_string(&file).unwrap_or_default());
    if !defects.is_empty() {
        return Err(die(format!(
            "add-plan: plan-lint rejects {path}\n{}",
            defects.join("\n")
        )));
    }
    let mut plans = idx.entries[i].arr("plan");
    plans.push(path.to_string());
    idx.entries[i].set("plan", Some(strs(&plans)));
    idx.write()?;
    let (id, title) = (idx.entries[i].id(), idx.entries[i].title());
    if let Some(head) = git(&cx.ns.repo_root, &["rev-parse", "--verify", "-q", "HEAD"]) {
        let dir = cx.ns.namespace_dir.join("plans");
        fs::create_dir_all(&dir)
            .and_then(|()| fs::write(dir.join(format!("{id}.head")), head))
            .map_err(|e| die(e.to_string()))?;
    }
    io.out
        .push_str(&format!("plan pointer added to \"{title}\"\n"));
    Ok(0)
}

fn drop_task_files(idx: &Index, cx: &Ctx, rels: &[String]) {
    for rel in rels {
        let _ = fs::remove_file(idx.task_path(rel));
        prune_empty_epic(&cx.ns.backlog_tasks_dir, &super::index::epic_of(rel));
    }
}

pub fn remove(cx: &Ctx, a: &[String], io: &mut Io) -> R {
    if arg(a, 0).is_empty() {
        return Err(usage_die("remove", "remove needs an id or title"));
    }
    let mut idx = cx.require()?;
    let e = &idx.entries[idx.single(&a[0])?];
    let (id, title) = (e.id(), e.title());
    let files = idx.remove_id(&id);
    idx.write()?;
    drop_task_files(&idx, cx, &files);
    io.out
        .push_str(&format!("removed \"{title}\" (id: {id})\n"));
    Ok(0)
}

pub fn reconcile(cx: &Ctx, _a: &[String], io: &mut Io) -> R {
    let mut idx = cx.require()?;
    let Ok(done) = fs::read_to_string(cx.ns.namespace_dir.join("state/completed.json")) else {
        io.out
            .push_str("reconcile: no completed file, nothing to do\n");
        return Ok(0);
    };
    let (mut removed, mut files) = (String::new(), vec![]);
    for line in done.lines() {
        let Ok(Value::Object(o)) = serde_json::from_str::<Value>(line) else {
            continue;
        };
        let id = o.get("id").and_then(Value::as_str).unwrap_or("");
        if !id.is_empty() && idx.has_id(id) {
            files.extend(idx.remove_id(id));
            removed.push_str(&format!(" {id}"));
        }
    }
    if removed.is_empty() {
        io.out.push_str("reconcile: no stale completed entries\n");
        return Ok(0);
    }
    idx.write()?;
    drop_task_files(&idx, cx, &files);
    io.out.push_str(&format!(
        "reconcile: dropped already-completed entries:{removed}\n"
    ));
    Ok(0)
}

pub fn set_category(cx: &Ctx, a: &[String], io: &mut Io) -> R {
    let (q, cat) = (arg(a, 0), arg(a, 1));
    if cat.is_empty() {
        return Err(usage_die(
            "set-category",
            "set-category needs an id or title and a category",
        ));
    }
    if !CATEGORIES.contains(&cat) {
        return Err(usage_die(
            "set-category",
            &format!("category must be feat|fix|chore|refactor, got: {cat}"),
        ));
    }
    let mut idx = cx.require()?;
    let i = idx.single(q)?;
    idx.entries[i].set("category", jstr(cat));
    idx.write()?;
    io.out
        .push_str(&format!("moved \"{}\" to {cat}\n", idx.entries[i].title()));
    Ok(0)
}

pub fn retitle(cx: &Ctx, a: &[String], io: &mut Io) -> R {
    let (q, title) = (arg(a, 0), arg(a, 1));
    if title.is_empty() {
        return Err(usage_die(
            "retitle",
            "retitle needs an id or title and a new title",
        ));
    }
    require_plain_title(title)?;
    let mut idx = cx.require()?;
    let i = idx.single(q)?;
    idx.entries[i].set("title", jstr(title));
    idx.write()?;
    io.out.push_str(&format!(
        "retitled {} to \"{title}\"\n",
        idx.entries[i].id()
    ));
    Ok(0)
}

pub fn set_priority(cx: &Ctx, a: &[String], io: &mut Io) -> R {
    let (q, v) = (arg(a, 0), arg(a, 1));
    if v.is_empty() {
        return Err(usage_die(
            "set-priority",
            &format!("set-priority needs an id or title and one of {PRIORITY_SCALE} or --none"),
        ));
    }
    if v != "--none" {
        require_priority(v)?;
    }
    let mut idx = cx.require()?;
    let i = idx.single(q)?;
    let n = v.parse::<u64>().ok().map(Value::from);
    idx.entries[i].set("priority", n);
    idx.write()?;
    io.out
        .push_str(&format!("priority of {} set to {v}\n", idx.entries[i].id()));
    Ok(0)
}

fn deps_reach(idx: &Index, target: &str, from: Vec<String>) -> bool {
    let (mut pending, mut seen) = (from, HashSet::new());
    while let Some(cur) = pending.pop() {
        if cur == target {
            return true;
        }
        if !seen.insert(cur.clone()) {
            continue;
        }
        if let Some(e) = idx.entries.iter().find(|e| e.id() == cur) {
            pending.extend(e.depends_on());
        }
    }
    false
}

pub fn set_deps(cx: &Ctx, a: &[String], io: &mut Io) -> R {
    let (q, v) = (arg(a, 0), arg(a, 1));
    if v.is_empty() {
        return Err(usage_die(
            "set-deps",
            "set-deps needs an id or title and a csv of ids or --none",
        ));
    }
    let mut idx = cx.require()?;
    let i = idx.single(q)?;
    let id = idx.entries[i].id();
    let mut value = None;
    if v != "--none" {
        let deps = resolve_deps(&idx, v)?;
        if deps_reach(&idx, &id, deps.clone()) {
            return Err(die(format!("depends_on would create a cycle through {id}")));
        }
        value = (!deps.is_empty()).then(|| strs(&deps));
    }
    idx.entries[i].set("depends_on", value);
    idx.write()?;
    io.out.push_str(&format!("depends_on of {id} set to {v}\n"));
    Ok(0)
}

pub fn set_meta(cx: &Ctx, a: &[String], io: &mut Io) -> R {
    let (q, key) = (arg(a, 0), arg(a, 1));
    if key.is_empty() {
        return Err(usage_die(
            "set-meta",
            "set-meta needs an id or title, a key, and a value or --none",
        ));
    }
    const KEYS: &str = "plan|skills|acceptance|facts|location|planning|complexity|exclusive|origin";
    if !KEYS.split('|').any(|k| k == key) {
        return Err(usage_die(
            "set-meta",
            &format!("key must be {KEYS}, got: {key}"),
        ));
    }
    let vals = a.get(2..).unwrap_or(&[]);
    if vals.is_empty() {
        return Err(usage_die(
            "set-meta",
            "set-meta needs at least one value, or --none",
        ));
    }
    let mut idx = cx.require()?;
    let i = idx.single(q)?;
    let id = idx.entries[i].id();
    let scalar = matches!(
        key,
        "facts" | "location" | "planning" | "complexity" | "exclusive" | "origin"
    );
    let value = if vals[0] == "--none" {
        if vals.len() > 1 {
            return Err(usage_die(
                "set-meta",
                &format!("--none takes no other value, got: {}", vals[1]),
            ));
        }
        None
    } else {
        if scalar && vals.len() != 1 {
            return Err(usage_die(
                "set-meta",
                &format!("{key} takes exactly one value, got {}", vals.len()),
            ));
        }
        let mut out = vec![];
        for v in vals {
            let v = if key == "skills" {
                skill_instruction(v)
            } else {
                v.clone()
            };
            require_meta_value(key, &v)?;
            out.push(v);
        }
        Some(if scalar {
            Value::String(out.remove(0))
        } else {
            strs(&out)
        })
    };
    let state = if value.is_some() { "set" } else { "cleared" };
    idx.entries[i].set(key, value);
    idx.write()?;
    io.out.push_str(&format!("{key} of {id} {state}\n"));
    Ok(0)
}

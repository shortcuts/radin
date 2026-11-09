use crate::paths::{git, Namespace};
use crate::{Ctx, Host, Out};
use sha2::{Digest, Sha256};
use std::fs;
use std::path::{Path, PathBuf};

const NAME_MAX: usize = 64;

/// The Agent tool caps names at 64 characters; a cut name gets a hash tag so it stays unique.
pub fn agent_name(kind: &str, task_id: &str) -> String {
    let full = format!("radin-{kind}-{task_id}");
    if full.len() <= NAME_MAX {
        return full;
    }
    let tag: String = Sha256::digest(full.as_bytes())
        .iter()
        .take(6)
        .map(|x| format!("{x:02x}"))
        .collect();
    let head: String = full.chars().take(NAME_MAX - tag.len() - 1).collect();
    format!("{}-{tag}", head.trim_end_matches('-'))
}

type R<T> = Result<T, Out>;

fn die<T>(m: impl AsRef<str>) -> R<T> {
    Err((1, String::new(), format!("radin-prompt: {}\n", m.as_ref())))
}

fn chomp(s: &str) -> &str {
    s.trim_end_matches('\n')
}

fn fence(text: &str) -> String {
    let mut on = false;
    let mut out = String::new();
    for l in text.lines() {
        if l == "```" {
            on = !on;
        } else if on {
            out += l;
            out.push('\n');
        }
    }
    chomp(&out).to_string()
}

fn strip_guards(text: &str, active: &str) -> String {
    let mut skip = false;
    let mut out = String::new();
    for l in text.lines() {
        if let Some(rest) = l.strip_prefix("<!-- if:") {
            let name = rest.strip_suffix(" -->").unwrap_or(rest);
            let (neg, name) = match name.strip_prefix('!') {
                Some(n) => (true, n),
                None => (false, name),
            };
            let on = active.contains(&format!(" {name} "));
            skip = if neg { on } else { !on };
        } else if l == "<!-- end -->" {
            skip = false;
        } else if !skip {
            out += l;
            out.push('\n');
        }
    }
    chomp(&out).to_string()
}

fn tick_line(text: &str, key: &str) -> Option<String> {
    let head = format!("`{key}: \"");
    text.lines().find_map(|l| {
        l.strip_prefix(&head)
            .and_then(|r| r.strip_suffix("\"`"))
            .filter(|v| !v.contains('"'))
            .map(str::to_string)
    })
}

struct Dispatch {
    model: String,
    effort: String,
}

impl Dispatch {
    fn print(&self, name: &str, path: &Path) -> Out {
        let mut s = String::new();
        if !self.model.is_empty() {
            s += &format!("model\t{}\n", self.model);
        }
        if !self.effort.is_empty() {
            s += &format!("effort\t{}\n", self.effort);
        }
        s += &format!("name\t{name}\n");
        (
            0,
            s + &format!("prompt\t{}\n", path.display()),
            String::new(),
        )
    }
}

fn read_fenced(dir: &Path, name: &str, what: &str) -> R<String> {
    let p = dir.join(name);
    let text = fence(&fs::read_to_string(&p).unwrap_or_default());
    if text.is_empty() {
        return die(format!("no fenced {what} in {}", p.display()));
    }
    Ok(text)
}

fn write_prompt(ns: &Path, file: &str, body: &str) -> R<PathBuf> {
    let dir = ns.join("state/prompts");
    let out = dir.join(file);
    let _ = fs::create_dir_all(ns.join("state/facts"));
    fs::create_dir_all(&dir)
        .and_then(|()| fs::write(&out, format!("{body}\n")))
        .or_else(|e| die(format!("cannot write {}: {e}", out.display())))?;
    Ok(out)
}

fn md_dir(c: &Ctx) -> PathBuf {
    let flat = c.home.join(".radin/lib");
    let dir = c.home.join(format!(".radin/hosts/{}/lib", c.host.as_str()));
    if dir.is_dir() {
        dir
    } else {
        flat
    }
}

pub fn run(c: &Ctx, args: &[String]) -> Out {
    match build(c, args) {
        Ok(o) | Err(o) => o,
    }
}

fn build(c: &Ctx, args: &[String]) -> R<Out> {
    let a = |i: usize| args.get(i).map_or("", String::as_str);
    let (kind, id, extra) = (a(0), a(1), a(2));
    if kind.is_empty() || (id.is_empty() && kind != "gate" && kind != "merge") {
        return die("usage: radin prompt <planning|execution|debug|factfind> <id> [<failure|question>] | planning <id> [<earlier-id>...] | gate | merge [<branch>...]");
    }
    if ![
        "planning",
        "execution",
        "debug",
        "factfind",
        "gate",
        "merge",
    ]
    .contains(&kind)
    {
        return die(format!("unknown prompt kind: {kind}"));
    }
    let dir = md_dir(c);
    let template = dir.join(format!("radin-prompt-{kind}.md"));
    let Ok(ttext) = fs::read_to_string(&template) else {
        return die(format!("no template file: {}", template.display()));
    };
    match kind {
        "debug" if extra.is_empty() => {
            return die("the debug prompt needs the failure reason as its third argument")
        }
        "factfind" if extra.is_empty() => {
            return die("the factfind prompt needs the question as its third argument")
        }
        _ => {}
    }
    let d = Dispatch {
        model: tick_line(&ttext, "model").unwrap_or_default(),
        effort: tick_line(&ttext, "effort").unwrap_or_default(),
    };
    if d.model.is_empty() && c.host != Host::Agents {
        return die(format!("no model line in {}", template.display()));
    }
    let mut body = fence(&ttext);
    if body.is_empty() {
        return die(format!("no fenced prompt in {}", template.display()));
    }
    let leaf = read_fenced(&dir, "radin-leaf-contract.md", "contract")?;
    let comment = read_fenced(&dir, "radin-comment-rule.md", "rule")?;
    let explore = read_fenced(&dir, "radin-explore-rule.md", "rule")?;
    let open = read_fenced(&dir, "radin-open-decisions.md", "rule")?;
    let complexity = read_fenced(&dir, "radin-complexity-rule.md", "rule")?;
    let planning = read_fenced(&dir, "radin-planning-rule.md", "rule")?;
    let n = Namespace::locate(&c.cwd);
    let (root, ns) = (n.repo_root, n.namespace_dir);
    let sub = |body: &mut String, token: &str, value: &str| *body = body.replace(token, value);

    if kind == "gate" {
        let map = c.nested(&root, &["state", "gate-map"]);
        if map.0 != 0 {
            return die("no session commits, so no gate is due");
        }
        let active = if ns.join("state/gate-reviewed").exists() {
            " "
        } else {
            " GATE_REVIEW "
        };
        body = strip_guards(&body, active);
        sub(&mut body, "LEAF_CONTRACT", &leaf);
        sub(&mut body, "PLANNING_RULE", &planning);
        sub(&mut body, "COMPLEXITY_RULE", &complexity);
        sub(&mut body, "GATE_MAP", chomp(&map.1));
        let out = write_prompt(&ns, "session-gate.md", &body)?;
        return Ok(d.print("radin-gate", &out));
    }
    if kind == "merge" {
        if args.len() < 2 {
            return die("usage: merge <branch>...");
        }
        let left = c.nested(&root, &["state", "leftovers"]);
        if left.0 != 0 {
            return die("no leftover branch to merge");
        }
        let base = left
            .1
            .lines()
            .next()
            .and_then(|l| l.strip_prefix("base\t"))
            .unwrap_or("");
        let mut branches = Vec::new();
        for b in &args[1..] {
            let Some(tip) = git(&root, &["rev-parse", "--short=12", b]) else {
                return die(format!("no such branch: {b}"));
            };
            branches.push(format!("{b} ({})", chomp(&tip)));
        }
        sub(&mut body, "LEAF_CONTRACT", &leaf);
        sub(&mut body, "MERGE_BASE", base);
        sub(&mut body, "MERGE_BRANCHES", &branches.join(", "));
        let out = write_prompt(&ns, "session-merge.md", &body)?;
        return Ok(d.print("radin-merge", &out));
    }

    let field = |name: &str| -> Option<String> {
        let o = c.nested(&root, &["backlog", "field", id, name]);
        (o.0 == 0).then(|| chomp(&o.1).to_string())
    };
    let task_id = field("TASK_ID").unwrap_or_default();
    if task_id.is_empty() {
        return die(format!("no backlog task matches: {id}"));
    }
    let task_file = field("TASK_FILE").unwrap_or_default();
    let category = field("CATEGORY").unwrap_or_default();
    let plan_paths = field("PLAN_PATHS").unwrap_or_default();
    let skills = match field("SKILLS").unwrap_or_default() {
        s if s == "none" => String::new(),
        s => s
            .lines()
            .filter(|l| !l.trim().is_empty())
            .collect::<Vec<_>>()
            .join("; "),
    };
    let acceptance = field("ACCEPTANCE").unwrap_or_default();
    let facts = field("FACTS").unwrap_or_default();
    let location = field("LOCATION").unwrap_or_default();
    let epic = field("EPIC_CONTEXT").unwrap_or_default();
    let Some(task_body) = field("TASK_BODY") else {
        return die(format!("task file is empty or missing: {task_file}"));
    };

    let mut depends_on = String::new();
    if kind == "execution" && ns.join("state/BACKLOG_STEPS.json").is_file() {
        let deps = c.nested(&c.cwd, &["state", "deps-check", &task_id]);
        if deps.0 != 0 {
            return die(format!(
                "dependency of {task_id} is unresolved, so no execution prompt is due yet"
            ));
        }
        depends_on = deps
            .1
            .lines()
            .filter_map(|l| l.split_once('\t').or(Some((l, ""))))
            .filter(|(dep, _)| !dep.is_empty())
            .map(|(dep, hash)| format!("{dep}: {hash}"))
            .collect::<Vec<_>>()
            .join(", ");
    }

    let mut stale_plan = String::new();
    let head_file = ns.join(format!("plans/{task_id}.head"));
    if kind == "execution" {
        if let Ok(base) = fs::read_to_string(&head_file) {
            let base = chomp(&base);
            if git(&root, &["cat-file", "-e", &format!("{base}^{{commit}}")]).is_some() {
                let files = c.nested(&root, &["backlog", "files", &task_id]);
                let plan_files: Vec<&str> = if files.0 == 0 {
                    files.1.lines().collect()
                } else {
                    vec![]
                };
                let changed =
                    git(&root, &["diff", "--name-only", base, "HEAD"]).unwrap_or_default();
                let hit: Vec<&str> = changed.lines().filter(|l| plan_files.contains(l)).collect();
                if !hit.is_empty() {
                    let range = format!("{base}..HEAD");
                    let mut a = vec!["log", "--format=%h %s", &range, "--"];
                    a.extend(&hit);
                    let commits = git(&root, &a)
                        .unwrap_or_default()
                        .lines()
                        .filter(|l| !l.trim().is_empty())
                        .collect::<Vec<_>>()
                        .join("; ");
                    if !commits.is_empty() {
                        stale_plan = format!("{commits} | files: {}", hit.join(", "));
                    }
                }
            }
        }
    }

    let task_dir = if kind == "debug" {
        let o = c.nested(&c.cwd, &["state", "task-dir", &task_id]);
        if o.0 != 0 {
            return Err(o);
        }
        chomp(&o.1).to_string()
    } else {
        String::new()
    };

    let earlier = if kind == "planning" {
        args.iter()
            .skip(2)
            .filter_map(|e| {
                let o = c.nested(&root, &["backlog", "field", e, "PLAN_PATHS"]);
                (o.0 == 0).then(|| chomp(&o.1).to_string())
            })
            .filter(|p| !p.is_empty())
            .collect::<Vec<_>>()
            .join(", ")
    } else {
        String::new()
    };

    let mut active = format!(" CAT_{category} ");
    let claims = fs::metadata(ns.join(format!("state/stash-claims/{task_id}")));
    for (on, name) in [
        (!plan_paths.is_empty(), "PLAN_PATHS"),
        (!earlier.is_empty(), "EARLIER_PLANS"),
        (!skills.is_empty(), "SKILLS"),
        (!acceptance.is_empty(), "ACCEPTANCE"),
        (!facts.is_empty(), "FACTS"),
        (!location.is_empty(), "LOCATION"),
        (!epic.is_empty(), "EPIC_CONTEXT"),
        (!depends_on.is_empty(), "DEPENDS_ON"),
        (!stale_plan.is_empty(), "STALE_PLAN"),
        (claims.is_ok_and(|m| m.len() > 0), "STASH_BASE"),
        (!depends_on.is_empty() || !stale_plan.is_empty(), "DRIFT"),
    ] {
        if on {
            active = format!("{active} {name} ");
        }
    }
    body = strip_guards(&body, &active);

    let review_core = if kind == "execution" {
        let p = dir.join("radin-review-core.md");
        match fs::read_to_string(&p) {
            Ok(t) => strip_guards(&t, " LEVEL_diff "),
            Err(_) => return die(format!("no review core: {}", p.display())),
        }
    } else {
        String::new()
    };

    let or_none = |s: &str| {
        if s.is_empty() {
            "none".to_string()
        } else {
            s.to_string()
        }
    };
    let ns_str = ns.to_string_lossy();
    for (token, value) in [
        ("LEAF_CONTRACT", leaf.as_str()),
        ("COMMENT_RULE", &comment),
        ("EXPLORE_RULE", &explore),
        ("OPEN_DECISIONS_RULE", &open),
        ("COMPLEXITY_RULE", &complexity),
        ("PLANNING_RULE", &planning),
        ("NAMESPACE_DIR", &ns_str),
        ("TASK_FILE", &task_file),
        ("TASK_DIR", &task_dir),
        ("TASK_ID", &task_id),
        ("EARLIER_PLAN_PATHS", &earlier),
        ("PLAN_PATHS", &or_none(&plan_paths)),
        ("DEPENDS_ON", &or_none(&depends_on)),
        ("STALE_PLAN", &or_none(&stale_plan)),
        ("SKILLS", &or_none(&skills)),
        ("CATEGORY", &category),
        ("ACCEPTANCE", &acceptance),
        ("FACTS", &facts),
        ("LOCATION", &location),
    ] {
        sub(&mut body, token, value);
    }
    match kind {
        "debug" => sub(&mut body, "FAILURE", extra),
        "factfind" => sub(&mut body, "QUESTION", extra),
        _ => {}
    }
    sub(&mut body, "REVIEW_CORE", &review_core);
    sub(&mut body, "EPIC_CONTEXT", &epic);
    sub(&mut body, "TASK_BODY", &task_body);

    let out = write_prompt(&ns, &format!("{task_id}-{kind}.md"), &body)?;
    Ok(d.print(&agent_name(kind, &task_id), &out))
}

mod epic;
mod index;
pub(crate) use index::epic_of;
mod order;
mod plan;
mod read;
mod usage;
mod write;

use crate::paths::Namespace;
use crate::{Host, Out};
use index::Index;
use std::io::{IsTerminal, Read};
use std::path::PathBuf;

pub struct Env {
    pub cwd: PathBuf,
    pub home: PathBuf,
    pub host: Host,
    pub epic_threshold: Option<String>,
    pub now: i64,
    pub stdin: Box<dyn Fn() -> Option<String>>,
}

impl Env {
    pub fn process(host: Host, env: &dyn Fn(&str) -> Option<String>) -> Env {
        Env {
            cwd: std::env::current_dir().unwrap_or_default(),
            home: env("HOME").unwrap_or_default().into(),
            host,
            epic_threshold: env("RADIN_EPIC_THRESHOLD").filter(|v| !v.is_empty()),
            now: std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map_or(0, |d| d.as_secs() as i64),
            stdin: Box::new(|| {
                let mut s = std::io::stdin();
                if s.is_terminal() {
                    return None;
                }
                let mut b = Vec::new();
                s.read_to_end(&mut b).ok()?;
                Some(String::from_utf8_lossy(&b).into_owned())
            }),
        }
    }
}

pub struct Fail {
    pub code: i32,
    pub msg: String,
}

#[derive(Default)]
pub struct Io {
    pub out: String,
    pub err: String,
}

pub type R = Result<i32, Fail>;

pub fn die(m: impl AsRef<str>) -> Fail {
    Fail {
        code: 1,
        msg: format!("radin-backlog: {}\n", m.as_ref()),
    }
}

pub fn usage_die(verb: &str, m: &str) -> Fail {
    Fail {
        code: 1,
        msg: format!("radin-backlog: {m}\n{}", usage::usage_for(verb)),
    }
}

pub struct Ctx<'a> {
    pub env: &'a Env,
    pub ns: &'a Namespace,
}

impl Ctx<'_> {
    pub fn require(&self) -> Result<Index, Fail> {
        Index::require(self.ns.backlog_index.clone())
    }

    pub fn body(&self) -> String {
        (self.env.stdin)().unwrap_or_default()
    }
}

pub fn arg(a: &[String], i: usize) -> &str {
    a.get(i).map_or("", String::as_str)
}

pub fn opt_val<'a>(a: &'a [String], i: usize, verb: &str, msg: &str) -> Result<&'a str, Fail> {
    match arg(a, i + 1) {
        "" => Err(usage_die(verb, msg)),
        v => Ok(v),
    }
}

fn unknown(what: &str) -> Fail {
    die(format!(
        "unknown command: {}\n{}",
        if what.is_empty() { "<none>" } else { what },
        usage::all().trim_end_matches('\n')
    ))
}

pub fn run(args: &[String], env: &Env) -> Out {
    let mut io = Io::default();
    let code = match dispatch(args, env, &mut io) {
        Ok(c) => c,
        Err(e) => {
            io.err.push_str(&e.msg);
            e.code
        }
    };
    (code, io.out, io.err)
}

fn help(a: &[String], io: &mut Io) -> R {
    let text = match arg(a, 0) {
        "" => usage::all(),
        v => match usage::usage_for(v) {
            u if u.is_empty() => return Err(unknown(v)),
            u => u,
        },
    };
    io.out.push_str(&text);
    Ok(0)
}

fn dispatch(args: &[String], env: &Env, io: &mut Io) -> R {
    let verb = arg(args, 0);
    let a = args.get(1..).unwrap_or(&[]);
    if matches!(verb, "help" | "--help" | "-h") {
        return help(a, io);
    }
    if !usage::USAGE.iter().any(|(v, _)| *v == verb) {
        return Err(unknown(verb));
    }
    let ns = Namespace::locate(&env.cwd);
    ns.ensure_dirs().map_err(|e| die(e.to_string()))?;
    let cx = Ctx { env, ns: &ns };
    match verb {
        "env" => read::env(&cx, a, io),
        "show" => read::show(&cx, a, io),
        "list" => read::list(&cx, a, io),
        "find" => read::find(&cx, a, io),
        "count" => read::count(&cx, a, io),
        "meta" => read::meta(&cx, a, io),
        "field" => read::field(&cx, a, io),
        "duplicates" => read::duplicates(&cx, a, io),
        "stamps" => read::stamps(&cx, a, io),
        "add" => write::add(&cx, a, io),
        "append" => write::append(&cx, a, io),
        "fact" => write::fact(&cx, a, io),
        "add-plan" => write::add_plan(&cx, a, io),
        "remove" => write::remove(&cx, a, io),
        "reconcile" => write::reconcile(&cx, a, io),
        "set-category" => write::set_category(&cx, a, io),
        "retitle" => write::retitle(&cx, a, io),
        "set-priority" => write::set_priority(&cx, a, io),
        "set-deps" => write::set_deps(&cx, a, io),
        "set-meta" => write::set_meta(&cx, a, io),
        "order" => order::order(&cx, a, io),
        "suggest" => order::suggest(&cx, a, io),
        "scope" => order::scope(&cx, a, io),
        "plan-target" => plan::plan_target(&cx, a, io),
        "open-decisions" => plan::open_decisions(&cx, a, io),
        "files" => plan::files(&cx, a, io),
        "plan-lint" => plan::plan_lint(&cx, a, io),
        "epics" => epic::epics(&cx, a, io),
        "epic-add" => epic::epic_add(&cx, a, io),
        "epic-show" => epic::epic_show(&cx, a, io),
        "epic-move" => epic::epic_move(&cx, a, io),
        _ => epic::epic_remove(&cx, a, io),
    }
}

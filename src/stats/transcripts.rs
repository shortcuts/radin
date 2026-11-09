use super::{f0, f1, sorted, Rows};
use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::fs;
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};

/// The first run after `prefix` that has `min..=max` chars of `ok` and, when `close` is set, ends at that char.
pub(super) fn grab<'a>(
    l: &'a str,
    prefix: &str,
    ok: impl Fn(char) -> bool,
    min: usize,
    max: usize,
    close: Option<char>,
) -> Option<(usize, &'a str)> {
    for (i, _) in l.match_indices(prefix) {
        let from = i + prefix.len();
        let run: usize = l[from..]
            .chars()
            .take(max)
            .take_while(|c| ok(*c))
            .map(char::len_utf8)
            .sum();
        let n = l[from..from + run].chars().count();
        let after = l[from + run..].chars().next();
        if n >= min && close.is_none_or(|c| after == Some(c)) {
            return Some((i, &l[from..from + run]));
        }
    }
    None
}

pub(super) fn val<'a>(l: &'a str, prefix: &str, min: usize) -> Option<&'a str> {
    grab(l, prefix, |c| c != '"', min, usize::MAX, Some('"')).map(|r| r.1)
}

pub(super) fn alnum(c: char) -> bool {
    c.is_ascii_alphanumeric()
}

/// A `"id":"toolu_…","name":"<name>","input":<tail>` call: its id, where it starts and where its tail ends.
pub(super) fn tool_call<'a>(l: &'a str, name: &str, tail: &str) -> Option<(&'a str, usize, usize)> {
    let lit = format!("\",\"name\":\"{name}\",\"input\":{tail}");
    for (i, _) in l.match_indices("\"id\":\"toolu_") {
        let from = i + 6;
        let run: usize = l[from + 6..].chars().take_while(|c| alnum(*c)).count();
        let end = from + 6 + run;
        if run > 0 && l[end..].starts_with(&lit) {
            return Some((&l[from..end], i, end + lit.len()));
        }
    }
    None
}

pub(super) fn skip_attachment(l: &str) -> bool {
    l.match_indices("\"attachment\":{\"type\":\"")
        .any(|(i, m)| {
            let mut c = l[i + m.len()..].chars();
            match (c.next(), c.next()) {
                (Some(a), _) if a != 'h' => true,
                (Some('h'), Some(b)) => b != 'o',
                _ => false,
            }
        })
}

pub(super) fn vendor(n: &str) -> String {
    if n.starts_with("radin") {
        "radin".into()
    } else if let Some((v, _)) = n.split_once(':') {
        v.into()
    } else {
        "other".into()
    }
}

pub(super) fn hook_label(l: &str, ht: &str) -> String {
    let none = "(no output)".to_string();
    if ht == "hook_cancelled" {
        return val(l, "\"command\":\"", 1).map_or(none, str::to_string);
    }
    if ht == "hook_non_blocking_error" {
        return grab(l, "executing hook command: ", |c| c != '"', 1, 60, None)
            .map_or(none, |r| r.1.to_string());
    }
    let content = ["\"content\":[\"", "\"content\":\""]
        .iter()
        .filter_map(|p| grab(l, p, |c| c != '"' && c != '\\', 2, 40, None))
        .min_by_key(|r| r.0);
    if let Some((_, v)) = content {
        return v.to_string();
    }
    if let Some((_, v)) = grab(
        l,
        "permissionDecisionReason\\\":\\\"",
        |c| c != '\\',
        1,
        usize::MAX,
        None,
    ) {
        return v.to_string();
    }
    if let Some((_, v)) = grab(
        l,
        "additionalContext\\\":\\\"[",
        |c| c.is_ascii_lowercase() || c == '-',
        1,
        usize::MAX,
        Some(']'),
    ) {
        return format!("[{v}]");
    }
    none
}

#[derive(Default)]
pub(super) struct Notice {
    tool_use: String,
    status: String,
    tokens: u64,
    tools: u64,
    ms: u64,
}

#[derive(Default)]
pub(super) struct Scan {
    min: String,
    max: String,
    seen: HashSet<String>,
    skill_tool: HashMap<String, u64>,
    skill_typed: HashMap<String, u64>,
    skill_sessions: HashSet<(String, String)>,
    skill_projects: HashSet<(String, String)>,
    skill_last: HashMap<String, String>,
    agent_calls: BTreeMap<String, u64>,
    agent_models: BTreeMap<(String, String), u64>,
    type_of: HashMap<String, String>,
    name_of: HashMap<String, String>,
    notices: HashMap<String, Notice>,
    hooks: BTreeMap<(String, String), [u64; 3]>,
    hook_sessions: HashSet<(String, String, String)>,
    hook_last: HashMap<(String, String), String>,
}

pub(super) fn num(l: &str, prefix: &str) -> u64 {
    grab(l, prefix, |c| c.is_ascii_digit(), 1, usize::MAX, None)
        .map_or(0, |r| r.1.parse().unwrap_or(0))
}

impl Scan {
    fn touch(&mut self, name: &str, proj: &str, sid: &str, day: &str) {
        self.skill_sessions.insert((name.into(), sid.into()));
        self.skill_projects.insert((name.into(), proj.into()));
        let last = self.skill_last.entry(name.into()).or_default();
        if day > last.as_str() {
            *last = day.into();
        }
    }

    fn line(&mut self, l: &str, proj: &str, sid: &str, since: &str) {
        let day = grab(
            l,
            "\"timestamp\":\"",
            |c| c.is_ascii_digit() || c == '-',
            1,
            usize::MAX,
            None,
        )
        .map_or("", |r| r.1);
        if !since.is_empty() && !day.is_empty() && day < since {
            return;
        }
        if !day.is_empty() {
            if self.min.is_empty() || day < self.min.as_str() {
                self.min = day.into();
            }
            if day > self.max.as_str() {
                self.max = day.into();
            }
        }
        if let Some((_, run)) = grab(
            l,
            "\"attachment\":{\"type\":\"hook_",
            |c| c.is_ascii_lowercase() || c == '_',
            1,
            usize::MAX,
            Some('"'),
        ) {
            let ht = format!("hook_{run}");
            let mut hn = val(l, "\"hookName\":\"", 1).unwrap_or("-").to_string();
            if hn.starts_with("SubagentStart:") {
                hn = "SubagentStart".into();
            }
            let hid = val(l, "\"toolUseID\":\"", 1).unwrap_or("");
            let key = (hn, hook_label(l, &ht));
            if self
                .seen
                .insert(format!("{hid}\u{1c}{}\u{1c}{}\u{1c}{ht}", key.0, key.1))
            {
                let slot = match ht.as_str() {
                    "hook_cancelled" => 1,
                    "hook_non_blocking_error" => 2,
                    _ => 0,
                };
                self.hooks.entry(key.clone()).or_default()[slot] += 1;
                self.hook_sessions
                    .insert((key.0.clone(), key.1.clone(), sid.into()));
                let last = self.hook_last.entry(key).or_default();
                if day > last.as_str() {
                    *last = day.into();
                }
            }
            return;
        }
        if let Some((id, _, end)) = tool_call(l, "Skill", "{\"skill\":\"") {
            if let Some(name) = l[end..]
                .split('"')
                .next()
                .filter(|n| !n.is_empty() && l[end..].len() > n.len())
            {
                if self.seen.insert(id.into()) {
                    *self.skill_tool.entry(name.into()).or_default() += 1;
                    self.touch(name, proj, sid, day);
                }
            }
        }
        if let Some((_, v)) = typed(l) {
            *self.skill_typed.entry(v.into()).or_default() += 1;
            self.touch(v, proj, sid, day);
        }
        if let Some((id, start, _)) = tool_call(l, "Agent", "") {
            if self.seen.insert(id.into()) {
                let rest = &l[start..];
                let t = val(rest, "\"subagent_type\":\"", 1).unwrap_or("general-purpose");
                let m = val(rest, "\"model\":\"", 1).unwrap_or("inherit");
                *self.agent_calls.entry(t.into()).or_default() += 1;
                *self.agent_models.entry((t.into(), m.into())).or_default() += 1;
                self.type_of.insert(id.into(), t.into());
                if let Some((_, n)) = grab(
                    rest,
                    "\"name\":\"radin-",
                    |c| c != '"',
                    1,
                    usize::MAX,
                    Some('"'),
                ) {
                    self.name_of.insert(id.into(), format!("radin-{n}"));
                }
            }
        }
        if l.contains("<task-notification>") {
            let Some(tid) = grab(l, "<task-id>", |c| c != '<', 1, usize::MAX, None) else {
                return;
            };
            let field =
                |p: &str| grab(l, p, |c| c != '<', 1, usize::MAX, None).map(|r| r.1.to_string());
            self.notices.insert(
                tid.1.into(),
                Notice {
                    tool_use: field("<tool-use-id>").unwrap_or_default(),
                    status: field("<status>").unwrap_or_else(|| "?".into()),
                    tokens: num(l, "<subagent_tokens>"),
                    tools: num(l, "<tool_uses>"),
                    ms: num(l, "<duration_ms>"),
                },
            );
        }
    }
}

pub(super) fn typed(l: &str) -> Option<(usize, &str)> {
    for (i, m) in l.match_indices("<command-name>/") {
        let from = i + m.len();
        let run: usize = l[from..]
            .chars()
            .take_while(|c| alnum(*c) || ":_.-".contains(*c))
            .count();
        if run > 0 && l[from + run..].starts_with("</command-name>") {
            return Some((i, &l[from..from + run]));
        }
    }
    None
}

pub(super) fn jsonl_files(dir: &Path, out: &mut Vec<PathBuf>) {
    let Ok(rd) = fs::read_dir(dir) else { return };
    for e in rd.flatten() {
        let p = e.path();
        if p.is_dir() {
            jsonl_files(&p, out);
        } else if p.extension().is_some_and(|x| x == "jsonl") {
            out.push(p);
        }
    }
}

pub(super) fn scan_transcripts(root: &Path, since: &str) -> Scan {
    let mut files = Vec::new();
    jsonl_files(root, &mut files);
    files.sort();
    let mut s = Scan::default();
    for f in files {
        let rel = f.strip_prefix(root).unwrap_or(&f);
        let parts: Vec<String> = rel
            .iter()
            .map(|p| p.to_string_lossy().into_owned())
            .collect();
        let proj = parts.first().cloned().unwrap_or_default();
        let sid = parts
            .get(1)
            .map(|p| p.strip_suffix(".jsonl").unwrap_or(p).to_string())
            .unwrap_or_default();
        let Ok(file) = fs::File::open(&f) else {
            continue;
        };
        let mut r = BufReader::new(file);
        let mut buf = Vec::new();
        while r.read_until(b'\n', &mut buf).is_ok_and(|n| n > 0) {
            let line = String::from_utf8_lossy(&buf);
            let l = line.trim_end_matches('\n');
            let hit = l.contains("\"name\":\"Skill\",\"input\":")
                || l.contains("\"name\":\"Agent\",\"input\":")
                || l.contains("<command-name>/")
                || l.contains("<task-notification>")
                || l.contains("\"type\":\"hook_");
            if hit && !skip_attachment(l) {
                s.line(l, &proj, &sid, since);
            }
            buf.clear();
        }
    }
    s
}

pub(super) struct Tables {
    pub(super) span: String,
    pub(super) vendors: Rows,
    pub(super) skills: Rows,
    pub(super) agents: Rows,
    pub(super) roles: Rows,
    pub(super) tasks: Rows,
    pub(super) hooks: Rows,
}

pub(super) fn tables_of(s: &Scan) -> Tables {
    let mut names: BTreeSet<&String> = s.skill_tool.keys().collect();
    names.extend(s.skill_typed.keys());
    let mut v: BTreeMap<String, u64> = BTreeMap::new();
    let mut skills = Rows::new();
    for n in names {
        let (t, ty) = (
            s.skill_tool.get(n).copied().unwrap_or(0),
            s.skill_typed.get(n).copied().unwrap_or(0),
        );
        let ns = s.skill_sessions.iter().filter(|k| &k.0 == n).count();
        let np = s.skill_projects.iter().filter(|k| &k.0 == n).count();
        skills.push(vec![
            vendor(n),
            n.clone(),
            t.to_string(),
            ty.to_string(),
            ns.to_string(),
            np.to_string(),
            s.skill_last.get(n).cloned().unwrap_or_default(),
        ]);
        *v.entry(vendor(n)).or_default() += t + ty;
    }
    #[derive(Default)]
    struct A {
        fin: u64,
        tok: u64,
        tls: u64,
        dur: u64,
        out: HashMap<String, u64>,
    }
    let mut per_type: HashMap<String, A> = HashMap::new();
    #[derive(Default)]
    struct Role {
        n: u64,
        tk: u64,
        tl: u64,
        ms: u64,
        tasks: HashSet<String>,
    }
    let mut roles: BTreeMap<String, Role> = BTreeMap::new();
    let mut task_tokens: BTreeMap<String, u64> = BTreeMap::new();
    let mut ids: Vec<&String> = s.notices.keys().collect();
    ids.sort();
    for tid in ids {
        let n = &s.notices[tid];
        let Some(t) = s.type_of.get(&n.tool_use) else {
            continue;
        };
        if let Some(nm) = s.name_of.get(&n.tool_use) {
            let role = nm.split('-').nth(1).unwrap_or("").to_string();
            let task: String = nm.chars().skip(role.chars().count() + 7).collect();
            let r = roles.entry(role).or_default();
            r.n += 1;
            r.tk += n.tokens;
            r.tl += n.tools;
            r.ms += n.ms;
            r.tasks.insert(task.clone());
            *task_tokens.entry(task).or_default() += n.tokens;
        }
        let a = per_type.entry(t.clone()).or_default();
        *a.out.entry(n.status.clone()).or_default() += 1;
        a.tok += n.tokens;
        a.tls += n.tools;
        a.dur += n.ms;
        a.fin += 1;
    }
    let mut agents = Rows::new();
    for (t, calls) in &s.agent_calls {
        let a = per_type.remove(t).unwrap_or_default();
        let (c, fl) = (
            a.out.get("completed").copied().unwrap_or(0),
            a.out.get("failed").copied().unwrap_or(0),
        );
        let n = a.fin.max(1) as f64;
        let models: Vec<String> = s
            .agent_models
            .iter()
            .filter(|k| &k.0 .0 == t)
            .map(|k| format!("{}={}", k.0 .1, k.1))
            .collect();
        let vd = if t.contains(':') {
            vendor(t)
        } else {
            "built-in".into()
        };
        agents.push(vec![
            vd.clone(),
            t.clone(),
            calls.to_string(),
            a.fin.to_string(),
            c.to_string(),
            fl.to_string(),
            (a.fin - c - fl).to_string(),
            ((a.tok as f64 / n) as u64).to_string(),
            f1(a.tls as f64 / n),
            f0(a.dur as f64 / n / 1000.0),
            models.join(" "),
        ]);
        *v.entry(vd).or_default() += calls;
    }
    let roles_rows = roles
        .iter()
        .map(|(r, x)| {
            let n = x.n as f64;
            vec![
                r.clone(),
                x.n.to_string(),
                x.tk.to_string(),
                ((x.tk as f64 / n) as u64).to_string(),
                f1(x.tl as f64 / n),
                f0(x.ms as f64 / n / 1000.0),
                x.tl.to_string(),
                x.tasks.len().to_string(),
            ]
        })
        .collect();
    let hooks = s
        .hooks
        .iter()
        .map(|(k, c)| {
            let ns = s
                .hook_sessions
                .iter()
                .filter(|h| h.0 == k.0 && h.1 == k.1)
                .count();
            vec![
                k.0.clone(),
                k.1.clone(),
                c[0].to_string(),
                c[1].to_string(),
                c[2].to_string(),
                ns.to_string(),
                s.hook_last.get(k).cloned().unwrap_or_default(),
            ]
        })
        .collect();
    Tables {
        span: format!("{} to {}", s.min, s.max),
        vendors: sorted(
            v.into_iter().map(|(k, n)| vec![k, n.to_string()]).collect(),
            &[(1, true)],
        ),
        skills: sorted(skills, &[(0, false), (2, true), (3, true)]),
        agents: sorted(agents, &[(0, false), (2, true)]),
        roles: roles_rows,
        tasks: sorted(
            task_tokens
                .into_iter()
                .map(|(k, n)| vec![k, n.to_string()])
                .collect(),
            &[(1, true)],
        )
        .into_iter()
        .take(15)
        .collect(),
        hooks: sorted(hooks, &[(0, false), (2, true)]),
    }
}

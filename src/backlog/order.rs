use super::index::{Entry, Index};
use super::{arg, die, opt_val, usage_die, Ctx, Fail, Io, R};
use std::collections::{HashMap, HashSet};
use std::fmt::Write as _;

pub struct OEntry {
    pub id: String,
    pub title: String,
    pub prio: Option<String>,
    pub deps: String,
}

#[derive(Default)]
pub struct Opts {
    pub mode: String,
    pub rank: String,
    pub infer: Vec<String>,
    pub defer: String,
    pub only: String,
    pub first: bool,
}

fn cyc(v: &str, eff: &HashMap<String, String>, st: &mut HashMap<String, u8>) -> bool {
    match st.get(v) {
        Some(1) => return true,
        Some(_) => return false,
        None => {}
    }
    st.insert(v.into(), 1);
    if let Some(d) = eff.get(v) {
        if d.split(',').any(|x| !x.is_empty() && cyc(x, eff, st)) {
            return true;
        }
    }
    st.insert(v.into(), 2);
    false
}

fn squash(v: &str) -> String {
    v.chars().filter(|c| *c != ' ' && *c != '\t').collect()
}

fn num(p: &Option<String>) -> f64 {
    p.as_deref().and_then(|s| s.parse().ok()).unwrap_or(0.0)
}

struct Built<'a> {
    es: &'a [OEntry],
    order: Vec<usize>,
    eff: HashMap<String, String>,
    deferred: HashSet<String>,
    violated: Vec<(String, String)>,
}

fn build<'a>(es: &'a [OEntry], o: &Opts) -> Result<Built<'a>, String> {
    let n = es.len();
    let pos: HashMap<&str, usize> = es
        .iter()
        .enumerate()
        .map(|(i, e)| (e.id.as_str(), i))
        .collect();
    let un = es.iter().filter(|e| e.prio.is_none()).count();
    let mut rankpos: HashMap<String, usize> = HashMap::new();
    if !o.rank.is_empty() {
        for v in o.rank.split(',').map(squash).filter(|v| !v.is_empty()) {
            let Some(&p) = pos.get(v.as_str()) else {
                return Err(format!("--rank: no such task id: {v}"));
            };
            if es[p].prio.is_some() {
                return Err(format!("--rank: {v} already has a priority"));
            }
            if rankpos.contains_key(&v) {
                return Err(format!("--rank: duplicate id: {v}"));
            }
            rankpos.insert(v, rankpos.len() + 1);
        }
        if rankpos.len() != un {
            return Err(format!(
                "--rank must name every unset-priority id exactly once: {un} expected, {} given",
                rankpos.len()
            ));
        }
    }
    let mut eff: HashMap<String, String> =
        es.iter().map(|e| (e.id.clone(), e.deps.clone())).collect();
    for p in o.infer.iter().filter(|p| !p.is_empty()) {
        let Some((a, b)) = p.split_once('=') else {
            return Err(format!("--infer-deps needs <id>=<csv>, got: {p}"));
        };
        let Some(&ai) = pos.get(a) else {
            return Err(format!("--infer-deps: no such task id: {a}"));
        };
        if !es[ai].deps.is_empty() {
            return Err(format!(
                "--infer-deps: {a} already has depends_on in the index"
            ));
        }
        for t in b.split(',').filter(|t| !t.is_empty()) {
            if !pos.contains_key(t) {
                return Err(format!("--infer-deps: no such task id: {t}"));
            }
            if t == a {
                return Err(format!("--infer-deps: {a} cannot depend on itself"));
            }
        }
        eff.insert(a.into(), b.into());
    }
    let mut deferred = HashSet::new();
    for d in o.defer.split(',').filter(|d| !d.is_empty()) {
        if !pos.contains_key(d) {
            return Err(format!("--defer: no such task id: {d}"));
        }
        deferred.insert(d.to_string());
    }
    let mut st = HashMap::new();
    for e in es {
        if cyc(&e.id, &eff, &mut st) {
            return Err(format!(
                "--infer-deps would create a cycle through {}",
                e.id
            ));
        }
    }
    let key = |i: usize| {
        let e = &es[i];
        match &e.prio {
            None => (
                1,
                0.0,
                if rankpos.is_empty() {
                    i + 1
                } else {
                    rankpos[&e.id]
                } as f64,
            ),
            Some(_) => (0, -num(&e.prio), (i + 1) as f64),
        }
    };
    let mut l: Vec<usize> = (0..n).collect();
    l.sort_by(|&x, &y| {
        let (a, b) = (key(x), key(y));
        a.0.cmp(&b.0)
            .then(a.1.total_cmp(&b.1))
            .then(a.2.total_cmp(&b.2))
    });
    let index_at = |l: &[usize]| -> HashMap<&str, usize> {
        l.iter()
            .enumerate()
            .map(|(k, &i)| (es[i].id.as_str(), k + 1))
            .collect()
    };
    let mut at = index_at(&l);
    let mut violated = vec![];
    for (k, &i) in l.iter().enumerate() {
        for d in eff[&es[i].id].split(',').filter(|d| !d.is_empty()) {
            if at.get(d).copied().unwrap_or(0) > k + 1 {
                violated.push((d.to_string(), es[i].id.clone()));
            }
        }
    }
    let mut k = 1;
    while k <= n {
        let mut d: Vec<usize> = eff[&es[l[k - 1]].id]
            .split(',')
            .filter(|d| !d.is_empty())
            .filter_map(|d| at.get(d).copied().filter(|&p| p > k))
            .collect();
        if d.is_empty() {
            k += 1;
            continue;
        }
        d.sort_unstable();
        d.dedup();
        let mut nl = Vec::with_capacity(n);
        for b in 1..=n {
            if d.contains(&b) {
                continue;
            }
            if b == k {
                nl.extend(d.iter().map(|&p| l[p - 1]));
            }
            nl.push(l[b - 1]);
        }
        l = nl;
        at = index_at(&l);
    }
    if o.first {
        deferred.extend(l.iter().skip(1).map(|&i| es[i].id.clone()));
    }
    if !o.only.is_empty() {
        let mut keep = HashSet::new();
        for v in o.only.split(',').map(squash).filter(|v| !v.is_empty()) {
            if !pos.contains_key(v.as_str()) {
                return Err(format!("--only: no such task id: {v}"));
            }
            keep.insert(v);
        }
        deferred.extend(
            es.iter()
                .filter(|e| !keep.contains(&e.id))
                .map(|e| e.id.clone()),
        );
    }
    Ok(Built {
        es,
        order: l,
        eff,
        deferred,
        violated,
    })
}

pub fn compute(es: &[OEntry], o: &Opts) -> Result<(i32, String), String> {
    if o.mode == "rank-needed" {
        let un: String = es
            .iter()
            .filter(|e| e.prio.is_none())
            .map(|e| format!("{}\n", e.id))
            .collect();
        return Ok((i32::from(un.is_empty()), un));
    }
    let b = build(es, o)?;
    let mut out = String::new();
    match o.mode.as_str() {
        "report" => {
            for (k, &i) in b.order.iter().enumerate() {
                let _ = writeln!(out, "{}. {} (id: {})", k + 1, es[i].title, es[i].id);
            }
            let prio = |id: &str| {
                es.iter()
                    .rev()
                    .find(|e| e.id == id)
                    .and_then(|e| e.prio.clone())
            };
            for (dep, ent) in &b.violated {
                let pe = prio(ent);
                if pe.is_none() && prio(dep).is_none() {
                    continue;
                }
                let _ = writeln!(
                    out,
                    "dependency override: {dep} moved above {ent} (priority {})",
                    pe.as_deref().unwrap_or("unset")
                );
            }
        }
        "steps" => {
            for (k, &i) in b.order.iter().enumerate() {
                let e = &b.es[i];
                let state = if b.deferred.contains(&e.id) {
                    "deferred"
                } else {
                    "pending"
                };
                let _ = writeln!(out, "{}\t{}\t{}\t{state}", e.id, k + 1, b.eff[&e.id]);
            }
        }
        m => return Err(format!("unknown mode: {m}")),
    }
    Ok((0, out))
}

pub fn ambiguous(idx: &Index, hits: &[usize], q: &str) -> Fail {
    Fail {
        code: 2,
        msg: format!(
            "radin-backlog: \"{q}\" matches several entries:\n{}",
            idx.rows(hits, "candidate\t")
        ),
    }
}

fn oentries(idx: &Index) -> Vec<OEntry> {
    idx.entries
        .iter()
        .map(|e: &Entry| OEntry {
            id: e.id(),
            title: e.title(),
            prio: e.priority(),
            deps: e.depends_on().join(","),
        })
        .collect()
}

fn resolve_only(idx: &Index, es: &[OEntry], o: &Opts, io: &mut Io) -> Result<String, Fail> {
    let mut ids = vec![];
    for r in o.only.split(',').map(str::trim).filter(|r| !r.is_empty()) {
        if r.bytes().all(|b| b.is_ascii_digit()) {
            let rep = Opts {
                mode: "report".into(),
                rank: o.rank.clone(),
                infer: o.infer.clone(),
                ..Opts::default()
            };
            let order = match build(es, &rep) {
                Ok(b) => b.order,
                Err(m) => {
                    io.err.push_str(&format!("radin-backlog: {m}\n"));
                    vec![]
                }
            };
            let id = r
                .parse::<usize>()
                .ok()
                .filter(|&k| r == k.to_string() && k >= 1);
            match id.and_then(|k| order.get(k - 1)) {
                Some(&i) => ids.push(es[i].id.clone()),
                None => return Err(die("--only: no task at that order number")),
            }
        } else {
            match idx.matches(r).as_slice() {
                [] => ids.push(r.to_string()),
                [i] => ids.push(idx.entries[*i].id()),
                hits => return Err(ambiguous(idx, hits, r)),
            }
        }
    }
    Ok(ids.join(","))
}

fn order_with(idx: &Index, a: &[String], io: &mut Io) -> R {
    let mut o = Opts::default();
    let mut i = 0;
    while i < a.len() {
        let f = a[i].as_str();
        match f {
            "--rank-needed" | "--report" | "--steps" => {
                if !o.mode.is_empty() {
                    return Err(usage_die(
                        "order",
                        &format!("order takes exactly one mode, got --{} and {f}", o.mode),
                    ));
                }
                o.mode = f[2..].to_string();
                i += 1;
                continue;
            }
            "--first" => {
                o.first = true;
                i += 1;
                continue;
            }
            "--rank" => o.rank = opt_val(a, i, "order", "--rank needs a csv of task ids")?.into(),
            "--infer-deps" => o
                .infer
                .push(opt_val(a, i, "order", "--infer-deps needs <id>=<csv>")?.into()),
            "--defer" => {
                o.defer = opt_val(a, i, "order", "--defer needs a csv of task ids")?.into()
            }
            "--only" => o.only = opt_val(a, i, "order", "--only needs a csv of task ids")?.into(),
            _ => return Err(usage_die("order", &format!("unknown order option: {f}"))),
        }
        i += 2;
    }
    if o.mode.is_empty() {
        return Err(usage_die(
            "order",
            "order needs one of --rank-needed, --report, --steps",
        ));
    }
    let picked = [!o.defer.is_empty(), !o.only.is_empty(), o.first];
    if picked.iter().filter(|p| **p).count() > 1 {
        return Err(usage_die(
            "order",
            "order takes at most one of --only, --first, --defer",
        ));
    }
    let es = oentries(idx);
    if !o.only.is_empty() {
        o.only = resolve_only(idx, &es, &o, io)?;
    }
    let (code, out) = compute(&es, &o).map_err(die)?;
    io.out.push_str(&out);
    Ok(code)
}

pub fn order(cx: &Ctx, a: &[String], io: &mut Io) -> R {
    order_with(&cx.require()?, a, io)
}

pub fn suggest(cx: &Ctx, a: &[String], io: &mut Io) -> R {
    let idx = cx.require()?;
    let th = cx.env.epic_threshold.as_deref().unwrap_or("20");
    if th.starts_with('0') || !th.bytes().all(|b| b.is_ascii_digit()) {
        return Err(die(format!(
            "suggest: RADIN_EPIC_THRESHOLD needs a positive integer, got: {th}"
        )));
    }
    let total = idx.entries.len();
    let epics: HashMap<String, String> = idx.entries.iter().map(|e| (e.id(), e.epic())).collect();
    let mut sub = Io::default();
    let args: Vec<String> = ["--steps".to_string()]
        .into_iter()
        .chain(a.iter().cloned())
        .collect();
    let code = order_with(&idx, &args, &mut sub);
    io.err.push_str(&sub.err);
    if let Err(f) = code {
        io.err.push_str(&f.msg);
    }
    let ids: Vec<&str> = sub
        .out
        .lines()
        .filter_map(|l| l.split('\t').next())
        .collect();
    let top = ids
        .iter()
        .find_map(|id| epics.get(*id).filter(|e| !e.is_empty()));
    let count = top.map_or(0, |t| {
        ids.iter().filter(|id| epics.get(**id) == Some(t)).count()
    });
    let pick = if top.is_some() && total > th.parse().unwrap_or(usize::MAX) {
        "epic"
    } else {
        "all"
    };
    let _ = writeln!(io.out, "tasks\t{total}\t{pick}");
    if let Some(t) = top {
        let _ = writeln!(io.out, "epic\t{t}\t{count}");
    }
    Ok(0)
}

pub fn scope(cx: &Ctx, a: &[String], io: &mut Io) -> R {
    let q = arg(a, 0);
    if q.is_empty() {
        return Err(usage_die(
            "scope",
            "scope needs an epic id, task id or title",
        ));
    }
    if a.len() > 1 {
        return Err(usage_die(
            "scope",
            &format!("scope takes one argument, got: {}", a[1]),
        ));
    }
    let idx = cx.require()?;
    let seeds: Vec<String> = if cx.ns.backlog_tasks_dir.join(q).is_dir() {
        idx.entries
            .iter()
            .filter(|e| e.epic() == q)
            .map(Entry::id)
            .collect()
    } else {
        let hits = idx.matches(q);
        if hits.len() > 1 {
            return Err(ambiguous(&idx, &hits, q));
        }
        hits.iter().map(|&i| idx.entries[i].id()).collect()
    };
    let ids: HashSet<String> = idx.entries.iter().map(Entry::id).collect();
    let mut inc: HashSet<String> = seeds.iter().filter(|s| ids.contains(*s)).cloned().collect();
    let seed = inc.clone();
    loop {
        let more: Vec<String> = idx
            .entries
            .iter()
            .filter(|e| inc.contains(&e.id()))
            .flat_map(Entry::depends_on)
            .filter(|d| ids.contains(d) && !inc.contains(d))
            .collect();
        if more.is_empty() {
            break;
        }
        inc.extend(more);
    }
    let all: Vec<String> = idx
        .entries
        .iter()
        .map(Entry::id)
        .filter(|i| inc.contains(i))
        .collect();
    if all.is_empty() {
        return Err(die(format!("no entry matches: {q}")));
    }
    let _ = writeln!(io.out, "ids\t{}", all.join(","));
    let extra: Vec<&str> = all
        .iter()
        .map(String::as_str)
        .filter(|i| !seed.contains(*i))
        .collect();
    if !extra.is_empty() {
        let _ = writeln!(io.out, "dependencies\t{}", extra.join(","));
    }
    Ok(0)
}

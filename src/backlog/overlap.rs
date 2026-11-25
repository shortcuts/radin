use super::epic::require_epic_id;
use super::graph::{self, Edge, Gap};
use super::index::Index;
use super::plan::changes_of;
use super::{arg, die, usage_die, Ctx, Io, R};
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::Path;

// shortcut: GRAPH_EXT is a fixed list, add an extension when a language is missed
const GRAPH_EXT: &[&str] = &[
    "rs", "py", "js", "jsx", "ts", "tsx", "mjs", "cjs", "go", "java", "kt", "kts", "scala", "c",
    "h", "cc", "cpp", "cxx", "hpp", "cs", "rb", "php", "swift", "lua", "sh",
];

#[derive(Default)]
struct Side {
    files: BTreeMap<String, BTreeSet<String>>,
    dirs: BTreeSet<String>,
}

fn normalize(p: &str) -> String {
    let mut p = p;
    while let Some(r) = p.strip_prefix("./") {
        p = r;
    }
    p.trim_end_matches('/').to_string()
}

fn safe(p: &str) -> bool {
    !p.is_empty()
        && !p.starts_with('/')
        && p != ".radin"
        && !p.starts_with(".radin/")
        && !p.starts_with(".git/")
        && !p.split('/').any(|c| c == "..")
}

fn strip_line(loc: &str) -> &str {
    match loc.rsplit_once(':') {
        Some((p, n)) if !n.is_empty() && n.bytes().all(|b| b.is_ascii_digit()) => p,
        _ => loc,
    }
}

fn cited(text: &str, exists: impl Fn(&str) -> bool) -> Vec<String> {
    let set: BTreeSet<String> = text
        .split(|c: char| !(c.is_ascii_alphanumeric() || "_./-".contains(c)))
        .map(|t| normalize(t).trim_end_matches('.').to_string())
        .filter(|t| safe(t) && exists(t))
        .collect();
    set.into_iter().collect()
}

fn add(side: &mut Side, root: &Path, raw: &str, id: &str) {
    let p = normalize(raw);
    if !safe(&p) {
        return;
    }
    if raw.ends_with('/') || root.join(&p).is_dir() {
        side.dirs.insert(p);
    } else {
        side.files.entry(p).or_default().insert(id.to_string());
    }
}

fn collect(cx: &Ctx, idx: &Index, epic: &str, io: &mut Io) -> Side {
    let root = &cx.ns.repo_root;
    let mut side = Side::default();
    for e in idx.entries.iter().filter(|e| e.epic() == epic) {
        if let Some(loc) = e.opt("location") {
            add(&mut side, root, strip_line(&loc), &e.id());
        }
        for pf in e.arr("plan") {
            match fs::read_to_string(root.join(&pf)) {
                Ok(t) => changes_of(&t)
                    .iter()
                    .for_each(|p| add(&mut side, root, p, &e.id())),
                Err(_) => io
                    .err
                    .push_str(&format!("radin-backlog: plan file not found: {pf}\n")),
            }
        }
        let body = fs::read_to_string(idx.entry_path(e)).unwrap_or_default();
        for p in cited(&body, |t| root.join(t).is_file()) {
            add(&mut side, root, &p, &e.id());
        }
    }
    side
}

fn is_graph_file(root: &Path, f: &str) -> bool {
    let ext = f.rsplit_once('.').map(|(_, x)| x.to_ascii_lowercase());
    ext.is_some_and(|x| GRAPH_EXT.contains(&x.as_str())) && root.join(f).is_file()
}

type Near<'a> = (BTreeSet<&'a str>, BTreeSet<&'a str>);

fn symbols(edges: &[Edge], a: &BTreeSet<String>, b: &BTreeSet<String>) -> BTreeSet<String> {
    let mut out = BTreeSet::new();
    let mut near: BTreeMap<(&str, &str), Near> = BTreeMap::new();
    for e in edges {
        let (s, d) = (e.src_file.as_str(), e.dst_file.as_str());
        let side = |f: &str| (a.contains(f), b.contains(f));
        match (side(s), side(d)) {
            ((true, _), (_, true)) => out.insert(format!(
                "symbol\tcall\ta\t{}\t{s}\tb\t{}\t{d}",
                e.src_qn, e.dst_qn
            )),
            ((_, true), (true, _)) => out.insert(format!(
                "symbol\tcall\tb\t{}\t{s}\ta\t{}\t{d}",
                e.src_qn, e.dst_qn
            )),
            (x, y) => {
                let (inside, f, out_qn, out_f) = match (x, y) {
                    ((true, _) | (_, true), (false, false)) => (x, s, &e.dst_qn, d),
                    ((false, false), (true, _) | (_, true)) => (y, d, &e.src_qn, s),
                    _ => continue,
                };
                let n = near.entry((out_qn, out_f)).or_default();
                if inside.0 {
                    n.0.insert(f);
                } else {
                    n.1.insert(f);
                }
                continue;
            }
        };
    }
    for ((qn, f), (fa, fb)) in near {
        if !fa.is_empty() && !fb.is_empty() {
            let csv = |s: BTreeSet<&str>| s.into_iter().collect::<Vec<_>>().join(",");
            out.insert(format!(
                "symbol\tcommon\t{qn}\t{f}\t{}\t{}",
                csv(fa),
                csv(fb)
            ));
        }
    }
    out
}

fn record_gap(cx: &Ctx, a: &str, b: &str, gaps: &[Gap], io: &mut Io) {
    let kinds: BTreeSet<&str> = gaps.iter().map(|g| g.kind).collect();
    let pairs = [
        format!("epic_a={a}"),
        format!("epic_b={b}"),
        format!("gaps={}", gaps.len()),
        format!("kinds={}", kinds.into_iter().collect::<Vec<_>>().join(",")),
        format!("detail={}", gaps[0].detail),
    ];
    let (_, _, err) =
        crate::telemetry::record(&cx.env.cwd, &cx.env.home, "overlap", "setup-issue", &pairs);
    io.err.push_str(&err);
}

pub fn overlap(cx: &Ctx, a: &[String], io: &mut Io) -> R {
    if a.len() != 2 {
        return Err(usage_die("overlap", "overlap needs <epic-a> <epic-b>"));
    }
    let (ea, eb) = (arg(a, 0), arg(a, 1));
    require_epic_id(cx, ea)?;
    require_epic_id(cx, eb)?;
    if ea == eb {
        return Err(die(format!(
            "overlap needs two different epics, got {ea} twice"
        )));
    }
    let idx = Index::load(cx.ns.backlog_index.clone())?;
    let (sa, sb) = (collect(cx, &idx, ea, io), collect(cx, &idx, eb, io));
    let root = &cx.ns.repo_root;
    let (ka, kb): (BTreeSet<&String>, BTreeSet<&String>) =
        (sa.files.keys().collect(), sb.files.keys().collect());
    let files: Vec<&&String> = ka.intersection(&kb).collect();
    let dirs: BTreeSet<&String> = sa.dirs.intersection(&sb.dirs).collect();
    let graph_side = |s: &Side, o: &Side| -> BTreeSet<String> {
        s.files
            .keys()
            .filter(|f| !o.files.contains_key(*f) && is_graph_file(root, f))
            .cloned()
            .collect()
    };
    let (ga, gb) = (graph_side(&sa, &sb), graph_side(&sb, &sa));
    let mut gaps: Vec<Gap> = vec![];
    let mut sym = BTreeSet::new();
    if !ga.is_empty() && !gb.is_empty() {
        let all: Vec<String> = ga.iter().chain(&gb).cloned().collect();
        match graph::load(root, &all) {
            Ok(edges) => sym = symbols(&edges, &ga, &gb),
            Err(g) => gaps = g,
        }
    }
    io.out.push_str(&format!(
        "tiers\tfile={}\tsymbol={}\tdirectory={}\n",
        files.len(),
        sym.len(),
        dirs.len()
    ));
    io.out.push_str(&format!(
        "known\ta={}\tb={}\n",
        sa.files.len(),
        sb.files.len()
    ));
    let csv = |s: &BTreeSet<String>| s.iter().cloned().collect::<Vec<_>>().join(",");
    for f in &files {
        let (ia, ib) = (&sa.files[**f], &sb.files[**f]);
        io.out
            .push_str(&format!("file\t{f}\t{}\t{}\n", csv(ia), csv(ib)));
    }
    sym.iter().for_each(|s| io.out.push_str(&format!("{s}\n")));
    dirs.iter()
        .for_each(|d| io.out.push_str(&format!("directory\t{d}\n")));
    if gaps.is_empty() {
        return Ok(0);
    }
    for g in &gaps {
        io.out.push_str(&format!(
            "gap\t{}\t{}\n",
            g.kind,
            g.detail.replace(['\t', '\n'], " ")
        ));
    }
    io.err.push_str(&format!(
        "radin-backlog: overlap: {} graph gap(s)\n",
        gaps.len()
    ));
    record_gap(cx, ea, eb, &gaps, io);
    Ok(2)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn edge(sq: &str, sf: &str, dq: &str, df: &str) -> Edge {
        Edge {
            src_qn: sq.into(),
            src_file: sf.into(),
            dst_qn: dq.into(),
            dst_file: df.into(),
        }
    }

    fn set(v: &[&str]) -> BTreeSet<String> {
        v.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn cited_keeps_existing_files_and_drops_line_suffixes_dots_and_state_paths() {
        let exists = |t: &str| t == "src/a.rs" || t == "x/y.md";
        let text =
            "see src/a.rs:12, ./src/a.rs. also ../src/a.rs /src/a.rs .radin/x.md docs x/y.md";
        assert_eq!(cited(text, exists), vec!["src/a.rs", "x/y.md"]);
    }

    #[test]
    fn normalize_strips_dot_slash_and_trailing_slash() {
        assert_eq!(normalize("./././src/"), "src");
        assert_eq!(normalize("a/b.rs"), "a/b.rs");
    }

    #[test]
    fn strip_line_removes_only_a_numeric_suffix() {
        assert_eq!(strip_line("src/a.rs:12"), "src/a.rs");
        assert_eq!(strip_line("src/a.rs:x"), "src/a.rs:x");
        assert_eq!(strip_line("src/a.rs"), "src/a.rs");
    }

    #[test]
    fn symbols_derive_cross_epic_calls_and_a_shared_neighbour() {
        let (a, b) = (set(&["a.rs"]), set(&["b.rs"]));
        let edges = [
            edge("a_fn", "a.rs", "b_fn", "b.rs"),
            edge("a_fn", "a.rs", "util", "u.rs"),
            edge("b_fn", "b.rs", "util", "u.rs"),
            edge("a_fn", "a.rs", "a_two", "a.rs"),
            edge("only_a", "a.rs", "lone", "l.rs"),
        ];
        let got: Vec<String> = symbols(&edges, &a, &b).into_iter().collect();
        assert_eq!(
            got,
            vec![
                "symbol\tcall\ta\ta_fn\ta.rs\tb\tb_fn\tb.rs",
                "symbol\tcommon\tutil\tu.rs\ta.rs\tb.rs",
            ]
        );
    }

    #[test]
    fn symbols_report_a_call_from_b_to_a() {
        let (a, b) = (set(&["a.rs"]), set(&["b.rs"]));
        let got = symbols(&[edge("b_fn", "b.rs", "a_fn", "a.rs")], &a, &b);
        assert_eq!(
            got.into_iter().collect::<Vec<_>>(),
            vec!["symbol\tcall\tb\tb_fn\tb.rs\ta\ta_fn\ta.rs"]
        );
    }
}

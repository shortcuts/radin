#[path = "common/cli.rs"]
mod cli;
mod common;

use cli::{radin_with, stub, Run};
use std::fs;
use std::path::PathBuf;
use tempfile::TempDir;

struct W {
    _t: TempDir,
    root: PathBuf,
    home: PathBuf,
    bin: PathBuf,
}

impl W {
    fn new() -> W {
        let t = tempfile::tempdir().unwrap();
        let root = t.path().canonicalize().unwrap();
        let (home, bin) = (root.join("home"), root.join("bin"));
        fs::create_dir_all(&home).unwrap();
        fs::create_dir_all(&bin).unwrap();
        let proj = root.join("proj");
        fs::create_dir_all(proj.join(".radin/backlog/tasks")).unwrap();
        let w = W {
            _t: t,
            root,
            home,
            bin,
        };
        stub(
            &w.bin,
            "codebase-memory-mcp",
            "echo \"$*\" >> \"$STUB/calls.log\"\nf=\"$STUB/$2.json\"\n[ -f \"$f\" ] || { echo '{\"error\":\"stub\"}' >&2; exit 1; }\ncat \"$f\"\n",
        );
        w
    }

    fn proj(&self) -> PathBuf {
        self.root.join("proj")
    }

    fn write(&self, rel: &str, text: &str) {
        let p = self.proj().join(rel);
        fs::create_dir_all(p.parent().unwrap()).unwrap();
        fs::write(p, text).unwrap();
    }

    fn task(&self, epic: &str, id: &str, location: &str, body: &str) -> String {
        let file = format!("tasks/{epic}/{id}.md");
        self.write(&format!(".radin/backlog/{file}"), body);
        format!(
            "{{\"id\":\"{id}\",\"category\":\"feat\",\"title\":\"{id}\",\"file\":\"{file}\",\"location\":\"{location}\"}}\n"
        )
    }

    fn index(&self, lines: &[String]) {
        self.write(".radin/backlog/index.jsonl", &lines.concat());
    }

    fn stub_json(&self, tool: &str, json: &str) {
        fs::write(self.root.join(format!("{tool}.json")), json).unwrap();
    }

    fn calls(&self) -> String {
        fs::read_to_string(self.root.join("calls.log")).unwrap_or_default()
    }

    fn overlap(&self, path_has_stub: bool) -> Run {
        let path = if path_has_stub {
            format!("{}:/usr/bin:/bin", self.bin.display())
        } else {
            "/usr/bin:/bin".to_string()
        };
        self.run(&["backlog", "overlap", "a", "b"], &path)
    }

    fn run(&self, args: &[&str], path: &str) -> Run {
        radin_with(
            &self.proj(),
            &self.home,
            args,
            "",
            &[("PATH", path), ("STUB", self.root.to_str().unwrap())],
        )
    }

    fn telemetry(&self) -> String {
        fs::read_to_string(self.home.join(".radin/telemetry/overlap.jsonl")).unwrap_or_default()
    }

    fn epics(&self) {
        for e in ["a", "b"] {
            fs::create_dir_all(self.proj().join(format!(".radin/backlog/tasks/{e}"))).unwrap();
        }
    }

    fn rust_epics(&self) {
        self.epics();
        for f in ["src/a.rs", "src/b.rs", "lib/shared.rs"] {
            self.write(f, "fn f() {}\n");
        }
        self.index(&[
            self.task("a", "ta", "src/a.rs:3", "uses lib/shared.rs"),
            self.task("b", "tb", "src/b.rs", "uses lib/shared.rs"),
        ]);
    }

    fn healthy_graph(&self, rows: &str) {
        let p = self.proj();
        self.stub_json(
            "list_projects",
            &format!(
                "{{\"projects\":[{{\"name\":\"p\",\"root_path\":\"{}\"}}]}}",
                p.display()
            ),
        );
        self.stub_json(
            "query_graph",
            &format!("{{\"rows\":{rows},\"has_more\":false,\"truncated\":false}}"),
        );
        self.coverage("metadata_match");
    }

    fn coverage(&self, a_freshness: &str) {
        let row = |f: &str, fr: &str| {
            format!("{{\"path\":\"{f}\",\"status\":\"no_recorded_issue\",\"freshness\":\"{fr}\"}}")
        };
        self.stub_json(
            "check_index_coverage",
            &format!(
                "{{\"paths\":[{},{}],\"path_has_more\":false}}",
                row("src/a.rs", a_freshness),
                row("src/b.rs", "metadata_match")
            ),
        );
    }
}

#[test]
fn file_and_directory_tiers_need_no_graph() {
    let w = W::new();
    w.epics();
    w.write("docs/x.md", "x");
    w.write("docs/y.md", "y");
    w.index(&[
        w.task("a", "ta", "docs/x.md", "notes"),
        w.task("b", "tb", "docs/y.md", "see docs/x.md:4"),
    ]);
    let r = w.overlap(true);
    assert_eq!(r.code, 0, "{}", r.err);
    assert_eq!(
        r.out,
        "tiers\tfile=1\tsymbol=0\tdirectory=0\nknown\ta=1\tb=2\nfile\tdocs/x.md\tta\ttb\n"
    );
    assert_eq!(w.calls(), "");
}

#[test]
fn a_directory_counts_only_when_a_task_names_it() {
    let w = W::new();
    w.epics();
    w.write("docs/x.md", "x");
    w.index(&[
        w.task("a", "ta", "docs/", "notes"),
        w.task("b", "tb", "docs", "notes"),
    ]);
    let r = w.overlap(true);
    assert_eq!(r.code, 0, "{}", r.err);
    assert_eq!(
        r.out,
        "tiers\tfile=0\tsymbol=0\tdirectory=1\nknown\ta=0\tb=0\ndirectory\tdocs\n"
    );
}

#[test]
fn symbol_tier_prints_call_and_common_evidence() {
    let w = W::new();
    w.rust_epics();
    w.healthy_graph(
        "[[\"p.a_fn\",\"src/a.rs\",\"p.b_fn\",\"src/b.rs\"],[\"p.a_fn\",\"src/a.rs\",\"p.util\",\"u.rs\"],[\"p.b_fn\",\"src/b.rs\",\"p.util\",\"u.rs\"]]",
    );
    let r = w.overlap(true);
    assert_eq!(r.code, 0, "{}", r.err);
    assert_eq!(
        r.out,
        "tiers\tfile=1\tsymbol=2\tdirectory=0\nknown\ta=2\tb=2\nfile\tlib/shared.rs\tta\ttb\n\
symbol\tcall\ta\ta_fn\tsrc/a.rs\tb\tb_fn\tsrc/b.rs\n\
symbol\tcommon\tutil\tu.rs\tsrc/a.rs\tsrc/b.rs\n"
    );
    let q = w
        .calls()
        .lines()
        .find(|l| l.contains("query_graph"))
        .unwrap()
        .to_string();
    assert!(
        q.contains("src/a.rs") && q.contains("src/b.rs") && !q.contains("lib/shared.rs"),
        "{q}"
    );
}

#[test]
fn every_graph_gap_exits_2_and_records_telemetry() {
    type Setup = fn(&W);
    let cases: [(&str, bool, Setup, &str, bool); 5] = [
        ("graph-cli", false, |_| {}, "graph-cli", false),
        (
            "not-indexed",
            true,
            |w| w.stub_json("list_projects", "{\"projects\":[]}"),
            "not-indexed",
            false,
        ),
        (
            "stale",
            true,
            |w| w.coverage("metadata_changed"),
            "stale\tsrc/a.rs freshness=metadata_changed status=no_recorded_issue",
            false,
        ),
        (
            "truncated",
            true,
            |w| w.stub_json("query_graph", "{\"rows\":[],\"has_more\":true}"),
            "truncated",
            true,
        ),
        (
            "unqueryable",
            true,
            |w| {
                w.write("src/q\"x.rs", "fn f() {}\n");
                w.index(&[
                    w.task("a", "ta", "src/q\\\"x.rs", "x"),
                    w.task("b", "tb", "src/b.rs", "x"),
                ]);
            },
            "unqueryable\tsrc/q\"x.rs",
            false,
        ),
    ];
    for (kind, stubbed, setup, line, queried) in cases {
        let w = W::new();
        w.rust_epics();
        w.healthy_graph("[]");
        setup(&w);
        let r = w.overlap(stubbed);
        assert_eq!(r.code, 2, "{kind}: {}{}", r.out, r.err);
        assert!(r.out.contains("symbol=0"), "{kind}: {}", r.out);
        assert!(r.out.contains(&format!("gap\t{line}")), "{kind}: {}", r.out);
        assert!(
            r.err.contains("overlap: 1 graph gap(s)"),
            "{kind}: {}",
            r.err
        );
        assert_eq!(w.calls().contains("query_graph"), queried, "{kind}");
        let t = w.telemetry();
        assert_eq!(t.lines().count(), 1, "{kind}: {t}");
        assert!(
            t.contains("\"kind\":\"setup-issue\"") && t.contains(&format!("\"kinds\":\"{kind}\"")),
            "{kind}: {t}"
        );
    }
}

#[test]
fn unknown_epic_and_same_epic_exit_1() {
    let w = W::new();
    w.rust_epics();
    let r = w.run(&["backlog", "overlap", "a", "nope"], "/usr/bin:/bin");
    assert_eq!(
        (r.code, r.err.as_str()),
        (1, "radin-backlog: no such epic: nope\n")
    );
    let r = w.run(&["backlog", "overlap", "a", "a"], "/usr/bin:/bin");
    assert_eq!(
        (r.code, r.err.as_str()),
        (
            1,
            "radin-backlog: overlap needs two different epics, got a twice\n"
        )
    );
    let r = w.run(&["backlog", "overlap", "a"], "/usr/bin:/bin");
    assert_eq!(r.code, 1);
    assert!(
        r.err
            .starts_with("radin-backlog: overlap needs <epic-a> <epic-b>\n"),
        "{}",
        r.err
    );
}

#[test]
fn a_cbm_daemon_failure_is_retried_once_before_it_is_a_gap() {
    let w = W::new();
    w.rust_epics();
    w.healthy_graph("[]");
    // list_projects fails once with a daemon message, then answers from its json.
    stub(
        &w.bin,
        "codebase-memory-mcp",
        "echo \"$*\" >> \"$STUB/calls.log\"\nif [ \"$2\" = list_projects ] && [ ! -f \"$STUB/seen\" ]; then touch \"$STUB/seen\"; echo 'CBM daemon is running' >&2; exit 1; fi\ncat \"$STUB/$2.json\"\n",
    );
    let r = w.overlap(true);
    assert_eq!(r.code, 0, "{}{}", r.out, r.err);
    assert_eq!(w.calls().matches("list_projects").count(), 2);
    assert!(w.telemetry().is_empty());
}

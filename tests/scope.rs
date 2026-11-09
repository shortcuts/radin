#[path = "common/cli.rs"]
mod cli;
mod common;

use cli::git;
use radin::{Ctx, Host, Out};
use std::fs;
use std::path::{Path, PathBuf};

type Cli<'a> = &'a dyn Fn(&Path, &[&str], &str) -> Out;

struct W {
    _t: tempfile::TempDir,
    p: PathBuf,
    path: String,
}

fn commit(p: &Path, msg: &str, date: &str) {
    let o = std::process::Command::new("git")
        .args([
            "-c",
            "user.name=t",
            "-c",
            "user.email=t@t",
            "commit",
            "-q",
            "-m",
            msg,
        ])
        .env("GIT_AUTHOR_DATE", date)
        .env("GIT_COMMITTER_DATE", date)
        .current_dir(p)
        .output()
        .unwrap();
    assert!(o.status.success());
}

fn gh_stub(dir: &Path) {
    fs::create_dir_all(dir).unwrap();
    let f = dir.join("gh");
    fs::write(
        &f,
        "#!/bin/sh\ncase \"$1 $2\" in\n\"pr view\")\n for a; do [ \"$a\" = --json ] && { printf 'abc1234 first\\ndef5678 second\\n'; exit 0; }; done\n [ \"$3\" = 12 ] || exit 1;;\n\"pr diff\") printf '+++ b/a.txt\\n@@ -1 +1,2 @@\\n+x\\n';;\nesac\n",
    )
    .unwrap();
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(&f, fs::Permissions::from_mode(0o755)).unwrap();
}

/// main holds two commits; a.txt has three lines.
fn w() -> W {
    let t = tempfile::tempdir().unwrap();
    let root = t.path().canonicalize().unwrap();
    let p = root.join("proj");
    fs::create_dir(&p).unwrap();
    git(&p, &["init", "-q", "-b", "main"]);
    fs::write(p.join("a.txt"), "1\n2\n3\n").unwrap();
    git(&p, &["add", "a.txt"]);
    commit(&p, "first", "2020-01-01T00:00:00Z");
    fs::write(p.join("b.txt"), "b\n").unwrap();
    git(&p, &["add", "b.txt"]);
    commit(&p, "second", "2020-01-02T00:00:00Z");
    gh_stub(&root.join("bin"));
    let path = format!(
        "{}:{}",
        root.join("bin").display(),
        std::env::var("PATH").unwrap()
    );
    W { _t: t, p, path }
}

impl W {
    fn go(&self, host: Host, args: &[&str], stdin: &str, cli: Cli) -> Out {
        let home = self.p.parent().unwrap().to_path_buf();
        let h = home.to_string_lossy().into_owned();
        let path = self.path.clone();
        let env = move |k: &str| match k {
            "HOME" => Some(h.clone()),
            "PATH" => Some(path.clone()),
            _ => None,
        };
        let c = Ctx {
            cwd: self.p.clone(),
            home,
            host,
            stdin: stdin.to_string(),
            env: &env,
            cli,
        };
        let a: Vec<String> = args.iter().map(|s| s.to_string()).collect();
        radin::scope::run(&c, &a)
    }
    fn s(&self, args: &[&str]) -> Out {
        self.go(Host::Claude, args, "", &no_cli)
    }
    fn head(&self, rev: &str) -> String {
        git(&self.p, &["rev-parse", rev]).trim().to_string()
    }
}

fn no_cli(_: &Path, _: &[&str], _: &str) -> Out {
    (1, String::new(), String::new())
}

fn emit(t: &str, s: &str, c: &str) -> String {
    format!("type\t{t}\nscope\t{s}\ncommand\t{c}\npasses\t\n")
}

#[test]
fn help_prints_the_usage_header() {
    let w = w();
    for a in ["help", "--help", "-h"] {
        let o = w.s(&[a]);
        assert_eq!(o.0, 0);
        assert!(o.1.starts_with("Deterministic review-scope resolution"));
        assert!(o.1.contains("--bucket"));
    }
}

#[test]
fn staged_and_the_last_commit_shapes_resolve() {
    let w = w();
    assert_eq!(
        w.s(&["staged"]),
        (
            0,
            emit("staged", "staged", "git diff --cached"),
            String::new()
        )
    );
    assert_eq!(
        w.s(&["last commit"]).1,
        emit("range", "HEAD~1..HEAD", "git diff HEAD~1..HEAD")
    );
    assert_eq!(
        w.s(&["last 1 commits"]).1,
        emit("range", "HEAD~1..HEAD", "git diff HEAD~1..HEAD")
    );
}

#[test]
fn a_commit_count_must_be_a_number_inside_the_history() {
    let w = w();
    assert_eq!(
        w.s(&["last x commits"]),
        (
            1,
            String::new(),
            "radin-scope: not a commit count: last x commits\n".into()
        )
    );
    assert_eq!(
        w.s(&["last 5 commits"]),
        (
            1,
            String::new(),
            "radin-scope: history is shorter than 5 commits\n".into()
        )
    );
}

#[test]
fn a_range_checks_both_revisions() {
    let w = w();
    assert_eq!(
        w.s(&["HEAD~1..HEAD"]).1,
        emit("range", "HEAD~1..HEAD", "git diff HEAD~1..HEAD")
    );
    assert_eq!(w.s(&["HEAD~1...HEAD"]).0, 0);
    assert_eq!(
        w.s(&["nope..HEAD"]),
        (
            1,
            String::new(),
            "radin-scope: not a revision: nope\n".into()
        )
    );
}

#[test]
fn no_argument_diffs_the_branch_against_its_merge_base_with_main() {
    let w = w();
    let base = w.head("HEAD");
    git(&w.p, &["checkout", "-q", "-b", "feature"]);
    fs::write(w.p.join("c.txt"), "c\n").unwrap();
    git(&w.p, &["add", "c.txt"]);
    commit(&w.p, "third", "2020-01-03T00:00:00Z");
    assert_eq!(
        w.s(&[]).1,
        emit(
            "branch-diff",
            &format!("{base}..HEAD"),
            &format!("git diff {base}..HEAD")
        )
    );
    git(&w.p, &["branch", "-q", "-m", "main", "trunk"]);
    assert_eq!(
        w.s(&[]),
        (
            1,
            String::new(),
            "radin-scope: no main or master branch to diff against\n".into()
        )
    );
}

#[test]
fn a_since_window_starts_before_its_oldest_commit_or_at_the_empty_tree() {
    let w = w();
    let left = format!("{}~1", w.head("HEAD"));
    let o = w.s(&["since 2020-01-01T12:00:00Z"]);
    assert_eq!(
        o.1,
        emit(
            "range",
            &format!("{left}..HEAD"),
            &format!("git diff {left}..HEAD")
        )
    );
    let empty = "4b825dc642cb6eb9a060e54bf8d69288fbee4904";
    assert_eq!(
        w.s(&["since 2000-01-01"]).1,
        emit(
            "range",
            &format!("{empty}..HEAD"),
            &format!("git diff {empty}..HEAD")
        )
    );
}

#[test]
fn a_bare_commit_resolves_to_its_own_diff() {
    let w = w();
    let h = w.head("HEAD");
    assert_eq!(
        w.s(&[&h]).1,
        emit("commit", &h, &format!("git diff {h}^..{h}"))
    );
}

#[test]
fn a_directory_resolves_and_the_host_adds_its_ponytail_passes() {
    let w = w();
    fs::create_dir(w.p.join("d")).unwrap();
    let claude = w.s(&["d"]);
    assert_eq!(claude.0, 0);
    assert!(claude
        .1
        .contains("passes\t/ponytail:ponytail-audit /ponytail:ponytail-debt\n"));
    assert!(claude
        .1
        .starts_with("type\tdir\nscope\td\ncommand\tread the files under d as they stand\n"));
    let agents = w.go(Host::Agents, &["d"], "", &no_cli);
    assert!(agents.1.contains("passes\tponytail-audit ponytail-debt\n"));
}

#[test]
fn a_name_that_is_a_directory_and_a_commit_is_ambiguous() {
    let w = w();
    git(&w.p, &["branch", "dup"]);
    fs::create_dir(w.p.join("dup")).unwrap();
    let o = w.s(&["dup"]);
    assert_eq!(o.0, 2);
    assert_eq!(o.1, "");
    assert!(o
        .2
        .starts_with("radin-scope: \"dup\" is ambiguous, 2 candidate readings:\n"));
    assert!(o.2.contains("type\tcommit\n"));
    assert!(o.2.contains("type\tdir\nscope\tdup\n"));
    assert!(o.2.ends_with("---\n"));
}

#[test]
fn an_unrecognized_argument_exits_1() {
    let w = w();
    assert_eq!(
        w.s(&["nonsense"]),
        (
            1,
            String::new(),
            "radin-scope: \"nonsense\" is not a commit, PR, directory, range, or since-date here\n"
                .into()
        )
    );
}

#[test]
fn a_pr_resolves_through_gh_and_a_missing_pr_exits_1() {
    let w = w();
    assert_eq!(w.s(&["#12"]).1, emit("pr", "#12", "gh pr diff 12"));
    assert_eq!(w.s(&["12"]).1, emit("pr", "#12", "gh pr diff 12"));
    assert_eq!(
        w.s(&["https://github.com/o/r/pull/12/files"]).1,
        emit("pr", "#12 (o/r)", "gh pr diff 12 --repo o/r")
    );
    assert_eq!(
        w.s(&["#99"]),
        (
            1,
            String::new(),
            "radin-scope: PR #99 does not resolve via gh\n".into()
        )
    );
    assert_eq!(w.s(&["#x"]).2, "radin-scope: not a PR number: #x\n");
}

#[test]
fn commits_lists_the_scopes_commits_per_scope_type() {
    let w = w();
    let (h1, h0) = (w.head("HEAD"), w.head("HEAD~1"));
    assert_eq!(
        w.s(&["--commits", "last commit"]).1,
        format!("{h1} second\n")
    );
    assert_eq!(
        w.s(&["--commits", "HEAD~1..HEAD"]).1,
        format!("{h1} second\n")
    );
    assert_eq!(w.s(&["--commits", &h0]).1, format!("{h0} first\n"));
    assert_eq!(
        w.s(&["--commits", "staged"]),
        (0, String::new(), String::new())
    );
    fs::create_dir(w.p.join("d")).unwrap();
    assert_eq!(w.s(&["--commits", "d"]), (0, String::new(), String::new()));
    assert_eq!(
        w.s(&["--commits", "#12"]).1,
        "abc1234 first\ndef5678 second\n"
    );
    assert_eq!(w.s(&["--commits", "nonsense"]).0, 1);
}

#[test]
fn in_scope_keeps_citations_inside_a_diff_hunk() {
    let w = w();
    fs::write(w.p.join("a.txt"), "1\nX\n3\n").unwrap();
    git(&w.p, &["add", "a.txt"]);
    let o = w.go(
        Host::Claude,
        &["--in-scope", "staged"],
        "a.txt:2\na.txt:1\n./a.txt:2-3\nb.txt:1\n\nplain\n",
        &no_cli,
    );
    assert_eq!(
        o,
        (
            0,
            "in\ta.txt:2\nout\ta.txt:1\nin\t./a.txt:2-3\nout\tb.txt:1\nout\tplain\ndropped\t3\n"
                .into(),
            String::new()
        )
    );
}

#[test]
fn in_scope_reads_a_pr_diff_through_gh() {
    let w = w();
    let o = w.go(
        Host::Claude,
        &["--in-scope", "#12"],
        "a.txt:2\na.txt:9\n",
        &no_cli,
    );
    assert_eq!(o.1, "in\ta.txt:2\nout\ta.txt:9\ndropped\t1\n");
}

#[test]
fn in_scope_for_a_dir_checks_the_path_prefix() {
    let w = w();
    fs::create_dir(w.p.join("d")).unwrap();
    let o = w.go(
        Host::Claude,
        &["--in-scope", "d/"],
        "d/x.rs:1\n./d/y.rs:2\ndd/z.rs:3\n",
        &no_cli,
    );
    assert_eq!(
        o.1,
        "in\td/x.rs:1\nin\t./d/y.rs:2\nout\tdd/z.rs:3\ndropped\t1\n"
    );
}

#[test]
fn in_scope_passes_a_resolution_failure_through() {
    let w = w();
    let o = w.go(Host::Claude, &["--in-scope", "nonsense"], "a:1\n", &no_cli);
    assert_eq!(o.0, 1);
    assert_eq!(o.1, "");
}

#[test]
fn bucket_sorts_every_finding_shape() {
    let w = w();
    let input = [
        "nit a.rs:1 — x [cited: y]",
        "critical a.rs:1 — x [ran: y]",
        "warning a.rs:1 — x [traced: y]",
        "warning a.rs:1 — x [cited: AGENTS.md rule]",
        "warning a.rs:1 — x [cited: quotes \"spec line\"]",
        "warning a.rs:1 — x [cited: y]",
        "warning a.rs:1 — x",
        "bogus a.rs:1 — x [ran: y]",
        "",
        "critical a.rs:1 — x [ran: ]",
    ]
    .join("\n");
    let o = w.go(Host::Claude, &["--bucket"], &input, &no_cli);
    let got: Vec<&str> = o.1.lines().map(|l| l.split('\t').next().unwrap()).collect();
    assert_eq!(
        got,
        [
            "noted", "act-on", "act-on", "act-on", "act-on", "consider", "unparsed", "unparsed",
            "act-on"
        ]
    );
    assert!(o.1.starts_with("noted\tnit a.rs:1 — x [cited: y]\n"));
}

fn state_cli(rows: &'static str, shown: &'static str) -> impl Fn(&Path, &[&str], &str) -> Out {
    move |_, a, _| match (a[2], a[3]) {
        ("state", "completed-list") => (0, rows.to_string(), String::new()),
        ("state", "completed-show") => (0, shown.to_string(), String::new()),
        ("backlog", "stamps") => (
            0,
            "p-1\t2020-01-05T00:00:00Z\tmain\nt-done\t2020-01-01T00:00:00Z\tmain\n".into(),
            String::new(),
        ),
        ("backlog", "meta") => (0, "plan\tplans/p-1.md\n".into(), String::new()),
        ("backlog", "field") => (0, String::new(), String::new()),
        _ => (1, String::new(), String::new()),
    }
}

#[test]
fn specs_join_a_completed_task_by_commit_and_a_pending_one_by_branch() {
    let w = w();
    let h1 = w.head("HEAD");
    let rows: &'static str = Box::leak(format!("t-done\t{h1}\n").into_boxed_str());
    let shown: &'static str =
        "created\t2020-01-02T00:00:00Z\nbranch\tradin/t-done\nplan\tplans/a.md, plans/b.md\n";
    fs::create_dir(w.p.join("plans")).unwrap();
    fs::write(w.p.join("plans/a.md"), "**Finding:** x\n").unwrap();
    let cli = state_cli(rows, shown);
    let o = w.go(Host::Claude, &["--specs", "last commit"], "", &cli);
    assert_eq!(o.0, 0, "{}", o.2);
    assert_eq!(
        o.1,
        format!(
            "t-done\t2020-01-02T00:00:00Z\tradin/t-done\t{h1}\tcommit\tfollow-up\tplans/a.md,plans/b.md\tnone\np-1\t2020-01-05T00:00:00Z\tmain\t\tpending\tfeature\tplans/p-1.md\tnone\n"
        )
    );
}

#[test]
fn specs_fall_back_to_the_reflog() {
    let w = w();
    let old = w.head("HEAD");
    git(
        &w.p,
        &[
            "commit",
            "-q",
            "--amend",
            "-m",
            "second",
            "--date",
            "2020-01-02T00:00:00Z",
            "--reset-author",
        ],
    );
    let rows: &'static str = Box::leak(format!("t-old\t{old}\n").into_boxed_str());
    let cli = state_cli(rows, "created\t2020-01-02T00:00:00Z\nbranch\tb\n");
    let o = w.go(Host::Claude, &["--specs", "last commit"], "", &cli);
    assert!(
        o.1.contains(&format!(
            "t-old\t2020-01-02T00:00:00Z\tb\t{old}\treflog\tfeature\tnone\tnone\n"
        )),
        "{}",
        o.1
    );
}

#[test]
fn specs_join_a_cherry_picked_task_by_patch_identity() {
    let w = w();
    let h1 = w.head("HEAD");
    git(&w.p, &["checkout", "-q", "-b", "side", "HEAD~1"]);
    fs::write(w.p.join("b.txt"), "b\n").unwrap();
    git(&w.p, &["add", "b.txt"]);
    let o = std::process::Command::new("git")
        .args([
            "-c",
            "user.name=t",
            "-c",
            "user.email=t@t",
            "commit",
            "-q",
            "-m",
            "second",
        ])
        .env("GIT_AUTHOR_DATE", "2020-01-02T00:00:00Z")
        .env("GIT_COMMITTER_DATE", "2020-02-02T00:00:00Z")
        .current_dir(&w.p)
        .output()
        .unwrap();
    assert!(o.status.success());
    let pick = w.head("HEAD");
    assert_ne!(pick, h1);
    git(&w.p, &["checkout", "-q", "main"]);
    let rows: &'static str = Box::leak(format!("t-pick\t{pick}\n").into_boxed_str());
    let cli = state_cli(
        rows,
        "created\t2020-01-02T00:00:00Z\nbranch\tradin/t-pick\n",
    );
    let o = w.go(Host::Claude, &["--specs", "last commit"], "", &cli);
    assert!(
        o.1.contains(&format!(
            "t-pick\t2020-01-02T00:00:00Z\tradin/t-pick\t{pick}\tpatch\tfeature\tnone\tnone\n"
        )),
        "{}",
        o.1
    );
}

#[test]
fn specs_exit_4_when_a_recorded_commit_is_gone_and_head_has_no_branch() {
    let w = w();
    git(&w.p, &["checkout", "-q", "--detach"]);
    let gone = "0123456789abcdef0123456789abcdef01234567";
    let rows: &'static str = Box::leak(format!("t-gone\t{gone}\n").into_boxed_str());
    let cli = state_cli(rows, "");
    let o = w.go(Host::Claude, &["--specs", "last commit"], "", &cli);
    assert_eq!(
        o,
        (
            4,
            String::new(),
            format!("radin-scope: commit {gone} of task t-gone no longer exists and HEAD has no branch to search the reflog of\n")
        )
    );
}

#[test]
fn attribute_maps_a_blamed_line_to_its_task_and_plan() {
    let w = w();
    let h1 = w.head("HEAD");
    let cli = move |_: &Path, a: &[&str], _: &str| -> Out {
        match (a[2], a[3]) {
            ("state", "trace") if a[4] == h1 => (
                0,
                "task\tt-one\nplan\tplans/t-one.md\n".into(),
                String::new(),
            ),
            ("state", "plan-covers") => (0, "in\n".into(), String::new()),
            _ => (1, String::new(), String::new()),
        }
    };
    let o = w.go(
        Host::Claude,
        &["--attribute", "last commit"],
        "b.txt:1\na.txt:2\n\nzzz\nb.txt:x",
        &cli,
    );
    assert_eq!(
        o,
        (
            0,
            "b.txt:1\tt-one\tplans/t-one.md\tin\na.txt:2\tnone\tnone\tnone\nzzz\tnone\tnone\tnone\nb.txt:x\tnone\tnone\tnone\n".into(),
            String::new()
        )
    );
}

mod specs;

use crate::paths::git;
use crate::{Ctx, Out};
use specs::{attribute, bucket, specs};
use std::collections::HashSet;
use std::io::Write;
use std::process::{Command, Stdio};

const HELP: &str = include_str!("help.txt");

struct Resolved {
    kind: &'static str,
    scope: String,
    command: String,
}

type R<T> = Result<T, Out>;

fn die(m: &str) -> Out {
    (1, String::new(), format!("radin-scope: {m}\n"))
}

pub(super) fn ok(s: String) -> Out {
    (0, s, String::new())
}

pub(super) fn exec(
    c: &Ctx,
    prog: &str,
    args: &[&str],
    stdin: Option<&str>,
) -> Option<(i32, String, String)> {
    let mut cmd = Command::new(prog);
    cmd.args(args)
        .current_dir(&c.cwd)
        .stdin(if stdin.is_some() {
            Stdio::piped()
        } else {
            Stdio::null()
        })
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    if let Some(p) = (c.env)("PATH") {
        cmd.env("PATH", p);
    }
    let mut child = cmd.spawn().ok()?;
    if let (Some(text), Some(mut s)) = (stdin, child.stdin.take()) {
        let _ = s.write_all(text.as_bytes());
    }
    let o = child.wait_with_output().ok()?;
    Some((
        o.status.code().unwrap_or(1),
        String::from_utf8_lossy(&o.stdout).into_owned(),
        String::from_utf8_lossy(&o.stderr).into_owned(),
    ))
}

fn gh_ok(c: &Ctx, args: &[&str]) -> bool {
    exec(c, "gh", args, None).is_some_and(|o| o.0 == 0)
}

fn in_git(c: &Ctx) -> bool {
    git(&c.cwd, &["rev-parse", "--git-dir"]).is_some()
}

fn verify(c: &Ctx, rev: &str) -> bool {
    git(&c.cwd, &["rev-parse", "--verify", "-q", rev]).is_some()
}

fn emit(c: &Ctx, kind: &str, scope: &str, command: &str) -> String {
    let passes = match kind {
        "dir" => ["ponytail-audit", "ponytail-debt"]
            .map(|n| c.host.skill_name(n).unwrap_or_default())
            .join(" "),
        _ => String::new(),
    };
    format!("type\t{kind}\nscope\t{scope}\ncommand\t{command}\npasses\t{passes}\n")
}

fn parse_resolved(text: &str) -> Resolved {
    let field = |k: &str| {
        text.lines()
            .find_map(|l| l.strip_prefix(&format!("{k}\t")))
            .unwrap_or("")
            .to_string()
    };
    let kind = match field("type").as_str() {
        "commit" => "commit",
        "pr" => "pr",
        "dir" => "dir",
        "branch-diff" => "branch-diff",
        "range" => "range",
        _ => "staged",
    };
    Resolved {
        kind,
        scope: field("scope"),
        command: field("command"),
    }
}

pub(super) fn digits(s: &str) -> bool {
    !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit())
}

fn resolve(c: &Ctx, arg: &str) -> R<String> {
    let e = |k: &str, s: &str, cmd: &str| Ok(emit(c, k, s, cmd));
    if arg.is_empty() {
        if !in_git(c) {
            return Err(die("not in a git repo and no scope argument given"));
        }
        let base_branch = ["main", "master"]
            .into_iter()
            .find(|b| verify(c, b))
            .ok_or_else(|| die("no main or master branch to diff against"))?;
        let base = git(&c.cwd, &["merge-base", base_branch, "HEAD"]).unwrap_or_default();
        let base = base.trim_end();
        return e(
            "branch-diff",
            &format!("{base}..HEAD"),
            &format!("git diff {base}..HEAD"),
        );
    }
    if let Some(num) = arg.strip_prefix('#') {
        if !digits(num) {
            return Err(die(&format!("not a PR number: {arg}")));
        }
        if !gh_ok(c, &["pr", "view", num]) {
            return Err(die(&format!("PR #{num} does not resolve via gh")));
        }
        return e("pr", &format!("#{num}"), &format!("gh pr diff {num}"));
    }
    if let Some((repo, tail)) = arg
        .strip_prefix("https://github.com/")
        .and_then(|r| r.split_once("/pull/"))
    {
        let num: String = tail
            .rsplit("/pull/")
            .next()
            .unwrap_or(tail)
            .chars()
            .take_while(char::is_ascii_digit)
            .collect();
        if num.is_empty() {
            return Err(die(&format!("no PR number in URL: {arg}")));
        }
        if !gh_ok(c, &["pr", "view", &num, "--repo", repo]) {
            return Err(die(&format!("{arg} does not resolve via gh")));
        }
        return e(
            "pr",
            &format!("#{num} ({repo})"),
            &format!("gh pr diff {num} --repo {repo}"),
        );
    }
    let need_git = || {
        if in_git(c) {
            Ok(())
        } else {
            Err(die(&format!("not in a git repo: {arg}")))
        }
    };
    if arg == "staged" {
        need_git()?;
        return e("staged", "staged", "git diff --cached");
    }
    if arg == "last commit" {
        need_git()?;
        return e("range", "HEAD~1..HEAD", "git diff HEAD~1..HEAD");
    }
    if let Some(n) = arg
        .strip_prefix("last ")
        .and_then(|r| r.strip_suffix(" commits"))
    {
        if !digits(n) {
            return Err(die(&format!("not a commit count: {arg}")));
        }
        need_git()?;
        if !verify(c, &format!("HEAD~{n}")) {
            return Err(die(&format!("history is shorter than {n} commits")));
        }
        return e(
            "range",
            &format!("HEAD~{n}..HEAD"),
            &format!("git diff HEAD~{n}..HEAD"),
        );
    }
    if let Some((left, _)) = arg.split_once("..") {
        need_git()?;
        let right = arg.rsplit("..").next().unwrap_or("");
        let right = right.strip_prefix('.').unwrap_or(right);
        for rev in [left, right] {
            if !rev.is_empty() && !verify(c, rev) {
                return Err(die(&format!("not a revision: {rev}")));
            }
        }
        return e("range", arg, &format!("git diff {arg}"));
    }

    let mut found: Vec<String> = Vec::new();
    if arg.bytes().all(|b| b.is_ascii_digit()) && gh_ok(c, &["pr", "view", arg]) {
        found.push(emit(
            c,
            "pr",
            &format!("#{arg}"),
            &format!("gh pr diff {arg}"),
        ));
    }
    if in_git(c)
        && git(&c.cwd, &["cat-file", "-t", arg])
            .is_some_and(|t| matches!(t.trim_end(), "commit" | "tag"))
    {
        found.push(emit(c, "commit", arg, &format!("git diff {arg}^..{arg}")));
    }
    if c.cwd.join(arg).is_dir() {
        found.push(emit(
            c,
            "dir",
            arg,
            &format!("read the files under {arg} as they stand"),
        ));
    }
    match found.len() {
        1 => return Ok(found.remove(0)),
        0 => {}
        n => {
            let body: String = found.iter().map(|f| format!("{f}---\n")).collect();
            return Err((
                2,
                String::new(),
                format!("radin-scope: \"{arg}\" is ambiguous, {n} candidate readings:\n{body}"),
            ));
        }
    }
    if let (Some(since), true) = (arg.strip_prefix("since "), in_git(c)) {
        let log = git(&c.cwd, &["log", &format!("--since={since}"), "--format=%H"]);
        if let Some(oldest) = log.as_deref().and_then(|l| l.lines().last()) {
            let left = if verify(c, &format!("{oldest}~1")) {
                format!("{oldest}~1")
            } else {
                exec(c, "git", &["hash-object", "-t", "tree", "/dev/null"], None)
                    .map(|o| o.1.trim_end().to_string())
                    .unwrap_or_default()
            };
            return e(
                "range",
                &format!("{left}..HEAD"),
                &format!("git diff {left}..HEAD"),
            );
        }
    }
    Err(die(&format!(
        "\"{arg}\" is not a commit, PR, directory, range, or since-date here"
    )))
}

fn awk_num(s: &str) -> i64 {
    let t: String = s.chars().take_while(char::is_ascii_digit).collect();
    t.parse().unwrap_or(0)
}

fn in_scope(c: &Ctx, arg: &str) -> Out {
    let r = match resolve(c, arg) {
        Ok(t) => parse_resolved(&t),
        Err(o) => return o,
    };
    let cites = c.stdin.lines().filter(|l| !l.is_empty());
    let mut dropped = 0;
    let mut out = String::new();
    if r.kind == "dir" {
        let dir = format!("{}/", r.scope.trim_end_matches('/'));
        for l in cites {
            if l.strip_prefix("./").unwrap_or(l).starts_with(&dir) {
                out += &format!("in\t{l}\n");
            } else {
                out += &format!("out\t{l}\n");
                dropped += 1;
            }
        }
        return ok(out + &format!("dropped\t{dropped}\n"));
    }
    let mut words: Vec<&str> = r.command.split_whitespace().collect();
    if r.command.starts_with("git diff") {
        words.push("--unified=0");
    }
    let Some(diff) = exec(c, words[0], &words[1..], None) else {
        return die(&format!("cannot run {}", words[0]));
    };
    if diff.0 != 0 {
        return (diff.0, String::new(), diff.2);
    }
    let mut seen: HashSet<(String, i64)> = HashSet::new();
    let mut file = String::new();
    for l in diff.1.lines() {
        if l.starts_with("+++ ") {
            let f = l.split_whitespace().nth(1).unwrap_or("");
            file = f.strip_prefix("b/").unwrap_or(f).to_string();
        } else if l.starts_with("@@ ") {
            let r = l.split_whitespace().nth(2).unwrap_or("");
            let r = r.strip_prefix('+').unwrap_or(r);
            let (s, n) = match r.split_once(',') {
                Some((s, n)) => (awk_num(s), awk_num(n)),
                None => (awk_num(r), 1),
            };
            for i in 0..n {
                seen.insert((file.clone(), s + i));
            }
        }
    }
    for l in cites {
        let (p, n) = l.rsplit_once(':').unwrap_or((l, l));
        let p = p.strip_prefix("./").unwrap_or(p);
        let n = n.split('-').next().unwrap_or("");
        if seen.contains(&(p.to_string(), awk_num(n))) {
            out += &format!("in\t{l}\n");
        } else {
            out += &format!("out\t{l}\n");
            dropped += 1;
        }
    }
    ok(out + &format!("dropped\t{dropped}\n"))
}

pub(super) fn commits(c: &Ctx, arg: &str) -> Out {
    let r = match resolve(c, arg) {
        Ok(t) => parse_resolved(&t),
        Err(o) => return o,
    };
    let run = |args: &[&str]| match exec(c, args[0], &args[1..], None) {
        Some(o) => (o.0, o.1, o.2),
        None => die(&format!("cannot run {}", args[0])),
    };
    match r.kind {
        "commit" => run(&["git", "log", "-1", "--format=%H %s", &r.scope]),
        "range" | "branch-diff" => run(&["git", "log", "--format=%H %s", &r.scope]),
        "pr" => {
            let num = r.scope.trim_start_matches('#');
            let num = num.split(' ').next().unwrap_or(num);
            let repo = r
                .scope
                .split_once('(')
                .map(|(_, t)| t.trim_end_matches(')').to_string());
            let mut a = vec!["gh", "pr", "view", num];
            if let Some(repo) = &repo {
                a.extend(["--repo", repo]);
            }
            a.extend([
                "--json",
                "commits",
                "--jq",
                ".commits[] | .oid + \" \" + .messageHeadline",
            ]);
            run(&a)
        }
        _ => ok(String::new()),
    }
}

pub fn run(c: &Ctx, args: &[String]) -> Out {
    let a = |i: usize| args.get(i).map_or("", String::as_str);
    match a(0) {
        "help" | "--help" | "-h" => ok(HELP.to_string()),
        "--in-scope" => in_scope(c, a(1)),
        "--commits" => commits(c, a(1)),
        "--specs" => specs(c, a(1)),
        "--bucket" => ok(bucket(&c.stdin)),
        "--attribute" => attribute(c, a(1)),
        arg => match resolve(c, arg) {
            Ok(t) => ok(t),
            Err(o) => o,
        },
    }
}

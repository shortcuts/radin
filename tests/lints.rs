use radin::render::{hits, Rules};
use regex::Regex;
use std::collections::{BTreeSet, HashMap, HashSet};
use std::fs;
use std::path::Path;

const PLUGINS: [&str; 3] = ["caveman", "ponytail", "mattpocock-skills"];
const COMPANIONS: [&str; 1] = ["thermo-nuclear"];
const EXAMPLES: [&str; 3] = ["deep-research", "frontend-design", "other-skill"];
const NOT_SKILLS: [&str; 3] = ["bin", "dev", "host"];
const ALLOWED: [&str; 2] = [
    "you are a leaf no user no askuserquestion no workflow no sub agent of your own",
    "read radin lib radin run md in full now and follow it as this skill s body",
];

fn repo() -> &'static Path {
    Path::new(env!("CARGO_MANIFEST_DIR"))
}

fn re(p: &str) -> Regex {
    Regex::new(p).unwrap()
}

fn read(root: &Path, rel: &str) -> Option<String> {
    fs::read_to_string(root.join(rel)).ok()
}

fn lib_files(root: &Path, keep: impl Fn(&str) -> bool) -> Vec<String> {
    let mut names: Vec<String> = fs::read_dir(root.join("lib"))
        .into_iter()
        .flatten()
        .filter_map(|e| e.ok()?.file_name().into_string().ok())
        .filter(|n| keep(n))
        .collect();
    names.sort();
    names.into_iter().map(|n| format!("lib/{n}")).collect()
}

fn skill_files(root: &Path) -> Vec<String> {
    let mut dirs: Vec<String> = fs::read_dir(root.join("skills"))
        .into_iter()
        .flatten()
        .filter_map(|e| e.ok()?.file_name().into_string().ok())
        .filter(|d| root.join("skills").join(d).join("SKILL.md").is_file())
        .collect();
    dirs.sort();
    dirs.into_iter()
        .map(|d| format!("skills/{d}/SKILL.md"))
        .collect()
}

fn prose_files(root: &Path) -> Vec<String> {
    let mut f = skill_files(root);
    f.extend(lib_files(root, |n| n.ends_with(".md")));
    f
}

fn lint_guard(root: &Path) -> Vec<String> {
    let comp = "caveman|ponytail|rtk|thermo|mattpocock|codebase-memory|graph tool";
    let guard = re(&format!(
        "(?i)command -v|if (it|the|that|a)[^.]{{0,40}}(is|are) (installed|wired|available|present)|(unavailable|not installed|absent|missing|without)[^.]{{0,50}}({comp})|({comp}|graph)[^.]{{0,50}}(unavailable|not installed|absent|is missing|when absent)"
    ));
    let mut out = Vec::new();
    for f in prose_files(root) {
        for (i, l) in read(root, &f).unwrap_or_default().lines().enumerate() {
            if guard.is_match(l) {
                out.push(format!("{f}:{}: companion guard; name the tool directly, a missing tool fails loudly and counts as a skip", i + 1));
            }
        }
    }
    out
}

fn lint_git(root: &Path) -> Vec<String> {
    let git = re(r"(?i)(`|^[ \t]*)git [a-z]");
    let mut files = vec!["lib/radin-run.md".to_string()];
    files.extend(lib_files(root, |n| {
        n.starts_with("radin-batch-") && n.ends_with(".md")
    }));
    let mut out = Vec::new();
    for f in files {
        for (i, l) in read(root, &f).unwrap_or_default().lines().enumerate() {
            if git.is_match(l) && !l.to_ascii_lowercase().contains("never") {
                out.push(format!("{f}:{}: raw git command in router prose; add a radin subcommand, or state the prohibition with \"never\"", i + 1));
            }
        }
    }
    out
}

fn normalise(s: &str) -> String {
    let mut out = String::new();
    for c in s.chars().map(|c| c.to_ascii_lowercase()) {
        if c.is_ascii_lowercase() || c.is_ascii_digit() {
            out.push(c);
        } else if !out.is_empty() && !out.ends_with(' ') {
            out.push(' ');
        }
    }
    out.trim_end().to_string()
}

#[derive(Default)]
struct Dup {
    buf: String,
    start: usize,
    block: usize,
    seen: HashMap<String, (String, usize)>,
    out: Vec<String>,
}

impl Dup {
    fn emit(&mut self, file: &str) {
        let s = normalise(&self.buf);
        self.buf.clear();
        if s.split(' ').count() < 8 || ALLOWED.contains(&s.as_str()) {
            return;
        }
        match self.seen.get(&s) {
            Some((first, b)) => {
                if self.block != 0 && *b != 0 && self.block != *b {
                    return;
                }
                self.out.push(format!(
                    "{file}:{}: repeats {first}; state it once there and point to it",
                    self.start
                ));
            }
            None => {
                let at = format!("{file}:{}", self.start);
                self.seen.insert(s, (at, self.block));
            }
        }
    }
}

fn lint_dup(root: &Path) -> Vec<String> {
    let marker = re(r"^[ \t]*<!-- (host:|/host)");
    let flush = re(r"^[ \t]*($|```|#|[-*] |[0-9]+[a-z]?\. |<!--)");
    let end = re(r"[.!?]([ \t]|$)");
    let mut files = vec!["lib/radin-leaf-contract.md".to_string()];
    files.extend(
        prose_files(root)
            .into_iter()
            .filter(|f| f.starts_with("lib/")),
    );
    files.extend(skill_files(root));
    let mut done = HashSet::new();
    let mut d = Dup::default();
    for f in files {
        let Some(text) = read(root, &f) else { continue };
        if !done.insert(f.clone()) {
            continue;
        }
        d.buf.clear();
        let (mut blk, mut nb) = (0, 0);
        for (i, l) in text.lines().enumerate() {
            let n = i + 1;
            if marker.is_match(l) {
                d.emit(&f);
                blk = if l.contains("host:") {
                    nb += 1;
                    nb
                } else {
                    0
                };
                continue;
            }
            if flush.is_match(l) {
                d.emit(&f);
            }
            if d.buf.is_empty() {
                d.start = n;
                d.block = blk;
            }
            let mut rest = l;
            while let Some(m) = end.find(rest) {
                d.buf.push(' ');
                d.buf.push_str(&rest[..m.start() + 1]);
                d.emit(&f);
                rest = &rest[m.end()..];
                d.start = n;
                d.block = blk;
            }
            if rest.contains(|c| c != ' ' && c != '\t') {
                d.buf.push(' ');
                d.buf.push_str(rest);
            }
        }
    }
    d.out
}

fn lint_forbid(root: &Path) -> Vec<String> {
    let rules = Rules::from_dir(&repo().join("lib"), "agents").unwrap();
    let mut out = Vec::new();
    let mut found = BTreeSet::new();
    for f in prose_files(root) {
        let src = read(root, &f).unwrap_or_default();
        match hits(&src, &f, &rules) {
            Ok(v) => found.extend(v.into_iter().map(|s| format!("{f}\t{s}"))),
            Err(e) => out.push(e),
        }
    }
    let base: BTreeSet<String> = read(root, "hosts/forbid-baseline.txt")
        .unwrap_or_default()
        .lines()
        .filter(|l| !l.is_empty())
        .map(String::from)
        .collect();
    for p in found.difference(&base) {
        let (f, s) = p.split_once('\t').unwrap();
        out.push(format!("{f}: forbidden string \"{s}\" outside a host block; wrap it in <!-- host:claude --> or use the name map"));
    }
    for p in base.difference(&found) {
        let (f, s) = p.split_once('\t').unwrap_or((p, ""));
        out.push(format!(
            "hosts/forbid-baseline.txt: {f} no longer holds \"{s}\"; delete the line"
        ));
    }
    out
}

fn token_sites(root: &Path) -> Vec<(String, usize, String)> {
    let tok = re(r"@@skill:([a-z0-9-]+)@@");
    let mut files = prose_files(root);
    files.extend(lib_files(root, |n| n.ends_with(".sh")));
    let mut out = Vec::new();
    for f in files {
        for (i, l) in read(root, &f).unwrap_or_default().lines().enumerate() {
            for c in tok.captures_iter(l) {
                out.push((f.clone(), i + 1, c[1].to_string()));
            }
        }
    }
    out
}

fn table_rows(root: &Path, rel: &str) -> Vec<Vec<String>> {
    read(root, rel)
        .unwrap_or_default()
        .lines()
        .filter(|l| !l.is_empty() && !l.starts_with('#'))
        .map(|l| l.split_whitespace().map(String::from).collect())
        .collect()
}

fn lint_names(root: &Path) -> Vec<String> {
    let lit = re(r"/(mattpocock-skills|ponytail|caveman):|/thermo-nuclear");
    let mut out = Vec::new();
    for f in lib_files(root, |n| n.ends_with(".sh")) {
        for (i, l) in read(root, &f).unwrap_or_default().lines().enumerate() {
            if lit.is_match(l) {
                out.push(format!(
                    "{f}:{}: skill name outside the table; use radin_skill NAME",
                    i + 1
                ));
            }
        }
    }
    let sites = token_sites(root);
    for tbl in lib_files(root, |n| {
        n.starts_with("skill-names-") && n.ends_with(".txt")
    }) {
        let keys: HashSet<String> = table_rows(root, &tbl)
            .into_iter()
            .filter_map(|r| r.into_iter().next())
            .collect();
        for (f, n, k) in &sites {
            if !keys.contains(k) {
                out.push(format!("{f}:{n}: skill {k} is not in {tbl}"));
            }
        }
    }
    out
}

fn lint_all(root: &Path) -> Vec<String> {
    let mut out = lint_guard(root);
    out.extend(lint_git(root));
    out.extend(lint_dup(root));
    out.extend(lint_forbid(root));
    out.extend(lint_names(root));
    out
}

fn fixture() -> tempfile::TempDir {
    let t = tempfile::tempdir().unwrap();
    for d in ["hosts", "skills/x", "lib", "tests"] {
        fs::create_dir_all(t.path().join(d)).unwrap();
    }
    for f in ["lib/radin-run.md", "lib/radin-leaf-contract.md"] {
        put(t.path(), f, "");
    }
    t
}

fn put(root: &Path, rel: &str, text: &str) {
    fs::write(root.join(rel), text).unwrap();
}

const SENTENCE: &str = "Read the shared plan file before you start the task.";

#[test]
fn repo_passes_every_lint() {
    assert_eq!(lint_all(repo()), Vec::<String>::new());
}

#[test]
fn guard_phrase_fails() {
    let t = fixture();
    put(
        t.path(),
        "skills/x/SKILL.md",
        "Run ponytail only if the tool is installed.\n",
    );
    assert_eq!(
        lint_all(t.path()),
        vec!["skills/x/SKILL.md:1: companion guard; name the tool directly, a missing tool fails loudly and counts as a skip"]
    );
}

#[test]
fn raw_git_fails_unless_the_line_says_never() {
    let t = fixture();
    put(t.path(), "skills/x/SKILL.md", "clean\n");
    put(
        t.path(),
        "lib/radin-run.md",
        "Run `git status` first.\nNever run `git push`.\n",
    );
    assert_eq!(
        lint_all(t.path()),
        vec!["lib/radin-run.md:1: raw git command in router prose; add a radin subcommand, or state the prohibition with \"never\""]
    );
}

#[test]
fn forbid_lint_fails_on_new_string_passes_once_baselined_fails_on_stale_pair() {
    let t = fixture();
    put(t.path(), "skills/x/SKILL.md", "use SendMessage\n");
    assert_eq!(
        lint_all(t.path()),
        vec!["skills/x/SKILL.md: forbidden string \"SendMessage\" outside a host block; wrap it in <!-- host:claude --> or use the name map"]
    );
    put(
        t.path(),
        "hosts/forbid-baseline.txt",
        "skills/x/SKILL.md\tSendMessage\n",
    );
    assert_eq!(lint_all(t.path()), Vec::<String>::new());
    put(t.path(), "skills/x/SKILL.md", "clean\n");
    assert_eq!(
        lint_all(t.path()),
        vec!["hosts/forbid-baseline.txt: skills/x/SKILL.md no longer holds \"SendMessage\"; delete the line"]
    );
}

#[test]
fn malformed_host_marker_fails() {
    let t = fixture();
    put(t.path(), "skills/x/SKILL.md", "clean\n");
    put(
        t.path(),
        "lib/radin-batch-gate.md",
        "<!-- host:claude -->\nbody\n",
    );
    assert_eq!(
        lint_all(t.path()),
        vec!["lib/radin-batch-gate.md:1: host block never closed"]
    );
}

#[test]
fn sentence_shared_by_the_claude_and_agents_twins_passes() {
    let t = fixture();
    put(t.path(), "skills/x/SKILL.md", "clean\n");
    let twin = format!(
        "<!-- host:claude -->\n{SENTENCE}\n<!-- /host -->\n<!-- host:agents -->\n{SENTENCE}\n<!-- /host -->\n"
    );
    put(t.path(), "lib/radin-twin.md", &twin);
    assert_eq!(lint_all(t.path()), Vec::<String>::new());
}

#[test]
fn sentence_repeated_outside_any_host_block_fails() {
    let t = fixture();
    put(t.path(), "skills/x/SKILL.md", "clean\n");
    put(
        t.path(),
        "lib/radin-twin.md",
        &format!("{SENTENCE}\n\n{SENTENCE}\n"),
    );
    assert_eq!(
        lint_all(t.path()),
        vec![
            "lib/radin-twin.md:3: repeats lib/radin-twin.md:1; state it once there and point to it"
        ]
    );
}

#[test]
fn skill_name_outside_the_table_and_token_missing_from_it_fail() {
    let t = fixture();
    put(t.path(), "skills/x/SKILL.md", "clean\n");
    for n in ["agents", "claude"] {
        let f = format!("lib/skill-names-{n}.txt");
        put(t.path(), &f, &read(repo(), &f).unwrap());
    }
    put(t.path(), "lib/radin-scope.sh", "# /ponytail:ponytail\n");
    assert_eq!(
        lint_all(t.path()),
        vec!["lib/radin-scope.sh:1: skill name outside the table; use radin_skill NAME"]
    );
    put(t.path(), "lib/radin-scope.sh", "clean\n");
    put(t.path(), "skills/x/SKILL.md", "@@skill:nope@@\n");
    let got = lint_names(t.path());
    assert_eq!(
        got,
        vec![
            "skills/x/SKILL.md:1: skill nope is not in lib/skill-names-agents.txt",
            "skills/x/SKILL.md:1: skill nope is not in lib/skill-names-claude.txt",
        ]
    );
}

fn slash_tokens(root: &Path) -> BTreeSet<String> {
    let tok = re(r#"(^|[\s=])[*_('"]*`?/[a-z0-9][a-z0-9:-]*"#);
    let mut files = prose_files(root)
        .into_iter()
        .filter(|f| f.starts_with("skills/") || f.starts_with("lib/"))
        .collect::<Vec<_>>();
    files.extend(["lib/radin-backlog.sh".into(), "lib/radin-scope.sh".into()]);
    let mut out = BTreeSet::new();
    for f in files {
        for l in read(root, &f).unwrap_or_default().lines() {
            for m in tok.find_iter(l) {
                let t: String = m
                    .as_str()
                    .chars()
                    .filter(|c| !c.is_whitespace() && !"`*_('\"=".contains(*c))
                    .collect();
                out.insert(t.trim_start_matches('/').to_string());
            }
        }
    }
    out
}

#[test]
fn every_slash_skill_name_resolves_to_a_shipped_skill() {
    let tokens = slash_tokens(repo());
    assert!(!tokens.is_empty());
    let unknown: Vec<&String> = tokens
        .iter()
        .filter(|t| match t.split_once(':') {
            Some((prefix, _)) => !PLUGINS.contains(&prefix),
            None => {
                !repo().join("skills").join(t).join("SKILL.md").is_file()
                    && ![COMPANIONS.as_slice(), &EXAMPLES, &NOT_SKILLS]
                        .concat()
                        .contains(&t.as_str())
            }
        })
        .collect();
    assert!(unknown.is_empty(), "unresolvable skill names: {unknown:?}");
}

#[test]
fn no_skill_invokes_a_disable_model_invocation_skill() {
    let files = skill_files(repo());
    let mut hit = Vec::new();
    for f in &files {
        let src = read(repo(), f).unwrap();
        if !src.lines().any(|l| l == "disable-model-invocation: true") {
            continue;
        }
        let name = f.split('/').nth(1).unwrap();
        for g in files.iter().filter(|g| *g != f) {
            if read(repo(), g)
                .unwrap()
                .contains(&format!("invoke `/{name}`"))
            {
                hit.push(format!("{g}->{name}"));
            }
        }
    }
    assert!(
        hit.is_empty(),
        "model-side invocation of a user-only skill: {hit:?}"
    );
}

#[test]
fn both_skill_name_tables_hold_the_same_keys_with_matching_values() {
    let claude = table_rows(repo(), "lib/skill-names-claude.txt");
    let agents = table_rows(repo(), "lib/skill-names-agents.txt");
    let keys = |t: &[Vec<String>]| t.iter().map(|r| r[0].clone()).collect::<Vec<_>>();
    assert_eq!(keys(&claude), keys(&agents));
    for (c, a) in claude.iter().zip(&agents) {
        let (k, v) = (&c[0], &c[1]);
        let name = match v.strip_prefix('/') {
            Some(p) if p.contains(':') => {
                let (prefix, name) = p.rsplit_once(':').unwrap();
                let prefix = prefix.split(':').next().unwrap();
                assert!(PLUGINS.contains(&prefix), "bad plugin {v}");
                name
            }
            Some(p) => {
                assert!(COMPANIONS.contains(&p), "bad companion {v}");
                p
            }
            None => panic!("claude value without slash: {v}"),
        };
        assert_eq!(a[1], name, "{k}: agents value {}, want {name}", a[1]);
        assert_eq!(k, name, "{k}: key differs from skill name {name}");
    }
}

#[test]
fn every_skill_token_resolves_in_both_tables() {
    let sites = token_sites(repo());
    assert!(!sites.is_empty());
    for h in ["claude", "agents"] {
        let keys: Vec<String> = table_rows(repo(), &format!("lib/skill-names-{h}.txt"))
            .into_iter()
            .map(|r| r[0].clone())
            .collect();
        for (f, n, k) in &sites {
            assert!(keys.contains(k), "{f}:{n}: {k} missing from {h}");
        }
    }
}

#[test]
fn companion_skills_has_a_well_formed_row_for_every_agents_skill_name() {
    let rows = table_rows(repo(), "lib/companion-skills.txt");
    let mut firsts = HashSet::new();
    for r in &rows {
        assert_eq!(r.len(), 4, "row needs 4 fields: {r:?}");
        let (n, c, b, f) = (&r[0], &r[1], &r[2], &r[3]);
        assert!(firsts.insert(n), "duplicate row {n}");
        assert!(
            ["caveman", "ponytail", "mattpocock-skills", "pstack"].contains(&c.as_str()),
            "{n}: bad companion {c}"
        );
        assert!(
            b.starts_with("https://raw.githubusercontent.com/"),
            "{n}: bad base {b}"
        );
        assert!(
            f == "SKILL.md" || f.starts_with("SKILL.md,"),
            "{n}: files must start with SKILL.md"
        );
    }
    for r in table_rows(repo(), "lib/skill-names-agents.txt") {
        assert!(
            rows.iter().any(|c| c[0] == r[0]),
            "{} missing from companion-skills.txt",
            r[0]
        );
    }
}

use radin::render::{apply_tokens, render, Rules, Tokens};
use radin::Host;
use sha2::{Digest, Sha256};
use std::fs;
use std::path::Path;

const LIB_SUFFIX: &str = "/.radin/hosts/claude/lib";

fn normalise(s: &str) -> String {
    let mut out = String::new();
    let mut run = String::new();
    let flush = |run: &mut String, out: &mut String| {
        let mut rest = run.as_str();
        while let Some(p) = rest.rfind(LIB_SUFFIX) {
            out.push_str("@RADIN_LIB@");
            rest = &rest[p + LIB_SUFFIX.len()..];
        }
        out.push_str(rest);
        run.clear();
    };
    for c in s.chars() {
        if c == '"' || c.is_whitespace() {
            flush(&mut run, &mut out);
            out.push(c);
        } else {
            run.push(c);
        }
    }
    flush(&mut run, &mut out);
    out.replace("\"$HOME/.radin/bin/radin\"", "@RADIN_CLI@")
}

#[test]
fn claude_render_matches_recorded_sums() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let rules = Rules::embedded("claude").unwrap();
    let tokens = Tokens {
        host: Host::Claude,
        model_major: "sonnet".into(),
        model_minor: "haiku".into(),
        effort_major: String::new(),
        effort_minor: String::new(),
        cli: "\"$HOME/.radin/bin/radin\"".into(),
        lib_dir: "/home/u/.radin/hosts/claude/lib".into(),
    };
    let mut got: Vec<(String, String)> = Vec::new();
    for line in fs::read_to_string(root.join("SHIPPED")).unwrap().lines() {
        let f: Vec<&str> = line.split_whitespace().collect();
        let (key, rel) = match f.as_slice() {
            ["skill", n] => (
                format!("skills/{n}/SKILL.md"),
                format!("skills/{n}/SKILL.md"),
            ),
            ["hostlib", n] => (format!("lib/{n}"), format!("lib/{n}")),
            _ => continue,
        };
        let src = fs::read_to_string(root.join(&rel)).unwrap();
        let text = apply_tokens(&render(&src, &rel, &rules).unwrap(), &tokens);
        let sum: String = Sha256::digest(normalise(&text).as_bytes())
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect();
        got.push((key, sum));
    }
    got.sort_by(|a, b| a.0.cmp(&b.0));
    if std::env::var("GOLDEN_UPDATE").as_deref() == Ok("1") {
        let text: String = got.iter().map(|(k, s)| format!("{s}  {k}\n")).collect();
        fs::write(root.join("tests/golden-claude-render.sha256"), text).unwrap();
    }
    let want: Vec<(String, String)> =
        fs::read_to_string(root.join("tests/golden-claude-render.sha256"))
            .unwrap()
            .lines()
            .map(|l| {
                let (s, k) = l.split_once("  ").unwrap();
                (k.to_string(), s.to_string())
            })
            .collect();
    let bad: Vec<String> = want
        .iter()
        .map(|(k, s)| {
            (
                k,
                s,
                got.iter().find(|(gk, _)| gk == k).map(|g| g.1.as_str()),
            )
        })
        .filter(|(_, s, g)| Some(s.as_str()) != *g)
        .map(|(k, s, g)| format!("{k}: expected {s} got {}", g.unwrap_or("missing")))
        .collect();
    assert!(bad.is_empty(), "{}", bad.join("\n"));
    assert_eq!(got.len(), want.len());
}

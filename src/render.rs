use crate::Host;
use std::fs;
use std::path::{Path, PathBuf};

const EMBEDDED: [(&str, &str, &str); 2] = [
    (
        "agents",
        include_str!("../lib/forbid-agents.txt"),
        include_str!("../lib/skill-names-agents.txt"),
    ),
    (
        "claude",
        include_str!("../lib/forbid-claude.txt"),
        include_str!("../lib/skill-names-claude.txt"),
    ),
];

pub struct Rules {
    host: String,
    hosts: Vec<String>,
    forbid: Vec<String>,
    names: Option<Vec<(String, String)>>,
}

pub fn embedded_names(host: &str) -> Option<&'static str> {
    EMBEDDED.iter().find(|e| e.0 == host).map(|e| e.2)
}

fn lines(text: &str) -> impl Iterator<Item = &str> {
    text.split_terminator('\n')
}

fn parse_forbid(text: &str) -> Vec<String> {
    lines(text)
        .filter(|l| !l.is_empty() && !l.starts_with('#'))
        .map(str::to_string)
        .collect()
}

pub fn parse_names(text: &str) -> Vec<(String, String)> {
    let blank = |c: char| c == ' ' || c == '\t';
    lines(text)
        .filter(|l| {
            !l.trim_start_matches(blank).is_empty() && !l.trim_start_matches(blank).starts_with('#')
        })
        .map(|l| match l.find(blank) {
            Some(i) => (
                l[..i].to_string(),
                l[i..].trim_start_matches(blank).to_string(),
            ),
            None => (l.to_string(), l.to_string()),
        })
        .collect()
}

impl Rules {
    pub fn embedded(host: &str) -> Result<Rules, String> {
        let e = EMBEDDED
            .iter()
            .find(|e| e.0 == host)
            .ok_or_else(|| format!("unknown host \"{host}\""))?;
        Ok(Rules {
            host: host.into(),
            hosts: EMBEDDED.iter().map(|e| e.0.to_string()).collect(),
            forbid: parse_forbid(e.1),
            names: Some(parse_names(e.2)),
        })
    }

    pub fn from_dir(dir: &Path, host: &str) -> Result<Rules, String> {
        let forbid = fs::read_to_string(dir.join(format!("forbid-{host}.txt")))
            .map_err(|_| format!("unknown host \"{host}\""))?;
        let mut hosts: Vec<String> = fs::read_dir(dir)
            .map_err(|_| format!("unknown host \"{host}\""))?
            .filter_map(|e| {
                let n = e.ok()?.file_name().into_string().ok()?;
                Some(n.strip_prefix("forbid-")?.strip_suffix(".txt")?.to_string())
            })
            .collect();
        hosts.sort();
        Ok(Rules {
            host: host.into(),
            hosts,
            forbid: parse_forbid(&forbid),
            names: fs::read_to_string(dir.join(format!("skill-names-{host}.txt")))
                .ok()
                .map(|t| parse_names(&t)),
        })
    }
}

fn is_blank(c: char) -> bool {
    c == ' ' || c == '\t'
}

fn marker_hosts(line: &str) -> Option<&str> {
    line.trim_matches(is_blank)
        .strip_prefix("<!-- host:")?
        .strip_suffix(" -->")
        .filter(|n| !n.contains(' '))
}

fn subst(line: &str, names: &[(String, String)]) -> Result<String, String> {
    let mut res = String::new();
    let mut line = line;
    while let Some(i) = line.find("@@skill:") {
        let rest = &line[i + 8..];
        let n = rest
            .find(|c: char| !(c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-'))
            .filter(|&n| n > 0 && rest[n..].starts_with("@@"))
            .ok_or("malformed skill token")?;
        let name = &rest[..n];
        let v = names
            .iter()
            .rev()
            .find(|(k, _)| k == name)
            .ok_or_else(|| format!("unknown skill name \"{name}\""))?;
        res.push_str(&line[..i]);
        res.push_str(&v.1);
        line = &rest[n + 2..];
    }
    res.push_str(line);
    Ok(res)
}

type Scan = (Vec<String>, Vec<String>);

fn scan(src: &str, label: &str, rules: &Rules) -> Result<Scan, String> {
    let names = rules
        .names
        .as_deref()
        .ok_or_else(|| format!("{label}: no skill-names-{}.txt", rules.host))?;
    let fail = |n: usize, why: String| format!("{label}:{n}: {why}");
    let (mut open, mut keep) = (0usize, false);
    let mut out = Vec::new();
    let mut hit = vec![false; rules.forbid.len()];
    for (idx, l) in lines(src).enumerate() {
        let n = idx + 1;
        if l.contains("<!-- host:") || l.contains("<!-- /host") {
            if l.trim_matches(is_blank) == "<!-- /host -->" {
                if open == 0 {
                    return Err(fail(n, "<!-- /host --> with no open block".into()));
                }
                open = 0;
                continue;
            }
            let list = marker_hosts(l)
                .ok_or_else(|| fail(n, "host marker must sit alone on its line".into()))?;
            if open != 0 {
                return Err(fail(n, format!("nested host block, opened at line {open}")));
            }
            if list.is_empty() {
                return Err(fail(n, "empty host name list".into()));
            }
            keep = false;
            for h in list.split(',') {
                if !rules.hosts.iter().any(|v| v == h) {
                    return Err(fail(n, format!("unknown host \"{h}\"")));
                }
                keep |= h == rules.host;
            }
            open = n;
            continue;
        }
        if open == 0 || keep {
            let line = subst(l, names).map_err(|e| fail(n, e))?;
            for (i, f) in rules.forbid.iter().enumerate() {
                hit[i] |= line.contains(f.as_str());
            }
            out.push(line);
        }
    }
    if open != 0 {
        return Err(fail(open, "host block never closed".into()));
    }
    let surviving = rules
        .forbid
        .iter()
        .zip(hit)
        .filter(|p| p.1)
        .map(|p| p.0.clone())
        .collect();
    Ok((out, surviving))
}

pub fn hits(src: &str, label: &str, rules: &Rules) -> Result<Vec<String>, String> {
    scan(src, label, rules).map(|s| s.1)
}

pub fn render(src: &str, label: &str, rules: &Rules) -> Result<String, String> {
    let (out, surviving) = scan(src, label, rules)?;
    if !surviving.is_empty() {
        return Err(surviving
            .iter()
            .map(|s| {
                format!(
                    "{label}: forbidden string \"{s}\" survives in the {} render",
                    rules.host
                )
            })
            .collect::<Vec<_>>()
            .join("\n"));
    }
    Ok(out.iter().map(|l| format!("{l}\n")).collect())
}

pub fn render_batch(pairs: &[(PathBuf, PathBuf)], rules: &Rules) -> Result<(), String> {
    let mut srcs = Vec::new();
    for (src, dest) in pairs {
        let text = fs::read_to_string(src).map_err(|_| format!("{}: unreadable", src.display()))?;
        if text.is_empty() {
            fs::write(dest, "").map_err(|e| format!("{}: {e}", dest.display()))?;
        } else {
            srcs.push((src, dest, text));
        }
    }
    if rules.names.is_none() && !srcs.is_empty() {
        return Err(format!("{0}: no skill-names-{0}.txt", rules.host));
    }
    for (src, dest, text) in srcs {
        let out = render(&text, &src.display().to_string(), rules)?;
        fs::write(dest, out).map_err(|e| format!("{}: {e}", dest.display()))?;
    }
    Ok(())
}

pub struct Tokens {
    pub host: Host,
    pub model_major: String,
    pub model_minor: String,
    pub effort_major: String,
    pub effort_minor: String,
    pub cli: String,
    pub lib_dir: String,
}

pub fn apply_tokens(text: &str, t: &Tokens) -> String {
    let mut s = text.to_string();
    if t.host == Host::Claude {
        for (kind, major, minor) in [
            ("MODEL", &t.model_major, &t.model_minor),
            ("EFFORT", &t.effort_major, &t.effort_minor),
        ] {
            for (role, v) in [
                ("PLANNING", major),
                ("EXECUTION", major),
                ("REVIEW", major),
                ("DEBUG", major),
                ("FACTFIND", minor),
                ("LOW", minor),
            ] {
                s = s.replace(&format!("RADIN_{kind}_{role}"), v);
            }
        }
    }
    let cli = match t.host {
        Host::Claude => t.cli.clone(),
        Host::Agents => format!("{} --host {}", t.cli, t.host.as_str()),
    };
    s.replace("RADIN_CLI", &cli)
        .replace("RADIN_LIB", &t.lib_dir)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn src(lines: &[&str]) -> String {
        lines.iter().map(|l| format!("{l}\n")).collect()
    }

    fn r(host: &str, lines: &[&str]) -> Result<String, String> {
        render(&src(lines), "in.md", &Rules::embedded(host).unwrap())
    }

    #[test]
    fn keeps_outside_text_and_matching_blocks_and_drops_markers() {
        let s = [
            "one",
            "<!-- host:claude -->",
            "c-only",
            "<!-- /host -->",
            "<!-- host:agents -->",
            "a-only",
            "<!-- /host -->",
            "<!-- host:claude,agents -->",
            "both",
            "<!-- /host -->",
            "two",
        ];
        assert_eq!(r("claude", &s).unwrap(), "one\nc-only\nboth\ntwo\n");
        assert_eq!(r("agents", &s).unwrap(), "one\na-only\nboth\ntwo\n");
    }

    #[test]
    fn marker_errors_name_file_and_line() {
        let e = |l: &[&str]| r("claude", l).unwrap_err();
        assert_eq!(
            e(&["one", "<!-- host:claude -->", "body"]),
            "in.md:2: host block never closed"
        );
        assert_eq!(
            e(&["one", "<!-- /host -->"]),
            "in.md:2: <!-- /host --> with no open block"
        );
        assert_eq!(
            e(&["<!-- host:claude -->", "<!-- host:agents -->"]),
            "in.md:2: nested host block, opened at line 1"
        );
        assert_eq!(
            e(&["one", "<!-- host:claude,mars -->"]),
            "in.md:2: unknown host \"mars\""
        );
        assert_eq!(
            e(&["one", "text <!-- host:claude -->"]),
            "in.md:2: host marker must sit alone on its line"
        );
        assert_eq!(e(&["<!-- host: -->"]), "in.md:1: empty host name list");
    }

    #[test]
    fn forbidden_string_fails_unless_inside_a_dropped_block() {
        assert_eq!(
            r("agents", &["one", "call SendMessage now"]).unwrap_err(),
            "in.md: forbidden string \"SendMessage\" survives in the agents render"
        );
        let s = [
            "one",
            "<!-- host:claude -->",
            "call SendMessage now",
            "<!-- /host -->",
        ];
        assert_eq!(r("agents", &s).unwrap(), "one\n");
        assert_eq!(
            r("claude", &["call SendMessage now"]).unwrap(),
            "call SendMessage now\n"
        );
    }

    #[test]
    fn hits_lists_surviving_strings_without_failing() {
        let rules = Rules::embedded("agents").unwrap();
        assert_eq!(
            hits(&src(&["call SendMessage now"]), "in.md", &rules).unwrap(),
            ["SendMessage"]
        );
        assert_eq!(hits("x\n", "in.md", &rules).unwrap(), Vec::<String>::new());
    }

    #[test]
    fn skill_tokens_render_each_host_value() {
        let s = ["Invoke `@@skill:grilling@@` now, then @@skill:ponytail-review@@."];
        assert_eq!(
            r("claude", &s).unwrap(),
            "Invoke `/mattpocock-skills:grilling` now, then /ponytail:ponytail-review.\n"
        );
        assert_eq!(
            r("agents", &s).unwrap(),
            "Invoke `grilling` now, then ponytail-review.\n"
        );
    }

    #[test]
    fn bad_skill_tokens_fail_with_line() {
        assert_eq!(
            r("agents", &["ok", "x @@skill:nope@@"]).unwrap_err(),
            "in.md:2: unknown skill name \"nope\""
        );
        assert_eq!(
            r("claude", &["@@skill:Bad Name@@"]).unwrap_err(),
            "in.md:1: malformed skill token"
        );
        assert_eq!(
            r("claude", &["@@skill:grilling"]).unwrap_err(),
            "in.md:1: malformed skill token"
        );
    }

    #[test]
    fn token_in_dropped_block_is_ignored() {
        let s = [
            "<!-- host:claude -->",
            "@@skill:nope@@",
            "<!-- /host -->",
            "@@skill:research@@",
        ];
        assert_eq!(r("agents", &s).unwrap(), "research\n");
    }

    #[test]
    fn unknown_host_and_missing_table() {
        assert_eq!(
            Rules::embedded("mars").err().unwrap(),
            "unknown host \"mars\""
        );
        let d = tempfile::tempdir().unwrap();
        for h in ["claude", "agents"] {
            fs::write(d.path().join(format!("forbid-{h}.txt")), "").unwrap();
        }
        let rules = Rules::from_dir(d.path(), "claude").unwrap();
        assert_eq!(
            render("one\n", "in.md", &rules).unwrap_err(),
            "in.md: no skill-names-claude.txt"
        );
        assert_eq!(
            Rules::from_dir(d.path(), "mars").err().unwrap(),
            "unknown host \"mars\""
        );
    }

    #[test]
    fn from_dir_adds_a_host_per_forbid_file() {
        let d = tempfile::tempdir().unwrap();
        for h in ["claude", "mars"] {
            fs::write(d.path().join(format!("forbid-{h}.txt")), "# c\nBAD\n").unwrap();
            fs::write(
                d.path().join(format!("skill-names-{h}.txt")),
                "# c\n\nk  v \n",
            )
            .unwrap();
        }
        let rules = Rules::from_dir(d.path(), "mars").unwrap();
        assert_eq!(
            render(
                "<!-- host:mars -->\n@@skill:k@@|\n<!-- /host -->\n",
                "f",
                &rules
            )
            .unwrap(),
            "v |\n"
        );
        assert_eq!(
            render("BAD\n", "f", &rules).unwrap_err(),
            "f: forbidden string \"BAD\" survives in the mars render"
        );
    }

    #[test]
    fn batch_keeps_empty_file_and_stops_at_a_bad_file() {
        let d = tempfile::tempdir().unwrap();
        let p = |n: &str| d.path().join(n);
        fs::write(
            p("a.md"),
            "one\n<!-- host:claude -->\nc-only\n<!-- /host -->\n",
        )
        .unwrap();
        fs::write(p("empty.md"), "").unwrap();
        fs::write(p("bad.md"), "bad\n<!-- host:claude -->\nbody\n").unwrap();
        fs::write(p("c.md"), "last\n").unwrap();
        let rules = Rules::embedded("claude").unwrap();
        let ok = [(p("a.md"), p("a.out")), (p("empty.md"), p("empty.out"))];
        render_batch(&ok, &rules).unwrap();
        assert_eq!(fs::read_to_string(p("a.out")).unwrap(), "one\nc-only\n");
        assert_eq!(fs::read_to_string(p("empty.out")).unwrap(), "");
        let bad = [(p("bad.md"), p("bad.out")), (p("c.md"), p("c.out"))];
        assert_eq!(
            render_batch(&bad, &rules).unwrap_err(),
            format!("{}:2: host block never closed", p("bad.md").display())
        );
        assert!(!p("bad.out").exists() && !p("c.out").exists());
        let gone = [(p("nope.md"), p("nope.out"))];
        assert_eq!(
            render_batch(&gone, &rules).unwrap_err(),
            format!("{}: unreadable", p("nope.md").display())
        );
    }

    fn lib_render(host: &str, rel: &str) -> String {
        let path = Path::new(env!("CARGO_MANIFEST_DIR")).join(rel);
        let text = fs::read_to_string(&path).unwrap();
        render(&text, rel, &Rules::embedded(host).unwrap()).unwrap()
    }

    #[test]
    fn agents_render_of_each_ask_site_names_the_ask_rule_and_no_question_tool() {
        for f in [
            "lib/radin-run.md",
            "lib/radin-batch-merge.md",
            "skills/radin-review/SKILL.md",
            "skills/radin-record/SKILL.md",
            "skills/radin-do/SKILL.md",
        ] {
            let out = lib_render("agents", f);
            assert!(out.contains("radin-ask-rule.md"), "{f}");
            assert!(!out.contains("AskUserQuestion"), "{f}");
        }
        for f in ["lib/radin-batch-session.md", "lib/radin-batch-clarify.md"] {
            assert!(!lib_render("agents", f).contains("AskUserQuestion"), "{f}");
        }
    }

    #[test]
    fn leaf_contract_and_explore_rule_name_no_claude_only_tool_on_agents() {
        for f in ["lib/radin-leaf-contract.md", "lib/radin-explore-rule.md"] {
            let out = lib_render("agents", f);
            for bad in [
                "Monitor",
                "Workflow",
                "TaskStop",
                "ToolSearch",
                "4 minutes",
                "AskUserQuestion",
            ] {
                assert!(!out.contains(bad), "{f} holds {bad}");
            }
        }
        let leaf = "lib/radin-leaf-contract.md";
        assert!(lib_render("agents", leaf).contains("no question tool"));
        let claude = lib_render("claude", leaf);
        assert!(claude.contains("Monitor") && claude.contains("Workflow"));
    }

    #[test]
    fn leaf_contract_runs_every_check_in_the_foreground_on_both_hosts() {
        for host in ["claude", "agents"] {
            let out = lib_render(host, "lib/radin-leaf-contract.md");
            assert!(out.contains("Run every check in the foreground"), "{host}");
        }
    }

    #[test]
    fn prompt_templates_drop_model_and_effort_lines_on_agents() {
        let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("lib");
        let mut seen = 0;
        for e in fs::read_dir(dir).unwrap() {
            let name = e.unwrap().file_name().into_string().unwrap();
            if !name.starts_with("radin-prompt-") {
                continue;
            }
            seen += 1;
            let rel = format!("lib/{name}");
            let agents = lib_render("agents", &rel);
            assert!(
                !agents
                    .lines()
                    .any(|l| l.starts_with("`model") || l.starts_with("`effort")),
                "{rel}"
            );
            assert!(
                !agents.contains("RADIN_MODEL_") && !agents.contains("model-low"),
                "{rel}"
            );
            let claude = lib_render("claude", &rel);
            assert_eq!(
                claude
                    .lines()
                    .filter(|l| l.starts_with("`model: \""))
                    .count(),
                1,
                "{rel}"
            );
        }
        assert!(seen >= 6);
    }

    #[test]
    fn recovery_prompt_holds_model_and_effort_tokens_only_on_claude() {
        let f = "lib/radin-batch-recovery.md";
        let agents = lib_render("agents", f);
        assert!(!agents.contains("RADIN_MODEL_") && !agents.contains("RADIN_EFFORT_"));
        assert!(lib_render("claude", f)
            .contains("`model: \"RADIN_MODEL_REVIEW\"`, `effort: \"RADIN_EFFORT_REVIEW\"`"));
    }

    #[test]
    fn tokens_replace_in_install_order() {
        let t = |host| Tokens {
            host,
            model_major: "sonnet".into(),
            model_minor: "haiku".into(),
            effort_major: "high".into(),
            effort_minor: String::new(),
            cli: "radin".into(),
            lib_dir: "/h/.radin/hosts/x/lib".into(),
        };
        let text = "RADIN_MODEL_PLANNING RADIN_MODEL_LOW RADIN_EFFORT_DEBUG RADIN_EFFORT_FACTFIND|RADIN_CLI|RADIN_LIB";
        assert_eq!(
            apply_tokens(text, &t(Host::Claude)),
            "sonnet haiku high |radin|/h/.radin/hosts/x/lib"
        );
        assert_eq!(
            apply_tokens(text, &t(Host::Agents)),
            "RADIN_MODEL_PLANNING RADIN_MODEL_LOW RADIN_EFFORT_DEBUG RADIN_EFFORT_FACTFIND|radin --host agents|/h/.radin/hosts/x/lib"
        );
    }
}

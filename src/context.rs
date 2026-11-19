//! Static context budget: the tokens a host's agent loads from radin's rendered files.
use crate::install::assets::Assets;
use crate::install::guidance::{agents_body, claude_body};
use crate::render::render;
use crate::shipped::shipped;
use crate::stats::{row, table, Rows};
use crate::{Ctx, Out};
use std::collections::{BTreeMap, BTreeSet};

const USAGE: &str = "usage: radin context [--check]\n";

/// Ceilings in estimated tokens per host. **Why:** the description of every skill and the radin
/// block sit in every session, and a route is what one skill pulls in when it runs.
const ALWAYS_CEILING: usize = 750;
const ROUTE_CEILING: usize = 10_200;

/// Four bytes a token, a rough rule that needs no tokenizer and moves with the text.
pub fn tokens(text: &str) -> usize {
    text.len().div_ceil(4)
}

struct Skill {
    name: String,
    /// Name and description: the part a host lists in every session.
    listed: usize,
    /// False when the render keeps the skill out of the model's list.
    model_invoked: bool,
    body: String,
}

fn split_skill(name: &str, text: &str) -> Skill {
    let rest = text.strip_prefix("---\n").unwrap_or(text);
    let (front, body) = rest.split_once("\n---\n").unwrap_or(("", rest));
    let mut desc = String::new();
    let mut in_desc = false;
    for l in front.lines() {
        if let Some(v) = l.strip_prefix("description:") {
            in_desc = true;
            desc += v.trim_matches(|c: char| c == '|' || c.is_whitespace());
        } else if in_desc && l.starts_with(' ') {
            desc += &format!(" {}", l.trim());
        } else {
            in_desc = false;
        }
    }
    Skill {
        name: name.into(),
        listed: tokens(&format!("name: {name}\ndescription: {}", desc.trim())),
        model_invoked: !front.contains("disable-model-invocation: true"),
        body: body.into(),
    }
}

/// Every `RADIN_LIB/<file>.md` a text names.
fn lib_refs(text: &str) -> BTreeSet<String> {
    text.match_indices("RADIN_LIB/")
        .filter_map(|(i, m)| {
            let rest = &text[i + m.len()..];
            let end = rest.find(".md")? + 3;
            let f = &rest[..end];
            f.chars()
                .all(|c| c.is_ascii_lowercase() || c == '-' || c == '.')
                .then(|| f.to_string())
        })
        .collect()
}

pub struct Report {
    pub always: usize,
    pub max_route: usize,
    text: String,
}

/// Measures one render (`claude` or `agents`) of the files radin ships.
pub fn measure(c: &Ctx, render_host: &str) -> Result<Report, String> {
    let assets = Assets::new(c.env);
    let rules = assets.rules(render_host)?;
    let s = shipped();
    let libs: Vec<(String, String)> = s
        .hostlib
        .iter()
        .map(|f| {
            let b = assets.lib(f).ok_or(format!("lib/{f}: unreadable"))?;
            let text = String::from_utf8_lossy(&b).into_owned();
            Ok((f.to_string(), render(&text, &format!("lib/{f}"), &rules)?))
        })
        .collect::<Result<_, String>>()?;
    let mut skills = Vec::new();
    for n in &s.skills {
        let b = assets
            .skill_files(n)
            .into_iter()
            .find(|f| f.0 == "SKILL.md")
            .ok_or(format!("{n}: no SKILL.md"))?;
        let text = String::from_utf8_lossy(&b.1).into_owned();
        skills.push(split_skill(
            n,
            &render(&text, &format!("skills/{n}"), &rules)?,
        ));
    }
    let lib_tokens = |f: &str| libs.iter().find(|l| l.0 == f).map_or(0, |l| tokens(&l.1));
    let block = tokens(&match render_host {
        "claude" => claude_body("radin"),
        _ => agents_body("radin"),
    });
    let mut always_rows = Rows::from([row(["item", "tokens"])]);
    always_rows.push(row(["radin block", &block.to_string()]));
    let mut always = block;
    for k in skills.iter().filter(|k| k.model_invoked) {
        always += k.listed;
        always_rows.push(row([&k.name, &k.listed.to_string()]));
    }
    always_rows.push(row(["total", &always.to_string()]));
    let mut routes: Vec<(usize, Vec<String>)> = Vec::new();
    let mut named: BTreeMap<String, usize> = BTreeMap::new();
    let mut max_route = 0;
    for k in &skills {
        let mut seen = lib_refs(&k.body);
        let mut todo: Vec<String> = seen.iter().cloned().collect();
        while let Some(f) = todo.pop() {
            if let Some(l) = libs.iter().find(|l| l.0 == f) {
                for r in lib_refs(&l.1) {
                    if seen.insert(r.clone()) {
                        todo.push(r);
                    }
                }
            }
        }
        for f in &seen {
            *named.entry(f.clone()).or_default() += 1;
        }
        let body = tokens(&k.body);
        let total = body + seen.iter().map(|f| lib_tokens(f)).sum::<usize>();
        max_route = max_route.max(total);
        routes.push((
            total,
            row([
                &k.name,
                &total.to_string(),
                &body.to_string(),
                &seen.len().to_string(),
            ]),
        ));
    }
    routes.sort_by_key(|r| std::cmp::Reverse(r.0));
    let mut route_rows = Rows::from([row(["skill", "tokens", "body", "lib files"])]);
    route_rows.extend(routes.into_iter().map(|r| r.1));
    let mut lib_rows = Rows::from([row(["lib file", "tokens", "routes naming it"])]);
    let mut by_size: Vec<_> = libs.iter().map(|l| (tokens(&l.1), &l.0)).collect();
    by_size.sort_by_key(|l| std::cmp::Reverse(l.0));
    for (t, f) in by_size {
        let n = named.get(f).copied().unwrap_or(0);
        lib_rows.push(row([
            f,
            &t.to_string(),
            &format!("{n} of {}", skills.len()),
        ]));
    }
    let text = table(
        &format!("{render_host}: always loaded (est. tokens, ceiling {ALWAYS_CEILING})"),
        &always_rows,
    ) + &table(
        &format!(
            "{render_host}: routes (skill body plus every lib file it names, worst case; ceiling {ROUTE_CEILING})"
        ),
        &route_rows,
    ) + &table(
        &format!("{render_host}: lib files (est. tokens; a file no route names loads through `radin prompt` or on demand)"),
        &lib_rows,
    );
    Ok(Report {
        always,
        max_route,
        text,
    })
}

/// The ceilings a report breaks, one line each.
pub fn breaches(host: &str, r: &Report) -> Vec<String> {
    let mut v = Vec::new();
    if r.always > ALWAYS_CEILING {
        v.push(format!(
            "{host}: always-loaded context is {} tokens, ceiling {ALWAYS_CEILING}",
            r.always
        ));
    }
    if r.max_route > ROUTE_CEILING {
        v.push(format!(
            "{host}: the largest route is {} tokens, ceiling {ROUTE_CEILING}",
            r.max_route
        ));
    }
    v
}

pub fn run(c: &Ctx, args: &[String]) -> Out {
    let check = match args {
        [] => false,
        [a] if a == "--check" => true,
        _ => return (1, String::new(), USAGE.into()),
    };
    let (mut out, mut bad) = (String::new(), Vec::new());
    for h in ["claude", "agents"] {
        match measure(c, h) {
            Ok(r) => {
                out += &r.text;
                bad.extend(breaches(h, &r));
            }
            Err(e) => return (1, out, format!("radin context: {e}\n")),
        }
    }
    if check && !bad.is_empty() {
        return (
            1,
            out,
            format!("radin context: {}\n", bad.join("\nradin context: ")),
        );
    }
    (0, out, String::new())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_report_over_a_ceiling_names_the_breach() {
        let r = Report {
            always: ALWAYS_CEILING + 1,
            max_route: ROUTE_CEILING,
            text: String::new(),
        };
        let v = breaches("claude", &r);
        assert_eq!(v.len(), 1, "{v:?}");
        assert!(v[0].contains("always-loaded"));
    }

    #[test]
    fn frontmatter_splits_a_block_description_and_the_opt_out() {
        let s = split_skill(
            "x",
            "---\nname: x\ndescription: |\n  Use for a.\n  Then b.\ndisable-model-invocation: true\n---\n# Body\n",
        );
        assert!(!s.model_invoked);
        assert_eq!(s.body, "# Body\n");
        assert_eq!(s.listed, tokens("name: x\ndescription: Use for a. Then b."));
    }

    #[test]
    fn lib_refs_find_every_named_file() {
        let r = lib_refs("Read `RADIN_LIB/radin-run.md` then RADIN_LIB/radin-batch-gate.md.");
        assert_eq!(r.len(), 2);
        assert!(r.contains("radin-batch-gate.md"));
    }
}

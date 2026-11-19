//! Tokens that radin skills, lib files and sub-agent reports add to a session's context.
//!
//! A request's context is `input + cache_creation + cache_read`. The growth from one request to
//! the next, minus the output of the first, is what the tool results in between added. That growth
//! is split over those results by size, so a radin item gets its share and nothing else is billed to it.
use super::transcripts::jsonl_files;
use super::{f0, row, sorted, with_header, Rows};
use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::fs;
use std::io::{BufRead, BufReader};
use std::path::Path;

#[derive(Default)]
struct Item {
    loads: u64,
    tokens: f64,
    max: f64,
    sessions: BTreeSet<String>,
}

#[derive(Default)]
pub(super) struct Load {
    items: BTreeMap<String, Item>,
    radin: f64,
    all: f64,
}

struct Req {
    key: String,
    total: u64,
    out: u64,
    day: String,
}

fn label_of(name: &str, input: &Value) -> Option<String> {
    let s = |k: &str| input.get(k).and_then(Value::as_str).unwrap_or("");
    match name {
        "Skill" => s("skill")
            .starts_with("radin")
            .then(|| format!("skill {}", s("skill"))),
        "Read" => {
            let p = s("file_path");
            let file = p.rsplit('/').next().unwrap_or("");
            (p.contains("/.radin/") && file.starts_with("radin-") && file.ends_with(".md"))
                .then(|| format!("lib {file}"))
        }
        // a leaf pulls its rendered prompt with `radin prompt <kind>`, so the prompt is a Bash result
        "Bash" => {
            let cmd = s("command");
            let kind = cmd
                .split_once("radin\"")
                .or_else(|| cmd.split_once("radin "))?
                .1
                .split(" prompt ")
                .nth(1)?
                .split_whitespace()
                .next()?
                .trim_matches(|c: char| !c.is_ascii_lowercase());
            const KINDS: [&str; 8] = [
                "planning",
                "execution",
                "debug",
                "factfind",
                "gate",
                "merge",
                "sync",
                "judge",
            ];
            KINDS.contains(&kind).then(|| format!("prompt {kind}"))
        }
        "Agent" => {
            let role = s("name")
                .strip_prefix("radin-")?
                .split('-')
                .next()?
                .to_string();
            Some(format!("agent radin-{role} report"))
        }
        _ => None,
    }
}

fn typed(text: &str) -> Option<String> {
    let rest = text.split("<command-name>/").nth(1)?;
    let n = rest.split('<').next()?;
    n.starts_with("radin").then(|| format!("skill {n}"))
}

impl Load {
    fn settle(
        &mut self,
        p: &Req,
        now: &Req,
        gap: &[(Option<String>, f64)],
        sid: &str,
        since: &str,
    ) {
        let Some(added) = now.total.checked_sub(p.total + p.out) else {
            return; // a compaction shrank the context
        };
        let sum: f64 = gap.iter().map(|g| g.1).sum();
        if sum == 0.0 || added == 0 || now.day.as_str() < since {
            return;
        }
        self.all += added as f64;
        let mut per: BTreeMap<&str, f64> = BTreeMap::new();
        for (l, w) in gap {
            if let Some(l) = l {
                *per.entry(l).or_default() += added as f64 * w / sum;
            }
        }
        for (l, t) in per {
            let it = self.items.entry(l.to_string()).or_default();
            it.loads += 1;
            it.tokens += t;
            it.max = it.max.max(t);
            it.sessions.insert(sid.to_string());
            self.radin += t;
        }
    }

    fn file(&mut self, path: &Path, sid: &str, since: &str) {
        let Ok(f) = fs::File::open(path) else { return };
        let mut prev: Option<Req> = None;
        let mut labels: HashMap<String, String> = HashMap::new();
        let mut gap: Vec<(Option<String>, f64)> = Vec::new();
        let mut last_skill: Option<String> = None;
        for l in BufReader::new(f).lines().map_while(Result::ok) {
            let assistant = l.contains("\"type\":\"assistant\"");
            if !assistant && !l.contains("\"type\":\"user\"") {
                continue;
            }
            let Ok(v) = serde_json::from_str::<Value>(&l) else {
                continue;
            };
            let m = &v["message"];
            if assistant {
                let u = &m["usage"];
                let n = |k: &str| u[k].as_u64().unwrap_or(0);
                let key = v["requestId"].as_str().or(m["id"].as_str()).unwrap_or("");
                if u.is_object() && !key.is_empty() {
                    let now = Req {
                        key: key.to_string(),
                        total: n("input_tokens")
                            + n("cache_creation_input_tokens")
                            + n("cache_read_input_tokens"),
                        out: n("output_tokens"),
                        day: v["timestamp"]
                            .as_str()
                            .unwrap_or("")
                            .chars()
                            .take(10)
                            .collect(),
                    };
                    match &mut prev {
                        Some(p) if p.key == now.key => p.out = p.out.max(now.out),
                        _ => {
                            if let Some(p) = &prev {
                                self.settle(p, &now, &gap, sid, since);
                            }
                            gap.clear();
                            last_skill = None;
                            prev = Some(now);
                        }
                    }
                }
                for c in m["content"].as_array().into_iter().flatten() {
                    if c["type"] == "tool_use" {
                        let id = c["id"].as_str().unwrap_or("");
                        if let Some(lb) = label_of(c["name"].as_str().unwrap_or(""), &c["input"]) {
                            labels.insert(id.to_string(), lb);
                        }
                    }
                }
            } else if let Some(t) = m["content"].as_str() {
                let lb = typed(t);
                last_skill = lb.clone().or(last_skill.take());
                gap.push((lb, t.len() as f64));
            } else {
                for c in m["content"].as_array().into_iter().flatten() {
                    let w = c.to_string().len() as f64;
                    if c["type"] == "tool_result" {
                        let lb = labels.get(c["tool_use_id"].as_str().unwrap_or("")).cloned();
                        if lb.as_deref().is_some_and(|x| x.starts_with("skill ")) {
                            last_skill = lb.clone();
                        }
                        gap.push((lb, w));
                    } else {
                        // the body of a skill arrives as a meta message after its tool result
                        gap.push((last_skill.clone(), w));
                    }
                }
            }
        }
    }

    pub(super) fn rows(&self) -> Rows {
        let body = self
            .items
            .iter()
            .map(|(k, i)| {
                row([
                    k,
                    &i.loads.to_string(),
                    &i.sessions.len().to_string(),
                    &f0(i.tokens),
                    &f0(i.tokens / i.loads as f64),
                    &f0(i.max),
                ])
            })
            .collect();
        let mut rows = sorted(body, &[(3, true)]);
        let pct = if self.all > 0.0 {
            100.0 * self.radin / self.all
        } else {
            0.0
        };
        rows.push(row([
            "all radin items",
            "",
            "",
            &f0(self.radin),
            "",
            &format!("{pct:.1}% of all context growth"),
        ]));
        with_header(
            row(["item", "loads", "sessions", "tokens", "avg", "max"]),
            rows,
        )
    }
}

pub(super) fn scan_load(root: &Path, since: &str) -> Load {
    let mut files = Vec::new();
    jsonl_files(root, &mut files);
    files.sort();
    let mut s = Load::default();
    for f in files {
        let sid = f
            .file_stem()
            .map(|x| x.to_string_lossy().into_owned())
            .unwrap_or_default();
        s.file(&f, &sid, since);
    }
    s
}

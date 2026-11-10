use super::{die, Fail};
use serde_json::{Map, Value};
use std::fs;
use std::path::{Path, PathBuf};

pub const CATEGORIES: [&str; 4] = ["feat", "fix", "chore", "refactor"];
pub const PRIORITY_SCALE: &str = "1 2 3 5 8 13 21";

#[derive(Clone)]
pub struct Entry {
    obj: Map<String, Value>,
    raw: String,
}

impl Entry {
    pub fn new(obj: Map<String, Value>) -> Entry {
        let raw = Value::Object(obj.clone()).to_string();
        Entry { obj, raw }
    }

    pub fn str(&self, k: &str) -> String {
        self.obj
            .get(k)
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string()
    }

    pub fn id(&self) -> String {
        self.str("id")
    }

    pub fn title(&self) -> String {
        self.str("title")
    }

    pub fn file(&self) -> String {
        self.str("file")
    }

    pub fn has(&self, k: &str) -> bool {
        self.obj.contains_key(k)
    }

    pub fn opt(&self, k: &str) -> Option<String> {
        self.has(k).then(|| self.str(k))
    }

    pub fn arr(&self, k: &str) -> Vec<String> {
        match self.obj.get(k) {
            Some(Value::Array(v)) => v
                .iter()
                .filter_map(|x| x.as_str().map(str::to_string))
                .collect(),
            _ => vec![],
        }
    }

    pub fn depends_on(&self) -> Vec<String> {
        self.arr("depends_on")
    }

    pub fn priority(&self) -> Option<String> {
        match self.obj.get("priority") {
            Some(Value::Number(n)) => {
                let s = n.to_string();
                let digits = s.strip_prefix('-').unwrap_or(&s);
                (!digits.is_empty() && digits.bytes().all(|b| b.is_ascii_digit())).then_some(s)
            }
            _ => None,
        }
    }

    pub fn epic(&self) -> String {
        epic_of(&self.file())
    }

    pub fn set(&mut self, k: &str, v: Option<Value>) {
        match v {
            Some(v) => {
                self.obj.insert(k.to_string(), v);
            }
            None if self.has(k) => {
                self.obj.shift_remove(k);
            }
            None => return,
        }
        self.raw = Value::Object(self.obj.clone()).to_string();
    }

    pub fn raw(&self) -> &str {
        &self.raw
    }

    pub fn meta_lines(&self) -> Vec<String> {
        let mut v = vec![];
        for (label, key) in [
            ("plan", "plan"),
            ("skill", "skills"),
            ("acceptance", "acceptance"),
        ] {
            v.extend(self.arr(key).into_iter().map(|x| format!("{label}\t{x}")));
        }
        for k in [
            "facts",
            "location",
            "planning",
            "complexity",
            "exclusive",
            "origin",
        ] {
            v.extend(self.opt(k).map(|x| format!("{k}\t{x}")));
        }
        v
    }

    pub fn row(&self, sep: &str) -> String {
        [
            self.id(),
            self.str("category"),
            self.title(),
            self.file(),
            self.priority().unwrap_or_default(),
            self.depends_on().join(","),
        ]
        .join(sep)
    }
}

pub fn epic_of(file: &str) -> String {
    file.strip_prefix("tasks/")
        .and_then(|r| r.split_once('/'))
        .map(|(e, _)| e.to_string())
        .unwrap_or_default()
}

pub struct Index {
    pub path: PathBuf,
    pub entries: Vec<Entry>,
}

impl Index {
    pub fn load(path: PathBuf) -> Result<Index, Fail> {
        let mut entries = vec![];
        if let Ok(text) = fs::read_to_string(&path) {
            for (n, line) in text.lines().enumerate() {
                if line.trim().is_empty() {
                    continue;
                }
                match serde_json::from_str::<Value>(line) {
                    Ok(Value::Object(obj)) => entries.push(Entry {
                        obj,
                        raw: line.to_string(),
                    }),
                    _ => {
                        return Err(die(format!("index line {} is not a JSON object", n + 1)));
                    }
                }
            }
        }
        Ok(Index { path, entries })
    }

    pub fn require(path: PathBuf) -> Result<Index, Fail> {
        if fs::metadata(&path).map_or(true, |m| m.len() == 0) {
            return Err(die(format!("no backlog at {}", path.display())));
        }
        Index::load(path)
    }

    pub fn write(&self) -> Result<(), Fail> {
        let mut text = self
            .entries
            .iter()
            .map(Entry::raw)
            .collect::<Vec<_>>()
            .join("\n");
        if !text.is_empty() {
            text.push('\n');
        }
        let mut tmp = self.path.clone().into_os_string();
        tmp.push(".tmp");
        let tmp = PathBuf::from(tmp);
        fs::write(&tmp, text)
            .and_then(|()| fs::rename(&tmp, &self.path))
            .map_err(|e| {
                let _ = fs::remove_file(&tmp);
                die(e.to_string())
            })
    }

    pub fn matches(&self, q: &str) -> Vec<usize> {
        let by = |f: &dyn Fn(&Entry) -> bool| -> Vec<usize> {
            (0..self.entries.len())
                .filter(|&i| f(&self.entries[i]))
                .collect()
        };
        let hit = by(&|e| e.id() == q);
        if !hit.is_empty() {
            return hit;
        }
        let hit = by(&|e| e.title() == q);
        if !hit.is_empty() || q.is_empty() {
            return hit;
        }
        let lq = q.to_ascii_lowercase();
        by(&|e| e.title().to_ascii_lowercase().contains(&lq))
    }

    pub fn single(&self, q: &str) -> Result<usize, Fail> {
        match self.matches(q).as_slice() {
            [] => Err(die(format!("no entry matches: {q}"))),
            [i] => Ok(*i),
            many => {
                let rows = self.rows(many, "");
                Err(die(format!(
                    "matches {} entries: {q}\n{}",
                    many.len(),
                    rows.trim_end_matches('\n')
                )))
            }
        }
    }

    pub fn rows(&self, hits: &[usize], prefix: &str) -> String {
        hits.iter()
            .map(|&i| format!("{prefix}{}\n", self.entries[i].row("\t")))
            .collect()
    }

    pub fn has_id(&self, id: &str) -> bool {
        self.entries.iter().any(|e| e.id() == id)
    }

    pub fn dir(&self) -> &Path {
        self.path.parent().unwrap_or(Path::new("."))
    }

    pub fn task_path(&self, rel: &str) -> PathBuf {
        self.dir().join(rel)
    }

    pub fn entry_path(&self, e: &Entry) -> PathBuf {
        self.task_path(&e.file())
    }

    pub fn remove_id(&mut self, id: &str) -> Vec<String> {
        let files = self
            .entries
            .iter()
            .filter(|e| e.id() == id)
            .map(Entry::file)
            .collect();
        self.entries.retain(|e| e.id() != id);
        for e in &mut self.entries {
            let deps = e.depends_on();
            if deps.iter().any(|d| d == id) {
                let kept: Vec<Value> = deps
                    .into_iter()
                    .filter(|d| d != id)
                    .map(Value::String)
                    .collect();
                e.set("depends_on", (!kept.is_empty()).then(|| Value::Array(kept)));
            }
        }
        files
    }
}

pub fn iso_utc(secs: i64) -> String {
    let (days, rem) = (secs.div_euclid(86_400), secs.rem_euclid(86_400));
    let z = days + 719_468;
    let (era, doe) = (z.div_euclid(146_097), z.rem_euclid(146_097));
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + i64::from(m <= 2);
    format!(
        "{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}Z",
        rem / 3600,
        rem % 3600 / 60,
        rem % 60
    )
}

pub fn slugify(s: &str) -> String {
    let mut out = String::new();
    for c in s.to_ascii_lowercase().chars() {
        if c.is_ascii_lowercase() || c.is_ascii_digit() {
            out.push(c);
        } else if !out.is_empty() && !out.ends_with('-') {
            out.push('-');
        }
    }
    out.trim_end_matches('-').to_string()
}

fn has_line_break(s: &str) -> bool {
    s.contains(['\t', '\r', '\n'])
}

pub fn require_plain_title(t: &str) -> Result<(), Fail> {
    if has_line_break(t) {
        return Err(die(format!(
            "title must not contain a tab, carriage return or newline: {t}"
        )));
    }
    Ok(())
}

pub fn require_meta_value(key: &str, v: &str) -> Result<(), Fail> {
    if v.is_empty() {
        return Err(die(format!("{key} value must not be empty")));
    }
    if has_line_break(v) {
        return Err(die(format!(
            "{key} value must not contain a tab, carriage return or newline: {v}"
        )));
    }
    match key {
        "planning" if v != "needed" => Err(die(format!("planning takes only \"needed\", got: {v}"))),
        "complexity" if v != "low" && v != "high" => Err(die(format!(
            "complexity takes only \"low\" or \"high\", got: {v}"
        ))),
        "exclusive" if v != "yes" => Err(die(format!("exclusive takes only \"yes\", got: {v}"))),
        "acceptance" if ["- ", "[ ]", "[x]", "[X]"].iter().any(|p| v.starts_with(p)) => Err(die(format!(
            "acceptance takes one criterion as bare text, with no \"- \" bullet and no \"[ ]\" checkbox: {v}"
        ))),
        _ => Ok(()),
    }
}

pub fn require_no_moved_label(text: &str) -> Result<(), Fail> {
    const LABELS: [&str; 8] = [
        "**Plan:**",
        "**Skill:**",
        "**Acceptance:**",
        "**Facts:**",
        "**Location:**",
        "**Planning:**",
        "**Complexity:**",
        "**Exclusive:**",
    ];
    match text.split('\n').find(|l| LABELS.iter().any(|p| l.starts_with(p))) {
        Some(l) => Err(die(format!(
            "that label lives on the index line now, not in the body: {l}\nwrite it with `add --skill`, `add-plan` or `backlog set-meta` instead"
        ))),
        None => Ok(()),
    }
}

pub fn require_priority(v: &str) -> Result<(), Fail> {
    if PRIORITY_SCALE.split(' ').any(|p| p == v) {
        return Ok(());
    }
    Err(die(format!(
        "priority must be one of {PRIORITY_SCALE} (higher wins), got: {v}"
    )))
}

pub fn strs(v: &[String]) -> Value {
    Value::Array(v.iter().cloned().map(Value::String).collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn civil_from_days_formats_a_known_instant() {
        assert_eq!(iso_utc(1_700_000_000), "2023-11-14T22:13:20Z");
        assert_eq!(iso_utc(0), "1970-01-01T00:00:00Z");
        assert_eq!(iso_utc(951_782_400), "2000-02-29T00:00:00Z");
    }

    #[test]
    fn slugify_squeezes_and_trims() {
        assert_eq!(slugify("Broken Auth"), "broken-auth");
        assert_eq!(slugify("  --a__b!! "), "a-b");
        assert_eq!(slugify("!!!"), "");
        assert_eq!(
            slugify("evil \"file\":\"tasks/hack.md\" and back\\slash"),
            "evil-file-tasks-hack-md-and-back-slash"
        );
        assert_eq!(slugify("ÄB"), "b");
    }

    #[test]
    fn epic_of_reads_one_nesting_level() {
        assert_eq!(epic_of("tasks/a/b.md"), "a");
        assert_eq!(epic_of("tasks/b.md"), "");
    }

    #[test]
    fn priority_accepts_only_digits() {
        let e = |s: &str| Entry::new(serde_json::from_str(s).unwrap());
        assert_eq!(e(r#"{"priority":70}"#).priority().as_deref(), Some("70"));
        assert_eq!(e(r#"{"priority":"5"}"#).priority(), None);
        assert_eq!(e(r#"{"priority":5.5}"#).priority(), None);
        assert_eq!(e(r#"{}"#).priority(), None);
    }

    #[test]
    fn matches_use_three_tiers() {
        let mk = |id: &str, t: &str| {
            Entry::new(serde_json::from_str(&format!(r#"{{"id":"{id}","title":"{t}"}}"#)).unwrap())
        };
        let idx = Index {
            path: PathBuf::new(),
            entries: vec![mk("a", "Alpha One"), mk("b", "alpha one"), mk("c", "ALPHA")],
        };
        assert_eq!(idx.matches("a"), vec![0]);
        assert_eq!(idx.matches("alpha one"), vec![1]);
        assert_eq!(idx.matches("alpha"), vec![0, 1, 2]);
        assert!(idx.matches("").is_empty());
    }

    #[test]
    fn validators_reject_their_inputs() {
        assert!(require_plain_title("a\tb").is_err());
        assert!(require_meta_value("planning", "x").is_err());
        assert!(require_meta_value("complexity", "mid").is_err());
        assert!(require_meta_value("acceptance", "- bullet").is_err());
        assert!(require_meta_value("acceptance", "[x] done").is_err());
        assert!(require_meta_value("facts", "").is_err());
        assert!(require_meta_value("location", "a.c:3").is_ok());
        assert!(require_no_moved_label("ok\n**Facts:** x").is_err());
        assert!(require_no_moved_label("**Fact:** x").is_ok());
        assert!(require_priority("13").is_ok());
        assert!(require_priority("7").is_err());
    }
}

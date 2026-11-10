use super::{die, S};
use crate::backlog::Fail;
use std::fs;
use std::io::Write;
use std::path::Path;

pub const MAX_ATTEMPTS: u64 = 3;
pub const FINDING_SECTIONS: &str = "outcome decisions alternatives changes reach-and-reuse rubrics-triggered modes-and-states order testing risks out-of-scope";

pub fn json_escape(s: &str) -> String {
    s.replace('\\', "\\\\").replace('"', "\\\"")
}

fn string_len(s: &str) -> Option<usize> {
    let b = s.as_bytes();
    let mut i = 0;
    while i < b.len() {
        match b[i] {
            b'\\' => i += 2,
            b'"' => return Some(i),
            _ => i += 1,
        }
    }
    None
}

/// The last `"key":"…"` string of a JSONL line, unescaped.
pub fn get(line: &str, key: &str) -> String {
    let pat = format!("\"{key}\":\"");
    let mut end = line.len();
    while let Some(i) = line[..end].rfind(&pat) {
        let start = i + pat.len();
        if let Some(n) = string_len(&line[start..]) {
            return line[start..start + n]
                .replace("\\\"", "\"")
                .replace("\\\\", "\\");
        }
        end = start - 1;
    }
    String::new()
}

/// The last `"key":<digits>` of a line, 0 when absent.
pub fn num(line: &str, key: &str) -> u64 {
    let pat = format!("\"{key}\":");
    let mut end = line.len();
    while let Some(i) = line[..end].rfind(&pat) {
        let rest = &line[i + pat.len()..];
        let digits: String = rest.chars().take_while(char::is_ascii_digit).collect();
        if !digits.is_empty() {
            return digits.parse().unwrap_or(0);
        }
        end = i + pat.len() - 1;
    }
    0
}

fn deps_inner(line: &str) -> Option<&str> {
    let pat = "\"depends_on\":[";
    let mut end = line.len();
    while let Some(i) = line[..end].rfind(pat) {
        let rest = &line[i + pat.len()..];
        if let Some(j) = rest.find(']') {
            return Some(&rest[..j]);
        }
        end = i + pat.len() - 1;
    }
    None
}

pub fn deps_csv(line: &str) -> String {
    deps_inner(line).map_or_else(String::new, |v| v.replace(['"', ' '], ""))
}

pub fn deps_json(csv: &str) -> String {
    let ids: Vec<String> = csv
        .split(',')
        .filter(|d| !d.is_empty())
        .map(|d| format!("\"{d}\""))
        .collect();
    format!("[{}]", ids.join(","))
}

#[allow(clippy::too_many_arguments)]
pub fn entry_json(
    id: &str,
    order: u64,
    status: &str,
    reason: &str,
    deps: &str,
    attempts: u64,
    debugged: u64,
    note: &str,
) -> String {
    format!(
        "{{\"id\":\"{}\",\"order\":{order},\"status\":\"{status}\",\"reason\":\"{reason}\",\"depends_on\":{deps},\"attempts\":{attempts},\"debugged\":{debugged},\"note\":\"{}\"}}",
        json_escape(id),
        json_escape(note)
    )
}

pub fn read_lines(p: &Path) -> Vec<String> {
    fs::read_to_string(p)
        .unwrap_or_default()
        .lines()
        .filter(|l| !l.is_empty())
        .map(String::from)
        .collect()
}

pub fn entry_line(p: &Path, id: &str) -> Option<String> {
    let key = format!("{{\"id\":\"{id}\",");
    read_lines(p).into_iter().find(|l| l.contains(&key))
}

pub fn write_atomic(p: &Path, text: &str) -> std::io::Result<()> {
    let mut tmp = p.as_os_str().to_owned();
    tmp.push(".tmp");
    fs::write(&tmp, text)?;
    fs::rename(tmp, p)
}

pub fn append(p: &Path, text: &str) {
    if let Ok(mut f) = fs::OpenOptions::new().create(true).append(true).open(p) {
        let _ = f.write_all(text.as_bytes());
    }
}

pub fn now_utc() -> String {
    let secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_secs() as i64);
    let (days, rem) = (secs.div_euclid(86400), secs.rem_euclid(86400));
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
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

pub fn run_stamp() -> String {
    format!(
        "r{}-{}",
        now_utc().replace(['-', ':'], ""),
        std::process::id()
    )
}

impl S<'_> {
    pub fn journal(&self, event: &str, id: &str, detail: &str) {
        self.journal_ctx(event, id, detail, &[]);
    }

    /// `dispatch` is a number, every other extra a string; empty extras are skipped.
    pub fn journal_ctx(&self, event: &str, id: &str, detail: &str, extras: &[(&str, String)]) {
        if self.state.is_dir() {
            let mut x = String::new();
            for (k, v) in extras.iter().filter(|(_, v)| !v.is_empty()) {
                x += &if *k == "dispatch" {
                    format!("\"{k}\":{v},")
                } else {
                    format!("\"{k}\":\"{}\",", json_escape(v))
                };
            }
            append(
                &self.state.join("journal.jsonl"),
                &format!(
                    "{{\"ts\":\"{}\",\"run\":\"{}\",{x}\"event\":\"{}\",\"id\":\"{}\",\"detail\":\"{}\"}}\n",
                    now_utc(),
                    json_escape(&self.run_id()),
                    json_escape(event),
                    json_escape(id),
                    json_escape(detail)
                ),
            );
        }
    }

    pub fn run_id(&self) -> String {
        get(&self.read("baseline.json"), "run_id")
    }

    /// Takes the next run-wide dispatch number for `id`; 0 without a state dir.
    pub fn dispatch_new(&self, id: &str, kind: &str) -> u64 {
        if !self.state.is_dir() {
            return 0;
        }
        let n = self.read("dispatch-seq").trim().parse::<u64>().unwrap_or(0) + 1;
        let _ = fs::write(self.state.join("dispatch-seq"), n.to_string());
        let _ = fs::create_dir_all(self.state.join("dispatch"));
        append(
            &self.state.join(format!("dispatch/{id}")),
            &format!("{n} {kind} {}\n", now_utc()),
        );
        n
    }

    /// The dispatches of `id` as (number, kind, ts), oldest first.
    pub fn dispatches(&self, id: &str) -> Vec<(u64, String, String)> {
        read_lines(&self.state.join(format!("dispatch/{id}")))
            .iter()
            .filter_map(|l| {
                let mut f = l.split(' ');
                Some((f.next()?.parse().ok()?, f.next()?.into(), f.next()?.into()))
            })
            .collect()
    }

    /// Dispatch extras for a journal line: the last dispatch of `id`, of `kind` when given.
    pub fn dispatch_extras(&self, id: &str, kind: Option<&str>) -> Vec<(&'static str, String)> {
        self.dispatches(id)
            .into_iter()
            .rfind(|d| kind.is_none_or(|k| d.1 == k))
            .map_or_else(Vec::new, |(n, k, _)| {
                vec![("dispatch", n.to_string()), ("kind", k)]
            })
    }

    pub fn entry(&self, id: &str) -> Option<String> {
        entry_line(&self.steps, id)
    }

    pub fn need_entry(&self, id: &str) -> Result<String, Fail> {
        self.entry(id)
            .ok_or_else(|| die(format!("no entry with id: {id}")))
    }

    /// Rewrites entry `id` with an empty reason; `debugged` None keeps the entry's own flag.
    pub fn write_entry(
        &self,
        id: &str,
        status: &str,
        attempts: u64,
        note: &str,
        debugged: Option<u64>,
    ) -> Result<(), Fail> {
        self.write_entry_as(id, status, "", attempts, note, debugged)
    }

    pub fn write_entry_as(
        &self,
        id: &str,
        status: &str,
        reason: &str,
        attempts: u64,
        note: &str,
        debugged: Option<u64>,
    ) -> Result<(), Fail> {
        let mut found = false;
        let mut out = String::new();
        let mut from = String::new();
        let mut unchanged = false;
        for line in read_lines(&self.steps) {
            if get(&line, "id") == id {
                from = get(&line, "status");
                unchanged = from == status
                    && num(&line, "attempts") == attempts
                    && get(&line, "note") == note;
                let deps = deps_inner(&line).map_or_else(|| "[]".to_string(), |d| format!("[{d}]"));
                let dbg = debugged.unwrap_or_else(|| num(&line, "debugged"));
                out += &entry_json(
                    id,
                    num(&line, "order"),
                    status,
                    reason,
                    &deps,
                    attempts,
                    dbg,
                    note,
                );
                found = true;
            } else {
                out += &line;
            }
            out.push('\n');
        }
        write_atomic(&self.steps, &out).map_err(|e| die(e.to_string()))?;
        if !found {
            return Err(die(format!("no entry with id: {id}")));
        }
        if !unchanged {
            let mut x = vec![("from", from)];
            x.extend(self.dispatch_extras(id, None));
            x.push((
                "wave",
                self.read(&format!("wave-of/{id}")).trim().to_string(),
            ));
            self.journal_ctx(status, id, note, &x);
        }
        Ok(())
    }

    /// Blocks `id` for `reason`; writes nothing when the entry already holds that block.
    pub fn set_blocked(&self, id: &str, reason: &str, note: &str) -> Result<bool, Fail> {
        let entry = self.need_entry(id)?;
        if get(&entry, "status") == "blocked"
            && get(&entry, "reason") == reason
            && get(&entry, "note") == note
        {
            return Ok(false);
        }
        self.write_entry_as(id, "blocked", reason, num(&entry, "attempts"), note, None)?;
        Ok(true)
    }

    /// Dependencies of `id`: the backlog's current list, else the copy `steps-init` stored.
    pub fn live_deps(&self, id: &str, entry: &str) -> String {
        let live = self.find_deps(id).replace(' ', "");
        if live.is_empty() {
            deps_csv(entry)
        } else {
            live
        }
    }

    pub fn set_status(&self, id: &str, status: &str, note: &str) -> Result<(), Fail> {
        let entry = self.need_entry(id)?;
        self.write_entry(id, status, num(&entry, "attempts"), note, None)
    }

    pub fn next_pending(&self) -> Option<(String, u64)> {
        let mut best: Option<(String, u64)> = None;
        for l in read_lines(&self.steps) {
            if get(&l, "status") != "pending" {
                continue;
            }
            let o = num(&l, "order");
            if best.as_ref().is_none_or(|(_, b)| o < *b) {
                best = Some((get(&l, "id"), o));
            }
        }
        best
    }

    /// Bumps attempts and sets `status`; Ok(false) once MAX_ATTEMPTS is passed and the entry is blocked.
    pub fn claim(&self, id: &str, status: &str, note: &str) -> Result<bool, Fail> {
        let entry = self.need_entry(id)?;
        let attempts = num(&entry, "attempts") + 1;
        if attempts > MAX_ATTEMPTS {
            self.write_entry_as(
                id,
                "blocked",
                "max-attempts",
                attempts - 1,
                &format!("dispatched {MAX_ATTEMPTS} times without a terminal status (MAX_ATTEMPTS) -- needs a human look before another retry"),
                None,
            )?;
            self.entry_note(
                id,
                &format!("dispatched {MAX_ATTEMPTS} times without finishing. Any work is committed as wip on its branch."),
            );
            return Ok(false);
        }
        self.rm(&format!("wave-of/{id}"));
        self.dispatch_new(
            id,
            if status == "pending" {
                "planning"
            } else {
                "execution"
            },
        );
        self.write_entry(id, status, attempts, note, None)?;
        Ok(true)
    }

    pub fn completed_get(&self, id: &str) -> Option<String> {
        entry_line(&self.completed, id).map(|l| get(&l, "commit"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn entry_json_matches_the_bash_printf_bytes() {
        assert_eq!(
            entry_json("a", 2, "pending", "", "[\"b\"]", 1, 0, "n\"q"),
            "{\"id\":\"a\",\"order\":2,\"status\":\"pending\",\"reason\":\"\",\"depends_on\":[\"b\"],\"attempts\":1,\"debugged\":0,\"note\":\"n\\\"q\"}"
        );
    }

    #[test]
    fn field_readers_take_the_last_match_and_unescape() {
        let l = entry_json(
            "t-1",
            7,
            "blocked",
            "max-attempts",
            "[\"x\", \"y\"]",
            3,
            1,
            "say \"hi\" \\ done",
        );
        assert_eq!(get(&l, "id"), "t-1");
        assert_eq!(get(&l, "reason"), "max-attempts");
        assert_eq!(get(&l, "note"), "say \"hi\" \\ done");
        assert_eq!(
            (num(&l, "order"), num(&l, "attempts"), num(&l, "debugged")),
            (7, 3, 1)
        );
        assert_eq!(deps_csv(&l), "x,y");
        assert_eq!(get(&l, "absent"), "");
        assert_eq!(num(&l, "absent"), 0);
    }

    #[test]
    fn json_escape_touches_only_backslash_and_quote() {
        assert_eq!(json_escape("a\\b\"c\td"), "a\\\\b\\\"c\td");
    }

    #[test]
    fn deps_json_quotes_each_id() {
        assert_eq!(deps_json(""), "[]");
        assert_eq!(deps_json("a,b"), "[\"a\",\"b\"]");
    }

    #[test]
    fn now_utc_has_the_iso_shape() {
        let t = now_utc();
        assert_eq!(t.len(), 20);
        assert!(t.ends_with('Z') && t.as_bytes()[10] == b'T');
        assert!(t.starts_with("20"));
    }
}

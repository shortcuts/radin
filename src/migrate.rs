use crate::paths::{git, Namespace};
use std::collections::HashSet;
use std::fs;
use std::io::{self, Write};
use std::os::unix::fs::symlink;
use std::path::{Path, PathBuf};
use std::thread::sleep;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

pub fn open(cwd: &Path, err: &mut String) -> Result<Namespace, String> {
    let ns = Namespace::locate(cwd);
    let tracked = if ns.created {
        migrate_state(&ns.repo_root, Duration::from_secs(5))?
    } else {
        false
    };
    ns.ensure_dirs()
        .map_err(|e| format!("radin: cannot create {}: {e}\n", ns.namespace_dir.display()))?;
    if ns.created {
        ignore_state(&ns.repo_root, tracked, err);
    }
    Ok(ns)
}

fn secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_secs())
}

fn ends_without_newline(p: &Path) -> bool {
    fs::read(p).is_ok_and(|b| b.last().is_some_and(|c| *c != b'\n'))
}

fn ensure_newline(p: &Path) {
    if ends_without_newline(p) {
        let _ = append(p, "\n");
    }
}

fn append(p: &Path, text: &str) -> io::Result<()> {
    if let Some(d) = p.parent() {
        fs::create_dir_all(d)?;
    }
    fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(p)?
        .write_all(text.as_bytes())
}

fn copy_tree(src: &Path, dst: &Path, clobber: bool) -> io::Result<()> {
    fs::create_dir_all(dst)?;
    for e in fs::read_dir(src)? {
        let e = e?;
        let (from, to) = (e.path(), dst.join(e.file_name()));
        let ty = e.file_type()?;
        if ty.is_dir() {
            copy_tree(&from, &to, clobber)?;
        } else if !clobber && fs::symlink_metadata(&to).is_ok() {
        } else if ty.is_symlink() {
            symlink(fs::read_link(&from)?, &to)?;
        } else {
            fs::copy(&from, &to)?;
        }
    }
    Ok(())
}

fn line_id(line: &str) -> String {
    let mut id = String::new();
    let mut rest = line;
    while let Some(at) = rest.find("\"id\":\"") {
        rest = &rest[at + 6..];
        let mut v = String::new();
        let mut chars = rest.char_indices();
        let mut closed = None;
        while let Some((i, c)) = chars.next() {
            match c {
                '"' => {
                    closed = Some(i);
                    break;
                }
                '\\' => match chars.next() {
                    Some((_, n)) => {
                        v.push('\\');
                        v.push(n);
                    }
                    None => break,
                },
                _ => v.push(c),
            }
        }
        let Some(end) = closed else { break };
        id = v.replace("\\\"", "\"").replace("\\\\", "\\");
        rest = &rest[end + 1..];
    }
    id
}

fn digits_then(s: &str, tail: &str) -> Option<usize> {
    let n = s.bytes().take_while(u8::is_ascii_digit).count();
    (n > 0 && s[n..].starts_with(tail)).then_some(n)
}

fn rewrite_paths(line: &str, old: &str, new: &str) -> String {
    let needle = format!("/{old}");
    let mut out = String::new();
    let mut rest = line;
    while let Some(at) = rest.find(&needle) {
        let after = &rest[at + needle.len()..];
        let keep = if after.starts_with(".md\"") {
            Some(0)
        } else {
            after
                .strip_prefix('-')
                .and_then(|a| digits_then(a, ".md\""))
                .map(|n| n + 1)
        };
        out.push_str(&rest[..at]);
        match keep {
            Some(n) => {
                out.push('/');
                out.push_str(new);
                out.push_str(&after[..n]);
                rest = &after[n..];
            }
            None => {
                out.push_str(&needle);
                rest = after;
            }
        }
    }
    out + rest
}

fn merge_index(dst: &Path, src: &Path) -> Vec<(String, String)> {
    let Ok(text) = fs::read_to_string(src).map(|t| t.trim_end().to_string()) else {
        return vec![];
    };
    if text.is_empty() {
        return vec![];
    }
    let mut taken: HashSet<String> = fs::read_to_string(dst)
        .unwrap_or_default()
        .lines()
        .map(line_id)
        .filter(|i| !i.is_empty())
        .collect();
    let lines: Vec<&str> = text.lines().collect();
    let incoming: HashSet<String> = lines.iter().map(|l| line_id(l)).collect();
    let mut map: Vec<(String, String)> = Vec::new();
    for id in lines.iter().map(|l| line_id(l)) {
        if id.is_empty() || !taken.contains(&id) {
            continue;
        }
        let mut new = format!("{id}-agents");
        let mut n = 2;
        while taken.contains(&new) || incoming.contains(&new) {
            new = format!("{id}-agents-{n}");
            n += 1;
        }
        taken.insert(new.clone());
        map.push((id, new));
    }
    ensure_newline(dst);
    let mut out = String::new();
    for l in lines {
        let id = line_id(l);
        let mut line = l.to_string();
        for (old, new) in &map {
            line = line.replace(&format!("\"{old}\""), &format!("\"{new}\""));
            if *old == id {
                line = rewrite_paths(&line, old, new);
            }
        }
        out.push_str(&line);
        out.push('\n');
    }
    let _ = append(dst, &out);
    map
}

fn files_under(root: &Path, rel: &str, into: &mut Vec<String>) {
    let Ok(rd) = fs::read_dir(root.join(rel)) else {
        return;
    };
    for e in rd.flatten() {
        let r = format!("{rel}/{}", e.file_name().to_string_lossy());
        match e.file_type() {
            Ok(t) if t.is_dir() => files_under(root, &r, into),
            Ok(t) if t.is_file() => into.push(r),
            _ => {}
        }
    }
}

fn renamed_base(rel: &str, old: &str, new: &str) -> Option<String> {
    let base = rel.rsplit('/').next()?;
    let ok = if rel.starts_with("backlog/tasks/") {
        base.strip_prefix(old).is_some_and(|r| r.starts_with('.'))
    } else if rel.starts_with("plans/") || rel.starts_with("state/facts/") {
        base.strip_prefix(old).is_some_and(|r| {
            r == ".md"
                || r.strip_prefix('-').is_some_and(|d| {
                    d.starts_with(|c: char| c.is_ascii_digit()) && d.ends_with(".md")
                })
        })
    } else if rel.starts_with("state/prompts/") {
        [
            "execution",
            "planning",
            "gate",
            "merge",
            "debug",
            "factfind",
        ]
        .iter()
        .any(|k| base.strip_prefix(old) == Some(&format!("-{k}.md")))
    } else {
        false
    };
    ok.then(|| format!("{new}{}", &base[old.len()..]))
}

fn merge(src: &Path, dst: &Path) -> io::Result<()> {
    let map = merge_index(
        &dst.join("backlog/index.jsonl"),
        &src.join("backlog/index.jsonl"),
    );
    let mut rels = Vec::new();
    for d in ["backlog/tasks", "plans", "state/facts", "state/prompts"] {
        files_under(src, d, &mut rels);
    }
    for (old, new) in &map {
        for rel in &rels {
            if let Some(nb) = renamed_base(rel, old, new) {
                let to = dst.join(rel.rsplit_once('/').map_or("", |x| x.0)).join(nb);
                fs::create_dir_all(to.parent().unwrap())?;
                fs::copy(src.join(rel), to)?;
            }
        }
    }
    for f in ["state/completed.json", "state/journal.jsonl"] {
        let text = fs::read(src.join(f)).unwrap_or_default();
        if !text.is_empty() {
            ensure_newline(&dst.join(f));
            append(&dst.join(f), &String::from_utf8_lossy(&text))?;
        }
    }
    copy_tree(src, dst, false)
}

fn retire(root: &Path, dir: &Path) {
    let rel = dir
        .strip_prefix(root)
        .unwrap_or(dir)
        .to_string_lossy()
        .into_owned();
    if git(root, &["ls-files", "--", &rel]).is_some_and(|o| !o.is_empty()) {
        git(root, &["rm", "-rqf", "--", &rel]);
    }
    let _ = fs::remove_dir_all(dir);
}

/// Returns whether git tracks any legacy or new state, which keeps the `.gitignore` untouched.
pub fn migrate_state(root: &Path, wait: Duration) -> Result<bool, String> {
    let tracked = git(
        root,
        &[
            "ls-files",
            "--",
            ".radin",
            ".claude/.radin",
            ".agents/.radin",
        ],
    )
    .is_some_and(|o| !o.is_empty());
    let legacy: Vec<PathBuf> = [".claude/.radin", ".agents/.radin"]
        .iter()
        .map(|d| root.join(d))
        .filter(|d| d.is_dir())
        .collect();
    if legacy.is_empty() {
        return Ok(tracked);
    }
    let stage = root.join(".radin.migrating");
    let aside = || {
        let _ = fs::rename(&stage, root.join(format!(".radin.migrating.{}", secs())));
    };
    if fs::create_dir(&stage).is_err() {
        let mut waited = Duration::ZERO;
        while !root.join(".radin").exists() && waited < wait {
            sleep(Duration::from_millis(100));
            waited += Duration::from_millis(100);
        }
        if root.join(".radin").exists() {
            return Ok(tracked);
        }
        aside();
        fs::create_dir(&stage).map_err(|_| "radin: migration in progress\n".to_string())?;
    }
    copy_tree(&legacy[0], &stage, true)
        .map_err(|_| format!("radin: cannot copy {}\n", legacy[0].display()))?;
    if let Some(second) = legacy.get(1) {
        let _ = merge(second, &stage);
    }
    let idx = stage.join("backlog/index.jsonl");
    if let Ok(t) = fs::read_to_string(&idx) {
        let fixed = t
            .replace("/.claude/.radin/", "/.radin/")
            .replace("/.agents/.radin/", "/.radin/");
        let _ = fs::write(&idx, fixed);
    }
    if root.join(".radin").exists() {
        aside();
        return Ok(tracked);
    }
    fs::rename(&stage, root.join(".radin"))
        .map_err(|_| "radin: cannot move .radin.migrating into place\n".to_string())?;
    for d in &legacy {
        retire(root, d);
    }
    Ok(tracked)
}

fn ignore_state(root: &Path, tracked: bool, err: &mut String) {
    if tracked
        || git(root, &["rev-parse", "--git-dir"]).is_none()
        || git(root, &["check-ignore", "-q", ".radin"]).is_some()
    {
        return;
    }
    let gi = root.join(".gitignore");
    ensure_newline(&gi);
    if append(&gi, ".radin/\n").is_ok() {
        err.push_str("radin: added .radin/ to .gitignore; delete the line to track it\n");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_last_id_string_wins_and_escapes_resolve() {
        assert_eq!(line_id(r#"{"id":"a","x":{"id":"b"}}"#), "b");
        assert_eq!(line_id(r#"{"id":"a\"b"}"#), "a\"b");
        assert_eq!(line_id(r#"{"title":"no id"}"#), "");
    }

    #[test]
    fn only_the_task_file_paths_of_an_id_are_renamed() {
        let l = r#"{"file":"/p/same.md","plan":["/p/same-12.md","/p/same-x.md","/p/same.md.bak"]}"#;
        assert_eq!(
            rewrite_paths(l, "same", "same-agents"),
            r#"{"file":"/p/same-agents.md","plan":["/p/same-agents-12.md","/p/same-x.md","/p/same.md.bak"]}"#
        );
    }

    #[test]
    fn renamed_copies_follow_the_per_directory_name_rules() {
        let r = |rel: &str| renamed_base(rel, "a", "a-agents");
        assert_eq!(r("backlog/tasks/a.md").as_deref(), Some("a-agents.md"));
        assert_eq!(r("backlog/tasks/ab.md"), None);
        assert_eq!(r("plans/a-2.md").as_deref(), Some("a-agents-2.md"));
        assert_eq!(r("plans/a.head"), None);
        assert_eq!(
            r("state/prompts/a-debug.md").as_deref(),
            Some("a-agents-debug.md")
        );
        assert_eq!(r("state/prompts/a-other.md"), None);
        assert_eq!(r("state/gate/a.md"), None);
    }
}

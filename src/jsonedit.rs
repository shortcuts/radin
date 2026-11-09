use crate::shellwords;
use crate::Out;
use serde_json::{Map, Value};
use std::fmt::Write as _;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;

type Obj = Map<String, Value>;

pub struct Ctx {
    pub home: Option<String>,
    pub path: Option<String>,
}

struct Fail {
    code: i32,
    msg: String,
}

pub enum Parsed {
    Absent,
    Invalid,
    Ok(Value),
}

fn fail<T>(code: i32, msg: String) -> Result<T, Fail> {
    Err(Fail { code, msg })
}

fn run(f: impl FnOnce(&mut String) -> Result<i32, Fail>) -> Out {
    let mut out = String::new();
    match f(&mut out) {
        Ok(code) => (code, out, String::new()),
        Err(e) => (e.code, out, e.msg),
    }
}

pub fn parse_file(path: &str) -> Parsed {
    if path.is_empty() {
        return Parsed::Absent;
    }
    match fs::read_to_string(path) {
        Err(_) => Parsed::Absent,
        Ok(t) => serde_json::from_str(&t).map_or(Parsed::Invalid, Parsed::Ok),
    }
}

pub fn load_strict(path: &str) -> Result<Option<Obj>, String> {
    match parse_file(path) {
        Parsed::Absent => Ok(None),
        Parsed::Ok(Value::Object(m)) => Ok(Some(m)),
        _ => Err(format!(
            "radin-cbm-config: {path} is not valid JSON -- nothing restored, your snapshot is still on disk\n"
        )),
    }
}

pub fn load_lax(path: &str) -> Obj {
    match parse_file(path) {
        Parsed::Ok(Value::Object(m)) => m,
        _ => Obj::new(),
    }
}

fn strict(path: &str) -> Result<Option<Obj>, Fail> {
    load_strict(path).or_else(|msg| fail(1, msg))
}

fn canon_to(v: &Value, o: &mut String) {
    match v {
        Value::Object(m) => {
            let mut keys: Vec<&String> = m.keys().collect();
            keys.sort();
            o.push('{');
            for (i, k) in keys.into_iter().enumerate() {
                if i > 0 {
                    o.push(',');
                }
                o.push_str(&Value::String(k.clone()).to_string());
                o.push_str(": ");
                canon_to(&m[k], o);
            }
            o.push('}');
        }
        Value::Array(a) => {
            o.push('[');
            for (i, x) in a.iter().enumerate() {
                if i > 0 {
                    o.push(',');
                }
                canon_to(x, o);
            }
            o.push(']');
        }
        _ => o.push_str(&v.to_string()),
    }
}

pub fn canon(v: Option<&Value>) -> String {
    let mut o = String::new();
    canon_to(v.unwrap_or(&Value::Object(Obj::new())), &mut o);
    o
}

pub fn write_file(path: &str, v: &Value) -> Result<(), String> {
    let tmp = format!("{path}.radin.tmp");
    let body = format!("{}\n", serde_json::to_string_pretty(v).unwrap());
    fs::write(&tmp, body).map_err(|_| format!("radin-cbm-config: cannot write {tmp}\n"))?;
    fs::rename(&tmp, path).map_err(|_| format!("radin-cbm-config: cannot write {path}\n"))
}

fn write(path: &str, root: &Obj) -> Result<(), Fail> {
    write_file(path, &Value::Object(root.clone())).or_else(|msg| fail(1, msg))
}

pub fn expanduser(ctx: &Ctx, p: &str) -> String {
    match (&ctx.home, p.strip_prefix('~')) {
        (Some(h), Some(rest)) if rest.is_empty() || rest.starts_with('/') => format!("{h}{rest}"),
        _ => p.to_string(),
    }
}

fn is_exec_file(p: &str) -> bool {
    // shortcut: any exec bit counts, not access(X_OK) for this user; use libc to tighten.
    fs::metadata(p).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
}

pub fn on_path_executable(ctx: &Ctx, word: &str) -> bool {
    if word.contains('/') {
        return is_exec_file(&expanduser(ctx, word));
    }
    let Some(path) = &ctx.path else { return false };
    path.split(':').any(|d| {
        let d = if d.is_empty() { "." } else { d };
        is_exec_file(&format!("{d}/{word}"))
    })
}

fn path_exists(p: &str) -> bool {
    Path::new(p).exists()
}

fn blank(s: &str) -> bool {
    s.chars().all(|c| matches!(c, ' ' | '\t' | '\n' | '\r'))
}

fn disp(v: Option<&Value>) -> String {
    match v {
        None => String::new(),
        Some(Value::String(s)) => s.clone(),
        Some(v) => canon(Some(v)),
    }
}

pub fn is_cbm_entry(entry: &Value, cbm: &str) -> bool {
    let b = canon(Some(entry));
    b.contains(cbm) || b.contains("cbm-")
}

fn command_str(h: &Value) -> Option<&str> {
    h.get("command")?.as_str()
}

pub fn command_exists(ctx: &Ctx, cmd: Option<&Value>) -> bool {
    let Some(Value::String(s)) = cmd else {
        return true;
    };
    if blank(s) {
        return true;
    }
    let Some(w) = shellwords::split(s).filter(|w| !w.is_empty()) else {
        return true;
    };
    let shell =
        !w[0].contains('/') && matches!(w[0].as_str(), "sh" | "bash" | "zsh") && w.len() > 1;
    let word = &w[usize::from(shell)];
    !word.contains('/') || path_exists(&expanduser(ctx, word))
}

fn hook_lists(hooks: &mut Obj) -> impl Iterator<Item = (&String, &mut Vec<Value>)> {
    hooks
        .iter_mut()
        .filter_map(|(k, v)| Some((k, v.as_array_mut()?)))
}

pub fn prune_dead(ctx: &Ctx, settings: &str, hooks: &mut Obj, out: &mut String) -> bool {
    let mut changed = false;
    for (key, entries) in hook_lists(hooks) {
        let mut kept = Vec::new();
        for mut entry in std::mem::take(entries) {
            let Some(hs) = entry.get("hooks").and_then(Value::as_array) else {
                kept.push(entry);
                continue;
            };
            let live: Vec<Value> = hs
                .iter()
                .filter(|h| {
                    let ok = !h.is_object() || command_exists(ctx, h.get("command"));
                    if !ok {
                        let _ = writeln!(
                            out,
                            "PRUNED   {settings} (hooks.{key}: '{}' does not exist)",
                            disp(h.get("command"))
                        );
                    }
                    ok
                })
                .cloned()
                .collect();
            if live.len() == hs.len() {
                kept.push(entry);
                continue;
            }
            changed = true;
            if !live.is_empty() {
                entry["hooks"] = Value::Array(live);
                kept.push(entry);
            }
        }
        *entries = kept;
    }
    changed
}

pub fn absolute(ctx: &Ctx, cmd: Option<&Value>) -> Option<String> {
    let Some(Value::String(s)) = cmd else {
        return None;
    };
    if blank(s) {
        return None;
    }
    let out = shellwords::split(s)?
        .iter()
        .map(|w| shellwords::quote(&expanduser(ctx, w)))
        .collect::<Vec<_>>()
        .join(" ");
    (out != *s).then_some(out)
}

pub fn normalize_cbm(
    ctx: &Ctx,
    settings: &str,
    cbm: &str,
    hooks: &mut Obj,
    out: &mut String,
) -> bool {
    let mut changed = false;
    for (key, entries) in hook_lists(hooks) {
        for entry in entries.iter_mut() {
            if !is_cbm_entry(entry, cbm) {
                continue;
            }
            let Some(hs) = entry.get_mut("hooks").and_then(Value::as_array_mut) else {
                continue;
            };
            for h in hs.iter_mut().filter(|h| h.is_object()) {
                let Some(new) = absolute(ctx, h.get("command")) else {
                    continue;
                };
                let _ = writeln!(out, "ABSOLUTE {settings} (hooks.{key}: '{new}')");
                h["command"] = Value::String(new);
                changed = true;
            }
        }
    }
    changed
}

fn plural(n: usize) -> &'static str {
    if n == 1 {
        "y"
    } else {
        "ies"
    }
}

fn whole_file(out: &mut String, path: &str, old: Obj) -> Result<(), Fail> {
    write(path, &old)?;
    let _ = writeln!(
        out,
        "RESTORED {path} (whole file -- upstream's write removed it)"
    );
    Ok(())
}

fn restore_settings(
    ctx: &Ctx,
    out: &mut String,
    settings: &str,
    snap: &str,
    cbm: &str,
) -> Result<(), Fail> {
    let old = strict(snap)?;
    let Some(mut new) = strict(settings)? else {
        return old.map_or(Ok(()), |o| whole_file(out, settings, o));
    };
    let mut changed = false;
    if let Some(old) = &old {
        for (k, v) in old.iter().filter(|(k, _)| *k != "hooks") {
            if !new.contains_key(k) {
                new.insert(k.clone(), v.clone());
                changed = true;
                let _ = writeln!(out, "RESTORED {settings} ({k})");
            }
        }
    }
    let old_hooks = old
        .as_ref()
        .and_then(|o| o.get("hooks"))
        .and_then(Value::as_object);
    let had_hooks = new.get("hooks").is_some_and(Value::is_object);
    let store = had_hooks || old_hooks.is_some_and(|h| !h.is_empty());
    let mut hooks = match new.get("hooks") {
        Some(Value::Object(m)) => m.clone(),
        _ => Obj::new(),
    };
    for (key, old_entries) in old_hooks.into_iter().flatten() {
        let Some(old_entries) = old_entries.as_array() else {
            continue;
        };
        let filtered: Vec<Value> = old_entries
            .iter()
            .filter(|e| !is_cbm_entry(e, cbm))
            .cloned()
            .collect();
        let Some(current) = hooks.get(key).and_then(Value::as_array) else {
            if filtered.is_empty() {
                continue;
            }
            let _ = writeln!(
                out,
                "RESTORED {settings} (hooks.{key}: {} entr{}, array was gone)",
                filtered.len(),
                plural(filtered.len())
            );
            hooks.insert(key.clone(), Value::Array(filtered));
            changed = true;
            continue;
        };
        let have: Vec<String> = current.iter().map(|c| canon(Some(c))).collect();
        let missing: Vec<Value> = filtered
            .into_iter()
            .filter(|f| !have.contains(&canon(Some(f))))
            .collect();
        if missing.is_empty() {
            let _ = writeln!(out, "INTACT   {settings} (hooks.{key})");
            continue;
        }
        let _ = writeln!(
            out,
            "RESTORED {settings} (hooks.{key}: {} entr{})",
            missing.len(),
            plural(missing.len())
        );
        let merged: Vec<Value> = missing.iter().chain(current.iter()).cloned().collect();
        hooks.insert(key.clone(), Value::Array(merged));
        changed = true;
    }
    changed |= prune_dead(ctx, settings, &mut hooks, out);
    changed |= normalize_cbm(ctx, settings, cbm, &mut hooks, out);
    if store {
        new.insert("hooks".into(), Value::Object(hooks));
    }
    if changed {
        write(settings, &new)?;
    }
    Ok(())
}

fn nonempty_servers(root: &Obj) -> Option<&Obj> {
    root.get("mcpServers")?
        .as_object()
        .filter(|m| !m.is_empty())
}

fn servers_mut(root: &mut Obj) -> &mut Obj {
    if !root.get("mcpServers").is_some_and(Value::is_object) {
        root.insert("mcpServers".into(), Value::Object(Obj::new()));
    }
    root["mcpServers"].as_object_mut().unwrap()
}

fn restore_mcp_servers(out: &mut String, claude_json: &str, snap: &str) -> Result<(), Fail> {
    let Some(old) = strict(snap)? else {
        return Ok(());
    };
    let Some(mut new) = strict(claude_json)? else {
        return whole_file(out, claude_json, old);
    };
    let Some(old_servers) = nonempty_servers(&old) else {
        return Ok(());
    };
    let servers = servers_mut(&mut new);
    let mut restored = 0;
    for (k, v) in old_servers {
        if servers.contains_key(k) {
            continue;
        }
        servers.insert(k.clone(), v.clone());
        restored += 1;
        let _ = writeln!(out, "RESTORED {claude_json} (mcpServers.{k})");
    }
    if restored == 0 {
        let _ = writeln!(out, "INTACT   {claude_json} (mcpServers)");
        return Ok(());
    }
    write(claude_json, &new)
}

pub fn restore(
    ctx: &Ctx,
    settings: &str,
    snap_settings: &str,
    claude_json: &str,
    snap_claude_json: &str,
    cbm: &str,
) -> Out {
    run(|out| {
        restore_settings(ctx, out, settings, snap_settings, cbm)?;
        restore_mcp_servers(out, claude_json, snap_claude_json)?;
        Ok(0)
    })
}

fn stale(ctx: &Ctx, entry: &Value) -> bool {
    entry.is_object()
        && command_str(entry).is_some_and(|s| s.contains('/') && !path_exists(&expanduser(ctx, s)))
}

pub fn adopt_mcp(ctx: &Ctx, staged_path: &str, claude_json: &str) -> Out {
    run(|out| {
        let staged = load_lax(staged_path);
        let Some(staged_servers) = nonempty_servers(&staged) else {
            return Ok(0);
        };
        let mut target = load_lax(claude_json);
        let servers = servers_mut(&mut target);
        let mut adopted = 0;
        for (k, v) in staged_servers {
            if servers.get(k).is_some_and(|e| !stale(ctx, e)) {
                continue;
            }
            servers.insert(k.clone(), v.clone());
            adopted += 1;
            let _ = writeln!(
                out,
                "ADOPTED  {claude_json} (mcpServers.{k} from {staged_path})"
            );
        }
        if adopted > 0 {
            write(claude_json, &target)?;
        }
        Ok(0)
    })
}

pub fn wired(settings: &str, claude_json: &str, cbm: &str) -> Out {
    let hooks = canon(load_lax(settings).get("hooks"));
    let mcp = canon(load_lax(claude_json).get("mcpServers"));
    let in_hooks = hooks.contains(cbm) || hooks.contains("cbm-");
    let in_mcp = mcp.contains(cbm);
    let word = |b| if b { "present" } else { "absent" };
    let line = format!(
        "CBM      hooks: {}, user-scope MCP entry: {}\n",
        word(in_hooks),
        word(in_mcp)
    );
    (if in_hooks && in_mcp { 0 } else { 4 }, line, String::new())
}

pub fn dead_hooks(ctx: &Ctx, path: &str) -> Out {
    run(|out| {
        let mut root = load_lax(path);
        let Some(Value::Object(hooks)) = root.get_mut("hooks") else {
            return Ok(0);
        };
        let mut dead = 0;
        for (key, entries) in hook_lists(hooks) {
            for entry in entries.iter() {
                for h in entry
                    .get("hooks")
                    .and_then(Value::as_array)
                    .into_iter()
                    .flatten()
                {
                    let Some(s) = command_str(h).filter(|s| !blank(s)) else {
                        continue;
                    };
                    let ok = if h.get("args").is_some() {
                        on_path_executable(ctx, s)
                    } else {
                        shellwords::split(s)
                            .filter(|w| !w.is_empty())
                            .is_none_or(|w| on_path_executable(ctx, &w[0]))
                    };
                    if !ok {
                        let _ = writeln!(
                            out,
                            "DEAD     {path} (hooks.{key}: '{s}' not on PATH or not executable)"
                        );
                        dead += 1;
                    }
                }
            }
        }
        Ok(if dead > 0 { 5 } else { 0 })
    })
}

fn invalid<T>(prefix: &str, path: &str) -> Result<T, Fail> {
    fail(
        1,
        format!("{prefix}: {path} is not valid JSON -- fix it first, nothing written\n"),
    )
}

fn root_of(prefix: &str, path: &str) -> Result<Option<Obj>, Fail> {
    match parse_file(path) {
        Parsed::Absent => Ok(None),
        Parsed::Ok(Value::Object(m)) => Ok(Some(m)),
        _ => invalid(prefix, path),
    }
}

pub fn ensure_mcp(path: &str, name: &str, command: &str) -> Out {
    run(|out| {
        let mut root = root_of("radin-cbm-hooks", path)?.unwrap_or_default();
        if root.get("mcpServers").is_some_and(|s| !s.is_object()) {
            return invalid("radin-cbm-hooks", path);
        }
        let servers = servers_mut(&mut root);
        if servers.contains_key(name) {
            let _ = writeln!(out, "PRESENT  {path} (mcpServers.{name})");
            return Ok(0);
        }
        let entry: Value = serde_json::json!({"type": "stdio", "command": command, "args": []});
        servers.insert(name.into(), entry);
        write(path, &root)?;
        let _ = writeln!(out, "ADDED    {path} (mcpServers.{name})");
        Ok(0)
    })
}

pub fn ensure_env(path: &str, key: &str, value: &str) -> Out {
    run(|out| {
        let Some(mut root) = root_of("radin-cbm-json", path)? else {
            return Ok(0);
        };
        if root.get("env").is_some_and(|e| !e.is_object()) {
            return invalid("radin-cbm-json", path);
        }
        let env = root
            .entry("env")
            .or_insert_with(|| Value::Object(Obj::new()));
        let env = env.as_object_mut().unwrap();
        if env.contains_key(key) {
            let _ = writeln!(out, "PRESENT  {path} (env.{key})");
            return Ok(0);
        }
        env.insert(key.into(), Value::String(value.into()));
        write(path, &root)?;
        let _ = writeln!(out, "ADDED    {path} (env.{key})");
        Ok(0)
    })
}

fn atoi(v: &Value) -> Option<i64> {
    let t = match v {
        Value::Number(n) => n.to_string(),
        Value::Bool(_) | Value::Null => return Some(0),
        _ => return None,
    };
    let digits: String = t
        .trim_start_matches('+')
        .chars()
        .enumerate()
        .take_while(|(i, c)| c.is_ascii_digit() || (*i == 0 && *c == '-'))
        .map(|(_, c)| c)
        .collect();
    Some(digits.parse().unwrap_or(0))
}

pub fn ensure_hook_timeout(path: &str, name: &str, secs: i64) -> Out {
    run(|out| {
        let Some(mut root) = root_of("radin-cbm-json", path)? else {
            return Ok(0);
        };
        let Some(Value::Object(hooks)) = root.get_mut("hooks") else {
            return Ok(0);
        };
        let mut changed = false;
        for (_, entries) in hook_lists(hooks) {
            for entry in entries.iter_mut() {
                let hs = entry.get_mut("hooks").and_then(Value::as_array_mut);
                for h in hs
                    .into_iter()
                    .flatten()
                    .filter(|h| h.is_object() && is_cbm_entry(h, name))
                {
                    if h.get("timeout").and_then(atoi).is_some_and(|t| t < secs) {
                        h["timeout"] = Value::from(secs);
                        changed = true;
                    }
                }
            }
        }
        if changed {
            write(path, &root)?;
            let _ = writeln!(out, "RAISED   {path} (hook timeout {secs} s)");
        }
        Ok(0)
    })
}

fn resolve(arg: &str) -> String {
    fs::canonicalize(arg).map_or_else(|_| arg.to_string(), |p| p.to_string_lossy().into_owned())
}

pub fn edit_allow(arg: &str, add: bool, rules: &[&str]) -> Out {
    run(|out| {
        let path = &resolve(arg);
        let bad = || invalid("radin-cbm-json", path);
        let mut root = match root_of("radin-cbm-json", path)? {
            Some(r) => r,
            None if add => Obj::new(),
            None => return Ok(0),
        };
        let allow_ok = root.get("permissions").is_none_or(|p| {
            p.as_object()
                .is_some_and(|p| p.get("allow").is_none_or(Value::is_array))
        });
        if !allow_ok {
            return bad();
        }
        let has_allow = root
            .get("permissions")
            .and_then(|p| p.get("allow"))
            .is_some();
        if !has_allow && !add {
            return Ok(0);
        }
        let perms = root
            .entry("permissions")
            .or_insert_with(|| Value::Object(Obj::new()));
        let allow = perms
            .as_object_mut()
            .unwrap()
            .entry("allow")
            .or_insert_with(|| Value::Array(vec![]));
        let allow = allow.as_array_mut().unwrap();
        let mut changed = false;
        for rule in rules {
            let at = allow.iter().rposition(|v| v.as_str() == Some(rule));
            match (add, at) {
                (true, None) => {
                    allow.push(Value::String(rule.to_string()));
                    let _ = writeln!(out, "ADDED    {path} (permissions.allow {rule})");
                    changed = true;
                }
                (false, Some(_)) => {
                    while let Some(i) = allow.iter().rposition(|v| v.as_str() == Some(rule)) {
                        allow.remove(i);
                        let _ = writeln!(out, "REMOVED  {path} (permissions.allow {rule})");
                    }
                    changed = true;
                }
                _ => {}
            }
        }
        if changed {
            write(path, &root)?;
        }
        Ok(0)
    })
}

pub fn edit_ext_dir(arg: &str, add: bool, globs: &[&str]) -> Out {
    run(|out| {
        let path = &resolve(arg);
        let mut root = match root_of("radin-cbm-json", path)? {
            Some(r) => r,
            None if add => Obj::new(),
            None => return Ok(0),
        };
        let perms = root.get("permission");
        let ext = perms.and_then(|p| p.get("external_directory"));
        if perms.is_some_and(|p| !p.is_object()) || ext.is_some_and(|e| !e.is_object()) {
            return fail(
                3,
                format!("radin-cbm-json: {path}: permission.external_directory is not an object -- nothing written\n"),
            );
        }
        if ext.is_none() && !add {
            return Ok(0);
        }
        let perms = root
            .entry("permission")
            .or_insert_with(|| Value::Object(Obj::new()));
        let ext = perms
            .as_object_mut()
            .unwrap()
            .entry("external_directory")
            .or_insert_with(|| Value::Object(Obj::new()));
        let ext = ext.as_object_mut().unwrap();
        let mut changed = false;
        for g in globs {
            if add {
                if ext.get(*g).and_then(Value::as_str) == Some("allow") {
                    continue;
                }
                ext.insert(g.to_string(), Value::String("allow".into()));
                let _ = writeln!(out, "ADDED    {path} (permission.external_directory {g})");
            } else if ext.shift_remove(*g).is_some() {
                let _ = writeln!(out, "REMOVED  {path} (permission.external_directory {g})");
            } else {
                continue;
            }
            changed = true;
        }
        if changed {
            write(path, &root)?;
        }
        Ok(0)
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    struct T {
        d: tempfile::TempDir,
    }

    impl T {
        fn new() -> T {
            T {
                d: tempfile::tempdir().unwrap(),
            }
        }
        fn p(&self, n: &str) -> String {
            self.d.path().join(n).to_string_lossy().into_owned()
        }
        fn put(&self, n: &str, body: &str) -> String {
            let p = self.p(n);
            fs::write(&p, body).unwrap();
            p
        }
        fn get(&self, n: &str) -> String {
            fs::read_to_string(self.p(n)).unwrap()
        }
        fn exe(&self, n: &str) -> String {
            let p = self.put(n, "");
            fs::set_permissions(&p, fs::Permissions::from_mode(0o755)).unwrap();
            p
        }
        fn ctx(&self) -> Ctx {
            Ctx {
                home: Some(self.d.path().to_string_lossy().into_owned()),
                path: Some(self.p("bin")),
            }
        }
    }

    fn cmds(body: &str) -> Vec<String> {
        let v: Value = serde_json::from_str(body).unwrap();
        let mut out = vec![];
        for entries in v["hooks"].as_object().unwrap().values() {
            for e in entries.as_array().unwrap() {
                for h in e["hooks"].as_array().unwrap() {
                    out.push(h["command"].as_str().unwrap().to_string());
                }
            }
        }
        out
    }

    fn hook(cmd: &str) -> Value {
        json!({"matcher": "", "hooks": [{"type": "command", "command": cmd}]})
    }

    fn no_ctx() -> Ctx {
        Ctx {
            home: None,
            path: None,
        }
    }

    #[test]
    fn ensure_allow_adds_once_keeps_foreign_rules_and_follows_a_symlink() {
        let t = T::new();
        let real = t.put(
            "real.json",
            r#"{"model": "opus", "permissions": {"allow": ["Bash(ls)"]}}"#,
        );
        let link = t.p("settings.json");
        std::os::unix::fs::symlink(&real, &link).unwrap();
        let r = format!("Read(//{}/.radin/**)", "h");
        let (code, out, err) = edit_allow(&link, true, &[&r, "Bash(ls)"]);
        let real_path = fs::canonicalize(&real)
            .unwrap()
            .to_string_lossy()
            .into_owned();
        assert_eq!((code, err.as_str()), (0, ""));
        assert_eq!(
            out,
            format!("ADDED    {real_path} (permissions.allow {r})\n")
        );
        assert!(fs::symlink_metadata(&link)
            .unwrap()
            .file_type()
            .is_symlink());
        let v: Value = serde_json::from_str(&fs::read_to_string(&real).unwrap()).unwrap();
        assert_eq!(v["permissions"]["allow"], json!(["Bash(ls)", r]));
        let before = fs::read_to_string(&real).unwrap();
        assert_eq!(
            edit_allow(&link, true, &[&r]),
            (0, String::new(), String::new())
        );
        assert_eq!(fs::read_to_string(&real).unwrap(), before);
        assert!(before.starts_with("{\n  \"model\": \"opus\","));
    }

    #[test]
    fn ensure_allow_creates_a_missing_file() {
        let t = T::new();
        let p = t.p("s.json");
        let (code, out, _) = edit_allow(&p, true, &["a"]);
        assert_eq!(code, 0);
        assert_eq!(out, format!("ADDED    {p} (permissions.allow a)\n"));
        assert_eq!(
            t.get("s.json"),
            "{\n  \"permissions\": {\n    \"allow\": [\n      \"a\"\n    ]\n  }\n}\n"
        );
    }

    #[test]
    fn remove_allow_drops_every_copy_and_only_the_named_rule() {
        let t = T::new();
        let p = t.put(
            "s.json",
            r#"{"permissions": {"allow": ["a", "keep", "a"]}}"#,
        );
        let p = fs::canonicalize(p).unwrap().to_string_lossy().into_owned();
        let (code, out, _) = edit_allow(&p, false, &["a", "missing"]);
        assert_eq!(code, 0);
        assert_eq!(
            out,
            format!("REMOVED  {p} (permissions.allow a)\nREMOVED  {p} (permissions.allow a)\n")
        );
        let v: Value = serde_json::from_str(&fs::read_to_string(&p).unwrap()).unwrap();
        assert_eq!(v["permissions"]["allow"], json!(["keep"]));
    }

    #[test]
    fn remove_allow_leaves_missing_and_invalid_files_alone() {
        let t = T::new();
        assert_eq!(
            edit_allow(&t.p("none.json"), false, &["a"]),
            (0, String::new(), String::new())
        );
        assert!(!Path::new(&t.p("none.json")).exists());
        let p = t.put("bad.json", "not json");
        let (code, out, err) = edit_allow(&p, false, &["a"]);
        assert_eq!((code, out.as_str()), (1, ""));
        assert!(
            err.ends_with("is not valid JSON -- fix it first, nothing written\n"),
            "{err}"
        );
        assert_eq!(t.get("bad.json"), "not json");
    }

    #[test]
    fn allow_refuses_wrong_typed_containers_and_non_object_roots() {
        let t = T::new();
        for body in [
            r#"{"permissions": []}"#,
            r#"{"permissions": {"allow": "x"}}"#,
            "[]",
        ] {
            let p = t.put("s.json", body);
            assert_eq!(edit_allow(&p, true, &["a"]).0, 1, "{body}");
            assert_eq!(t.get("s.json"), body);
        }
    }

    #[test]
    fn ext_dir_adds_once_removes_and_keeps_foreign_keys() {
        let t = T::new();
        let p = t.put(
            "o.json",
            r#"{"theme": "x", "permission": {"external_directory": {"/keep": "deny"}}}"#,
        );
        let (code, out, _) = edit_ext_dir(&p, true, &["/a", "/keep"]);
        assert_eq!(code, 0);
        let p = fs::canonicalize(&p).unwrap().to_string_lossy().into_owned();
        assert_eq!(out, format!("ADDED    {p} (permission.external_directory /a)\nADDED    {p} (permission.external_directory /keep)\n"));
        let v: Value = serde_json::from_str(&fs::read_to_string(&p).unwrap()).unwrap();
        assert_eq!(
            v["permission"]["external_directory"],
            json!({"/keep": "allow", "/a": "allow"})
        );
        assert_eq!(edit_ext_dir(&p, true, &["/a"]).1, "");
        let (_, out, _) = edit_ext_dir(&p, false, &["/a", "/nope"]);
        assert_eq!(
            out,
            format!("REMOVED  {p} (permission.external_directory /a)\n")
        );
        let v: Value = serde_json::from_str(&fs::read_to_string(&p).unwrap()).unwrap();
        assert_eq!(
            v["permission"]["external_directory"],
            json!({"/keep": "allow"})
        );
    }

    #[test]
    fn ext_dir_creates_a_missing_file_and_symlink_survives() {
        let t = T::new();
        let p = t.p("o.json");
        assert_eq!(edit_ext_dir(&p, true, &["/a"]).0, 0);
        assert!(t.get("o.json").contains("\"external_directory\""));
        let link = t.p("link.json");
        std::os::unix::fs::symlink(&p, &link).unwrap();
        edit_ext_dir(&link, true, &["/b"]);
        assert!(fs::symlink_metadata(&link)
            .unwrap()
            .file_type()
            .is_symlink());
        assert!(t.get("o.json").contains("/b"));
    }

    #[test]
    fn ext_dir_exits_1_on_invalid_json_and_3_on_a_string_value() {
        let t = T::new();
        let p = t.put("o.json", "{ // jsonc\n}");
        assert_eq!(edit_ext_dir(&p, true, &["/a"]).0, 1);
        assert_eq!(t.get("o.json"), "{ // jsonc\n}");
        let body = r#"{"permission": {"external_directory": "allow"}}"#;
        let p = t.put("s.json", body);
        let (code, out, err) = edit_ext_dir(&p, true, &["/a"]);
        assert_eq!((code, out.as_str()), (3, ""));
        assert!(
            err.contains("permission.external_directory is not an object"),
            "{err}"
        );
        assert_eq!(t.get("s.json"), body);
        assert_eq!(edit_ext_dir(&t.p("none.json"), false, &["/a"]).0, 0);
    }

    #[test]
    fn ensure_mcp_adds_then_reports_present_and_keeps_key_order() {
        let t = T::new();
        let p = t.put(
            ".mcp.json",
            r#"{"z": 1, "mcpServers": {"other": {"command": "x"}}}"#,
        );
        let (code, out, _) = ensure_mcp(&p, "cbm", "/bin/c m");
        assert_eq!(
            (code, out.as_str()),
            (0, format!("ADDED    {p} (mcpServers.cbm)\n").as_str())
        );
        let v: Value = serde_json::from_str(&t.get(".mcp.json")).unwrap();
        assert_eq!(
            v["mcpServers"]["cbm"],
            json!({"type": "stdio", "command": "/bin/c m", "args": []})
        );
        assert!(t.get(".mcp.json").starts_with("{\n  \"z\": 1,"));
        let before = t.get(".mcp.json");
        assert_eq!(
            ensure_mcp(&p, "cbm", "other").1,
            format!("PRESENT  {p} (mcpServers.cbm)\n")
        );
        assert_eq!(t.get(".mcp.json"), before);
        let fresh = t.p("new.json");
        assert_eq!(ensure_mcp(&fresh, "cbm", "c").0, 0);
        assert!(Path::new(&fresh).exists());
    }

    #[test]
    fn ensure_mcp_refuses_bad_files_with_the_hooks_prefix() {
        let t = T::new();
        for body in ["nope", "[]", r#"{"mcpServers": []}"#] {
            let p = t.put("m.json", body);
            let (code, out, err) = ensure_mcp(&p, "cbm", "c");
            assert_eq!((code, out.as_str()), (1, ""), "{body}");
            assert_eq!(
                err,
                format!(
                    "radin-cbm-hooks: {p} is not valid JSON -- fix it first, nothing written\n"
                )
            );
            assert_eq!(t.get("m.json"), body);
        }
    }

    #[test]
    fn ensure_env_adds_a_default_never_overrides_and_skips_a_missing_file() {
        let t = T::new();
        assert_eq!(
            ensure_env(&t.p("none.json"), "K", "v"),
            (0, String::new(), String::new())
        );
        assert!(!Path::new(&t.p("none.json")).exists());
        let p = t.put("s.json", r#"{"env": {"A": "1"}}"#);
        assert_eq!(
            ensure_env(&p, "K", "8000").1,
            format!("ADDED    {p} (env.K)\n")
        );
        assert_eq!(
            ensure_env(&p, "K", "1").1,
            format!("PRESENT  {p} (env.K)\n")
        );
        let v: Value = serde_json::from_str(&t.get("s.json")).unwrap();
        assert_eq!(v["env"], json!({"A": "1", "K": "8000"}));
        let p = t.put("bad.json", r#"{"env": []}"#);
        assert_eq!(ensure_env(&p, "K", "v").0, 1);
    }

    #[test]
    fn hook_timeout_is_raised_never_lowered_and_only_for_cbm() {
        let t = T::new();
        let body = r#"{"hooks": {"S": [{"hooks": [{"command": "cbm-a", "timeout": 5}, {"command": "other", "timeout": 5}, {"command": "cbm-b", "timeout": 20}, {"command": "cbm-c"}]}]}}"#;
        let p = t.put("s.json", body);
        let (code, out, _) = ensure_hook_timeout(&p, "codebase-memory-mcp", 10);
        assert_eq!(
            (code, out.as_str()),
            (0, format!("RAISED   {p} (hook timeout 10 s)\n").as_str())
        );
        let v: Value = serde_json::from_str(&t.get("s.json")).unwrap();
        let hs = &v["hooks"]["S"][0]["hooks"];
        assert_eq!(hs[0]["timeout"], 10);
        assert_eq!(hs[1]["timeout"], 5);
        assert_eq!(hs[2]["timeout"], 20);
        assert!(hs[3].get("timeout").is_none());
        assert_eq!(ensure_hook_timeout(&p, "codebase-memory-mcp", 10).1, "");
        assert_eq!(ensure_hook_timeout(&t.p("none"), "x", 10).0, 0);
        assert_eq!(ensure_hook_timeout(&t.put("bad", "{"), "x", 10).0, 1);
    }

    #[test]
    fn dead_hooks_flags_unrunnable_commands_with_exit_5() {
        let t = T::new();
        fs::create_dir(t.p("bin")).unwrap();
        let live = t.exe("bin/live-shim");
        let body = json!({"hooks": {"S": [
        {"hooks": [
            {"command": "live-shim --x"},
            {"command": "ghost-shim"},
            {"command": live.clone()},
            {"command": "/gone/hook"},
            {"command": "/gone/with space", "args": ["a"]},
            {"command": "   "},
            {"command": "'unterminated"},
        ]}]}});
        let p = t.put("s.json", &body.to_string());
        let (code, out, _) = dead_hooks(&t.ctx(), &p);
        assert_eq!(code, 5);
        assert_eq!(
            out,
            format!(
                "DEAD     {p} (hooks.S: 'ghost-shim' not on PATH or not executable)\nDEAD     {p} (hooks.S: '/gone/hook' not on PATH or not executable)\nDEAD     {p} (hooks.S: '/gone/with space' not on PATH or not executable)\n"
            )
        );
        assert_eq!(
            dead_hooks(&t.ctx(), &t.p("none")),
            (0, String::new(), String::new())
        );
        assert_eq!(dead_hooks(&no_ctx(), &p).0, 5);
    }

    #[test]
    fn wired_needs_cbm_in_hooks_and_in_the_mcp_entry() {
        let t = T::new();
        let s = t.put(
            "s.json",
            r#"{"hooks": {"S": [{"hooks": [{"command": "cbm-session"}]}]}}"#,
        );
        let c = t.put("c.json", r#"{"mcpServers": {"codebase-memory-mcp": {}}}"#);
        assert_eq!(
            wired(&s, &c, "codebase-memory-mcp"),
            (
                0,
                "CBM      hooks: present, user-scope MCP entry: present\n".into(),
                String::new()
            )
        );
        let (code, out, _) = wired(&s, &t.p("none"), "codebase-memory-mcp");
        assert_eq!(
            (code, out.as_str()),
            (4, "CBM      hooks: present, user-scope MCP entry: absent\n")
        );
        assert_eq!(
            wired(&t.p("none"), &c, "codebase-memory-mcp").1,
            "CBM      hooks: absent, user-scope MCP entry: present\n"
        );
    }

    #[test]
    fn adopt_mcp_moves_the_staged_entry_and_replaces_only_a_stale_one() {
        let t = T::new();
        let live = t.exe("live");
        let staged = t.put(
            "staged.json",
            &json!({"mcpServers": {"cbm": {"command": "/new/cbm"}, "other": {"command": "/o"}}})
                .to_string(),
        );
        let target = t.put("c.json", &json!({"keep": 1, "mcpServers": {"cbm": {"command": "/gone/cbm"}, "other": {"command": live}}}).to_string());
        let (code, out, _) = adopt_mcp(&t.ctx(), &staged, &target);
        assert_eq!(code, 0);
        assert_eq!(
            out,
            format!("ADOPTED  {target} (mcpServers.cbm from {staged})\n")
        );
        let v: Value = serde_json::from_str(&t.get("c.json")).unwrap();
        assert_eq!(v["mcpServers"]["cbm"]["command"], "/new/cbm");
        assert_eq!(v["mcpServers"]["other"]["command"], json!(live));
        assert_eq!(v["keep"], 1);
        assert_eq!(adopt_mcp(&t.ctx(), &t.p("none"), &target).1, "");
        let fresh = t.p("fresh.json");
        assert_eq!(adopt_mcp(&t.ctx(), &staged, &fresh).0, 0);
        assert!(t.get("fresh.json").contains("/new/cbm"));
    }

    fn restore_fixture(t: &T, snap: Value, now: Option<Value>) -> (String, String) {
        t.put("snap-s.json", &snap.to_string());
        let live = t.p("settings.json");
        if let Some(n) = now {
            fs::write(&live, n.to_string()).unwrap();
        }
        (live, t.p("claude.json"))
    }

    #[test]
    fn restore_puts_back_what_upstream_replaced_and_is_idempotent() {
        let t = T::new();
        let snap = json!({"model": "opus", "hooks": {"SessionStart": [hook("caveman-session"), {"matcher": "compact", "hooks": [{"command": "ponytail-session"}]}]}});
        let now = json!({"hooks": {"SessionStart": [hook("cbm-session-reminder")]}});
        let (live, cj) = restore_fixture(&t, snap, Some(now));
        let (code, out, err) = restore(
            &t.ctx(),
            &live,
            &t.p("snap-s.json"),
            &cj,
            &t.p("snap-c.json"),
            "codebase-memory-mcp",
        );
        assert_eq!((code, err.as_str()), (0, ""));
        assert_eq!(
            out,
            format!("RESTORED {live} (model)\nRESTORED {live} (hooks.SessionStart: 2 entries)\n")
        );
        let body = t.get("settings.json");
        assert_eq!(
            cmds(&body),
            [
                "caveman-session",
                "ponytail-session",
                "cbm-session-reminder"
            ]
        );
        let (_, out, _) = restore(
            &t.ctx(),
            &live,
            &t.p("snap-s.json"),
            &cj,
            &t.p("snap-c.json"),
            "codebase-memory-mcp",
        );
        assert_eq!(out, format!("INTACT   {live} (hooks.SessionStart)\n"));
        assert_eq!(t.get("settings.json"), body);
    }

    #[test]
    fn restore_skips_upstreams_own_entries_and_prunes_dead_paths() {
        let t = T::new();
        let live_hook = t.exe("live-hook");
        let snap = json!({"hooks": {"PreToolUse": [
            hook("'/gone/.config/.claude/hooks/cbm-code-discovery-gate'"),
            hook("/gone/other-tool-hook"),
            hook(&live_hook),
            hook("bare-shim-not-on-path"),
            hook("sh /Users/someone-else/.claude/hooks/x"),
        ]}});
        let (live, cj) = restore_fixture(&t, snap.clone(), Some(snap));
        let (code, out, _) = restore(
            &t.ctx(),
            &live,
            &t.p("snap-s.json"),
            &cj,
            &t.p("snap-c.json"),
            "codebase-memory-mcp",
        );
        assert_eq!(code, 0);
        assert!(out.contains("INTACT"), "{out}");
        for gone in ["cbm-code-discovery-gate", "other-tool-hook", "someone-else"] {
            assert!(
                out.contains(&format!("PRUNED   {live} (hooks.PreToolUse: '"))
                    && out.contains(gone),
                "{gone}: {out}"
            );
        }
        assert_eq!(
            cmds(&t.get("settings.json")),
            [live_hook.as_str(), "bare-shim-not-on-path"]
        );
    }

    #[test]
    fn restore_rewrites_cbm_commands_to_absolute_and_leaves_others() {
        let t = T::new();
        let home = t.d.path().to_string_lossy().into_owned();
        t.exe("cbm-session-reminder");
        t.exe("other-tool");
        let quoted = hook(&format!("'{home}/cbm-session-reminder'"));
        let tilde = hook("~/cbm-session-reminder --x");
        let other = hook("~/other-tool");
        let snap = json!({"hooks": {"S": []}});
        let (live, cj) = restore_fixture(
            &t,
            snap,
            Some(json!({"hooks": {"S": [quoted, tilde, other.clone()]}})),
        );
        let (_, out, _) = restore(
            &t.ctx(),
            &live,
            &t.p("snap-s.json"),
            &cj,
            &t.p("snap-c.json"),
            "codebase-memory-mcp",
        );
        assert!(
            out.contains(&format!(
                "ABSOLUTE {live} (hooks.S: '{home}/cbm-session-reminder')"
            )),
            "{out}"
        );
        assert!(
            out.contains(&format!(
                "ABSOLUTE {live} (hooks.S: '{home}/cbm-session-reminder --x')"
            )),
            "{out}"
        );
        assert_eq!(
            cmds(&t.get("settings.json")),
            [
                format!("{home}/cbm-session-reminder"),
                format!("{home}/cbm-session-reminder --x"),
                "~/other-tool".into()
            ]
        );
    }

    #[test]
    fn restore_brings_back_a_removed_file_and_mcp_servers() {
        let t = T::new();
        let snap = json!({"model": "opus"});
        let (live, cj) = restore_fixture(&t, snap, None);
        t.put(
            "snap-c.json",
            &json!({"mcpServers": {"other": {"command": "x"}}}).to_string(),
        );
        t.put(
            "claude.json",
            &json!({"mcpServers": {"codebase-memory-mcp": {"command": "c"}}}).to_string(),
        );
        let (code, out, _) = restore(
            &t.ctx(),
            &live,
            &t.p("snap-s.json"),
            &cj,
            &t.p("snap-c.json"),
            "codebase-memory-mcp",
        );
        assert_eq!(code, 0);
        assert_eq!(
            out,
            format!("RESTORED {live} (whole file -- upstream's write removed it)\nRESTORED {cj} (mcpServers.other)\n")
        );
        let v: Value = serde_json::from_str(&t.get("claude.json")).unwrap();
        assert_eq!(
            v["mcpServers"]
                .as_object()
                .unwrap()
                .keys()
                .collect::<Vec<_>>(),
            ["codebase-memory-mcp", "other"]
        );
        let (_, out, _) = restore(
            &t.ctx(),
            &live,
            &t.p("snap-s.json"),
            &cj,
            &t.p("snap-c.json"),
            "codebase-memory-mcp",
        );
        assert_eq!(out, format!("INTACT   {cj} (mcpServers)\n"));
    }

    #[test]
    fn restore_refuses_invalid_json_and_keeps_the_first_output() {
        let t = T::new();
        let (live, cj) = restore_fixture(&t, json!({"model": "opus"}), Some(json!({})));
        t.put("settings.json", "not json");
        let (code, out, err) = restore(
            &t.ctx(),
            &live,
            &t.p("snap-s.json"),
            &cj,
            &t.p("snap-c.json"),
            "c",
        );
        assert_eq!((code, out.as_str()), (1, ""));
        assert_eq!(err, format!("radin-cbm-config: {live} is not valid JSON -- nothing restored, your snapshot is still on disk\n"));
        assert_eq!(t.get("settings.json"), "not json");
        t.put("settings.json", "{}");
        t.put("claude.json", "[]");
        t.put("snap-c.json", r#"{"mcpServers": {"a": {}}}"#);
        let (code, out, err) = restore(
            &t.ctx(),
            &live,
            &t.p("snap-s.json"),
            &cj,
            &t.p("snap-c.json"),
            "c",
        );
        assert_eq!(code, 1);
        assert_eq!(out, format!("RESTORED {live} (model)\n"));
        assert!(err.contains(&cj), "{err}");
    }

    #[test]
    fn numbers_and_key_order_survive_a_write() {
        let t = T::new();
        let p = t.put(
            "s.json",
            r#"{"b": 1.50, "a": 12345678901234567890123, "env": {}}"#,
        );
        ensure_env(&p, "K", "v");
        let body = t.get("s.json");
        assert!(body.contains("\"b\": 1.50"), "{body}");
        assert!(body.contains("12345678901234567890123"), "{body}");
        assert!(body.find("\"b\"").unwrap() < body.find("\"a\"").unwrap());
    }

    #[test]
    fn canon_sorts_keys_recursively() {
        let v = json!({"b": {"y": 1, "x": [2, {"d": 1, "c": 2}]}, "a": null});
        assert_eq!(
            canon(Some(&v)),
            r#"{"a": null,"b": {"x": [2,{"c": 2,"d": 1}],"y": 1}}"#
        );
        assert_eq!(canon(None), "{}");
    }

    #[test]
    fn expanduser_expands_only_a_leading_tilde_slash() {
        let c = Ctx {
            home: Some("/h".into()),
            path: None,
        };
        assert_eq!(expanduser(&c, "~"), "/h");
        assert_eq!(expanduser(&c, "~/x"), "/h/x");
        assert_eq!(expanduser(&c, "~bob/x"), "~bob/x");
        assert_eq!(expanduser(&c, "a/~"), "a/~");
        assert_eq!(expanduser(&no_ctx(), "~/x"), "~/x");
    }

    #[test]
    fn parse_file_tells_absent_from_invalid() {
        let t = T::new();
        assert!(matches!(parse_file(""), Parsed::Absent));
        assert!(matches!(parse_file(&t.p("none")), Parsed::Absent));
        assert!(matches!(parse_file(&t.put("bad", "{")), Parsed::Invalid));
        assert!(matches!(parse_file(&t.put("ok", "[1]")), Parsed::Ok(_)));
        assert_eq!(load_lax(&t.p("bad")), Obj::new());
    }
}

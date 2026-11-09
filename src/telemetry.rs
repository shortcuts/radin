use crate::paths::git;
use crate::{Ctx, Out};
use std::fs::{self, OpenOptions};
use std::io::Write;

const USAGE: &str = "usage: radin telemetry record <scope> <kind> [key=value ...]\n       radin telemetry report-error <scope> <where> <message> [key=value ...]\n";

fn usage(msg: &str) -> Out {
    (2, String::new(), format!("radin telemetry: {msg}\n{USAGE}"))
}

fn valid_name(s: &str) -> bool {
    let b = s.as_bytes();
    b.first().is_some_and(u8::is_ascii_lowercase)
        && b.iter()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || *c == b'-')
}

fn escape(s: &str) -> String {
    s.replace('\\', "\\\\").replace('"', "\\\"")
}

pub(crate) fn now_utc() -> String {
    let secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_secs() as i64);
    let (days, rem) = (secs.div_euclid(86400), secs.rem_euclid(86400));
    let z = days + 719468;
    let era = z.div_euclid(146097);
    let doe = z.rem_euclid(146097);
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
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

fn evidence(pairs: &[String]) -> Result<String, Out> {
    let mut out = Vec::new();
    for p in pairs {
        let Some((key, val)) = p.split_once('=') else {
            return Err(usage(&format!("not a key=value pair: {p}")));
        };
        if key.is_empty()
            || !key
                .bytes()
                .all(|c| c.is_ascii_alphanumeric() || b"_.-".contains(&c))
        {
            return Err(usage(&format!("invalid key: {key}")));
        }
        let val = escape(val).replace(['\n', '\r', '\t'], " ");
        out.push(format!("\"{key}\":\"{val}\""));
    }
    Ok(format!("{{{}}}", out.join(",")))
}

pub fn run(c: &Ctx, args: &[String]) -> Out {
    let (scope, kind, rest): (&str, &str, Vec<String>) = match args.first().map(String::as_str) {
        Some("record") if args.len() >= 3 => (&args[1], &args[2], args[3..].to_vec()),
        Some("record") => return usage("record needs <scope> <kind>"),
        Some("report-error") if args.len() >= 4 => {
            let mut v = vec![format!("where={}", args[2]), format!("message={}", args[3])];
            v.extend_from_slice(&args[4..]);
            (&args[1], "error", v)
        }
        Some("report-error") => return usage("report-error needs <scope> <where> <message>"),
        other => {
            return usage(&format!("unknown verb: {}", other.unwrap_or("(none)")));
        }
    };
    if !valid_name(scope) {
        return usage(&format!("invalid scope: {scope}"));
    }
    if !valid_name(kind) {
        return usage(&format!("invalid kind: {kind}"));
    }
    let ev = match evidence(&rest) {
        Ok(e) => e,
        Err(o) => return o,
    };
    let repo = git(&c.cwd, &["rev-parse", "--show-toplevel"])
        .map(|s| s.trim_end_matches('\n').to_string())
        .unwrap_or_else(|| c.cwd.to_string_lossy().into_owned());
    let line = format!(
        "{{\"ts\":\"{}\",\"repo\":\"{}\",\"scope\":\"{scope}\",\"kind\":\"{kind}\",\"evidence\":{ev}}}\n",
        now_utc(),
        escape(&repo)
    );
    let dir = c.home.join(".radin/telemetry");
    let file = dir.join(format!("{scope}.jsonl"));
    let wrote = fs::create_dir_all(&dir)
        .and_then(|()| OpenOptions::new().create(true).append(true).open(&file))
        .and_then(|mut f| f.write_all(line.as_bytes()));
    match wrote {
        Ok(()) => (0, String::new(), String::new()),
        Err(_) => (
            0,
            String::new(),
            format!(
                "radin telemetry: warning: could not write {}\n",
                file.display()
            ),
        ),
    }
}

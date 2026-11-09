pub mod cbm;
pub mod host;
pub mod jsonedit;
pub mod manifest;
pub mod paths;
pub mod prompt;
pub mod render;
pub mod scope;
pub mod shellwords;
pub mod stats;
pub mod telemetry;

pub use host::Host;
use std::path::{Path, PathBuf};

pub const SUBCOMMANDS: [&str; 12] = [
    "backlog",
    "state",
    "scope",
    "prompt",
    "stats",
    "telemetry",
    "update",
    "doctor",
    "uninstall",
    "hooks",
    "wire",
    "repair",
];

pub const USAGE: &str = "usage: radin [--host claude|agents] <backlog|state|scope|prompt|stats|telemetry|hooks|wire|repair|update|doctor|uninstall> [args]\n\
With no subcommand on a terminal, radin opens the TUI; \"radin help\" prints this text.\n\
Each subcommand prints its own usage when run with no arguments.\n";

pub type Out = (i32, String, String);

fn fail(code: i32, err: String) -> Out {
    (code, String::new(), err)
}

pub struct Ctx<'a> {
    pub cwd: PathBuf,
    pub home: PathBuf,
    pub host: Host,
    pub stdin: String,
    pub env: &'a dyn Fn(&str) -> Option<String>,
    /// Runs another radin subcommand in `dir` with `stdin`: the seam to backlog and state.
    pub cli: &'a dyn Fn(&Path, &[&str], &str) -> Out,
}

impl Ctx<'_> {
    /// Calls a nested subcommand on the same host, so a rendered text never mixes hosts.
    pub fn nested(&self, dir: &Path, args: &[&str]) -> Out {
        let mut a = vec!["--host", self.host.as_str()];
        a.extend_from_slice(args);
        (self.cli)(dir, &a, "")
    }
}

pub fn run(args: &[String], env: &dyn Fn(&str) -> Option<String>, is_tty: bool) -> Out {
    run_in(args, env, is_tty, Path::new("."), None)
}

/// Runs radin with an explicit working directory and stdin text, so nested calls never read process state.
pub fn run_in(
    args: &[String],
    env: &dyn Fn(&str) -> Option<String>,
    is_tty: bool,
    cwd: &Path,
    stdin: Option<&str>,
) -> Out {
    let mut flag: Option<String> = None;
    let mut rest = args;
    while let Some(first) = rest.first() {
        if let Some(v) = first.strip_prefix("--host=") {
            flag = Some(v.to_string());
            rest = &rest[1..];
        } else if first == "--host" {
            match rest.get(1) {
                Some(v) => flag = Some(v.clone()),
                None => return fail(2, USAGE.to_string()),
            }
            rest = &rest[2..];
        } else {
            break;
        }
    }
    let host = match Host::select(flag.as_deref(), env) {
        Ok(h) => h,
        Err(e) => return fail(2, e),
    };
    let nested = |dir: &Path, a: &[&str], input: &str| {
        let a: Vec<String> = a.iter().map(|s| s.to_string()).collect();
        run_in(&a, env, false, dir, Some(input))
    };
    let ctx = || Ctx {
        cwd: if cwd == Path::new(".") {
            std::env::current_dir().unwrap_or_default()
        } else {
            cwd.to_path_buf()
        },
        home: env("HOME").unwrap_or_default().into(),
        host,
        stdin: stdin.unwrap_or("").to_string(),
        env,
        cli: &nested,
    };
    match rest.first().map(String::as_str) {
        None if is_tty => fail(1, "radin: the TUI is not ported yet\n".into()),
        None => fail(1, USAGE.to_string()),
        Some("help") => (0, USAGE.to_string(), String::new()),
        Some("telemetry") => telemetry::run(&ctx(), &rest[1..]),
        Some("prompt") => prompt::run(&ctx(), &rest[1..]),
        Some("scope") => scope::run(&ctx(), &rest[1..]),
        Some("stats") => stats::run(&ctx(), &rest[1..]),
        Some("hooks") => cbm::run_hooks(&ctx(), &rest[1..]),
        Some("wire") => cbm::run_wire(&ctx()),
        Some("repair") => cbm::run_repair(&ctx()),
        Some(c) if SUBCOMMANDS.contains(&c) => fail(1, format!("radin: '{c}' is not ported yet\n")),
        Some(_) => fail(1, USAGE.to_string()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn go(args: &[&str], env: &[(&str, &str)]) -> Out {
        let a: Vec<String> = args.iter().map(|s| s.to_string()).collect();
        let e: Vec<(String, String)> = env
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect();
        run(
            &a,
            &|k| e.iter().find(|(n, _)| n == k).map(|(_, v)| v.clone()),
            false,
        )
    }

    fn unknown(h: &str) -> String {
        format!("radin: unknown host '{h}' (expected claude|agents)\n")
    }

    #[test]
    fn host_parse_accepts_two_names() {
        assert_eq!(Host::parse("claude"), Some(Host::Claude));
        assert_eq!(Host::parse("agents"), Some(Host::Agents));
        assert_eq!(Host::parse("codex"), None);
    }

    #[test]
    fn flag_beats_env_host() {
        assert_eq!(
            go(&["--host", "claude", "help"], &[("RADIN_HOST", "bogus")]).0,
            0
        );
        assert_eq!(
            go(&["--host=claude", "help"], &[("RADIN_HOST", "bogus")]).0,
            0
        );
    }

    #[test]
    fn env_host_beats_opencode() {
        assert_eq!(
            go(&["help"], &[("RADIN_HOST", "bogus"), ("OPENCODE", "1")]).2,
            unknown("bogus")
        );
    }

    #[test]
    fn opencode_selects_agents_then_default_claude() {
        assert_eq!(
            go(&["--host", "bogus", "help"], &[("OPENCODE", "1")]).2,
            unknown("bogus")
        );
        assert_eq!(go(&["help"], &[("OPENCODE", "1")]).0, 0);
        assert_eq!(go(&["help"], &[]).0, 0);
    }

    #[test]
    fn empty_flag_falls_through_to_env() {
        assert_eq!(
            go(&["--host", "", "help"], &[("RADIN_HOST", "bogus")]).2,
            unknown("bogus")
        );
    }

    #[test]
    fn host_flag_without_value_prints_usage_exit_2() {
        assert_eq!(go(&["--host"], &[]), (2, String::new(), USAGE.to_string()));
    }

    #[test]
    fn help_prints_usage_to_stdout() {
        assert_eq!(go(&["help"], &[]), (0, USAGE.to_string(), String::new()));
    }

    #[test]
    fn every_other_subcommand_is_not_ported() {
        for c in SUBCOMMANDS.iter().filter(|c| {
            ![
                "telemetry",
                "prompt",
                "scope",
                "stats",
                "hooks",
                "wire",
                "repair",
            ]
            .contains(c)
        }) {
            assert_eq!(
                go(&[c], &[]),
                (
                    1,
                    String::new(),
                    format!("radin: '{c}' is not ported yet\n")
                )
            );
        }
    }

    #[test]
    fn bare_radin_depends_on_terminal() {
        let none = |_: &str| None;
        assert_eq!(
            run(&[], &none, true),
            (
                1,
                String::new(),
                "radin: the TUI is not ported yet\n".into()
            )
        );
        assert_eq!(
            run(&[], &none, false),
            (1, String::new(), USAGE.to_string())
        );
    }

    #[test]
    fn unknown_word_prints_usage_exit_1() {
        assert_eq!(
            go(&["frobnicate"], &[]),
            (1, String::new(), USAGE.to_string())
        );
    }
}

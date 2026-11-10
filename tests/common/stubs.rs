#![allow(dead_code)]
//! One `/bin/sh` script stands in for every command the installer reaches for, so no test touches the network or a real device setup.
//!
//! The script logs `"$*"` to `$MOCK_LOG_DIR/<name>.log` and obeys:
//! `MOCK_FAIL` (names that exit 1), `MOCK_NPX` (`fail`), `MOCK_CBM` (`fail-install`, `fail-after-wiring`),
//! `MOCK_CLAUDE_LIST` (file that `claude plugin list` prints), `MOCK_CURL` (`pstack-fail`),
//! `claude` and `codex` `mcp get` (exits 1 until `mcp add` creates `$MOCK_BIN/.mcp-<name>`),
//! `MOCK_CURL_FAIL` (curl exits 1 when an argument contains it).
use std::fs;
use std::os::unix::fs::{symlink, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

const STUB: &str = r#"#!/bin/sh
me=${STUB_NAME:-${0##*/}}
printf '%s\n' "$*" >>"$MOCK_LOG_DIR/$me.log"
case " ${MOCK_FAIL:-} " in *" $me "*) exit 1 ;; esac
tool() { ln -sf "$MOCK_BIN/.stub" "$MOCK_BIN/$1"; }
case "$me" in
brew)
	[ "$1 $2" = "install rtk" ] && tool rtk
	[ "$1 $2" = "install dmtrKovalenko/fff/fff-mcp" ] && tool fff-mcp
	;;
mise) case "$*" in *rtk*) tool rtk ;; *fff*) tool fff-mcp ;; esac ;;
curl)
	pstack=""
	case "$*" in */pstack/skills/*) pstack=1 ;; esac
	[ -n "$pstack" ] && [ "${MOCK_CURL:-}" = pstack-fail ] && exit 1
	[ -n "${MOCK_CURL_FAIL:-}" ] && case "$*" in *"$MOCK_CURL_FAIL"*) exit 1 ;; esac
	out=""
	prev=""
	skill=""
	for a in "$@"; do
		[ "$prev" = -o ] && out="$a"
		case "$a" in */SKILL.md) skill=1 ;; esac
		prev="$a"
	done
	if [ -n "$out" ]; then
		if [ -n "$pstack$skill" ]; then printf -- '---\nname: stub\ndisable-model-invocation: true\n---\n' >"$out"; else echo mock >"$out"; fi
	fi
	;;
npx)
	[ "${MOCK_NPX:-}" = fail ] && exit 1
	case " $* " in *" add "*)
		d="$HOME/.claude/skills/thermo-nuclear-code-quality-review"
		mkdir -p "$d" && printf 'stub thermo-nuclear\n' >"$d/SKILL.md"
		;;
	esac
	;;
claude | codex)
	case " $* " in *" plugin list "*) [ -n "${MOCK_CLAUDE_LIST:-}" ] && cat "$MOCK_CLAUDE_LIST" ;; esac
	case "$1 $2" in
	"mcp get") [ -f "$MOCK_BIN/.mcp-$me" ] || exit 1 ;;
	"mcp add") touch "$MOCK_BIN/.mcp-$me" ;;
	"mcp remove") rm -f "$MOCK_BIN/.mcp-$me" ;;
	esac
	;;
codebase-memory-mcp)
	if [ "${MOCK_CBM:-}" = fail-after-wiring ]; then
		case " $* " in *" install "*)
			mkdir -p "$HOME/.claude"
			printf '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"%s/codebase-memory-mcp hook"}]}]}}\n' "$MOCK_BIN" >"$HOME/.claude/settings.json"
			printf '{"mcpServers":{"codebase-memory-mcp":{"command":"%s/codebase-memory-mcp"}}}\n' "$MOCK_BIN" >"$HOME/.claude.json"
			exit 1
			;;
		esac
	fi
	if [ "${MOCK_CBM:-}" = fail-install ]; then
		case " $* " in *" install "*)
			printf 'Claude Code:\n  hooks: SessionStart (MCP usage reminder on startup)\nOpenCode:\n  mcp: /dev/null/opencode.json\n'
			exit 1
			;;
		esac
	fi
	;;
esac
exit 0
"#;

pub struct R {
    pub code: i32,
    pub out: String,
    pub err: String,
}

impl R {
    pub fn all(&self) -> String {
        format!("{}{}", self.out, self.err)
    }
}

/// An isolated HOME and a PATH holding only stubs plus `/usr/bin:/bin`.
pub struct Sandbox {
    _t: Option<tempfile::TempDir>,
    pub home: PathBuf,
    pub bin: PathBuf,
    pub work: PathBuf,
}

pub fn sha(p: &Path) -> String {
    use sha2::{Digest, Sha256};
    format!("{:x}", Sha256::digest(fs::read(p).unwrap()))
}

impl Sandbox {
    pub fn new() -> Sandbox {
        let t = tempfile::tempdir().unwrap();
        let root = t.path().canonicalize().unwrap();
        Sandbox::at(root, Some(t))
    }

    /// A sandbox that outlives the test: built once per test binary and shared read-only.
    pub fn shared(name: &str) -> Sandbox {
        let root =
            Path::new(env!("CARGO_TARGET_TMPDIR")).join(format!("{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&root).unwrap();
        Sandbox::at(root, None)
    }

    fn at(root: PathBuf, t: Option<tempfile::TempDir>) -> Sandbox {
        let (home, bin, work) = (root.join("home"), root.join("bin"), root.join("work"));
        for d in [&home, &bin, &work] {
            fs::create_dir_all(d).unwrap();
        }
        fs::write(bin.join(".stub"), STUB).unwrap();
        fs::set_permissions(bin.join(".stub"), fs::Permissions::from_mode(0o755)).unwrap();
        let s = Sandbox {
            _t: t,
            home,
            bin,
            work,
        };
        for n in ["brew", "curl", "claude", "npx"] {
            s.add(n);
        }
        s
    }

    pub fn add(&self, name: &str) {
        let _ = fs::remove_file(self.bin.join(name));
        symlink(self.bin.join(".stub"), self.bin.join(name)).unwrap();
    }

    pub fn remove(&self, name: &str) {
        let _ = fs::remove_file(self.bin.join(name));
    }

    pub fn p(&self, rel: &str) -> PathBuf {
        self.home.join(rel)
    }

    pub fn read(&self, rel: &str) -> String {
        fs::read_to_string(self.p(rel)).unwrap_or_else(|e| panic!("{rel}: {e}"))
    }

    pub fn put(&self, rel: &str, text: &str) {
        let p = self.p(rel);
        fs::create_dir_all(p.parent().unwrap()).unwrap();
        fs::write(p, text).unwrap();
    }

    pub fn log(&self, name: &str) -> String {
        fs::read_to_string(self.home.join(format!("{name}.log"))).unwrap_or_default()
    }

    pub fn manifest(&self) -> serde_json::Value {
        serde_json::from_str(&self.read(".radin/manifest.json")).unwrap()
    }

    pub fn command(&self, args: &[&str], env: &[(&str, &str)]) -> Command {
        self.command_of(env!("CARGO_BIN_EXE_radin"), args, env)
    }

    pub fn command_of(&self, program: &str, args: &[&str], env: &[(&str, &str)]) -> Command {
        let mut c = Command::new(program);
        c.args(args)
            .current_dir(&self.work)
            .env("HOME", &self.home)
            .env("XDG_CONFIG_HOME", self.home.join(".config"))
            .env("CODEX_HOME", self.home.join(".codex"))
            .env("RADIN_DETAILS", "1")
            .env("PATH", format!("{}:/usr/bin:/bin", self.bin.display()))
            .env("MOCK_LOG_DIR", &self.home)
            .env("MOCK_BIN", &self.bin)
            .env("TERM", "dumb");
        for v in [
            "OPENCODE_CONFIG",
            "CARGO_HOME",
            "RADIN_INSTALLER_URL",
            "CLAUDE_CONFIG_DIR",
            "OPENCODE",
            "RADIN_ASSETS",
            "HOMEBREW_NO_AUTO_UPDATE",
            "MOCK_FAIL",
            "MOCK_NPX",
            "MOCK_CBM",
            "MOCK_CLAUDE_LIST",
            "MOCK_CURL",
            "MOCK_CURL_FAIL",
        ] {
            c.env_remove(v);
        }
        c.envs(env.iter().copied());
        c
    }

    pub fn run_env(&self, args: &[&str], stdin: &str, env: &[(&str, &str)]) -> R {
        use std::io::Write;
        let mut c = self.command(args, env);
        c.stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        let mut child = c.spawn().unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(stdin.as_bytes())
            .unwrap();
        let o = child.wait_with_output().unwrap();
        R {
            code: o.status.code().unwrap_or(-1),
            out: String::from_utf8_lossy(&o.stdout).into_owned(),
            err: String::from_utf8_lossy(&o.stderr).into_owned(),
        }
    }

    pub fn install(&self, args: &[&str]) -> R {
        let all: Vec<&str> = ["install"].iter().chain(args).copied().collect();
        self.run_env(&all, "", &[])
    }

    /// Every file under HOME with its digest, sorted: a snapshot that proves "changes nothing".
    pub fn tree(&self) -> Vec<(String, String)> {
        fn walk(d: &Path, home: &Path, out: &mut Vec<(String, String)>) {
            for e in fs::read_dir(d).unwrap().flatten() {
                let p = e.path();
                let m = fs::symlink_metadata(&p).unwrap();
                if m.is_dir() {
                    walk(&p, home, out);
                } else {
                    let rel = p.strip_prefix(home).unwrap().to_string_lossy().into_owned();
                    let d = if m.is_symlink() {
                        format!("-> {}", fs::read_link(&p).unwrap().display())
                    } else {
                        sha(&p)
                    };
                    out.push((rel, d));
                }
            }
        }
        let mut v = vec![];
        walk(&self.home, &self.home, &mut v);
        v.sort();
        v
    }

    /// A copy of the shipped sources that `RADIN_ASSETS` can point at, to break or change one file.
    pub fn assets_copy(&self) -> PathBuf {
        let dst = self.work.parent().unwrap().join("assets");
        let src = Path::new(env!("CARGO_MANIFEST_DIR"));
        fs::create_dir_all(&dst).unwrap();
        for d in ["skills", "lib", "hosts"] {
            let _ = fs::remove_dir_all(dst.join(d));
            assert!(Command::new("cp")
                .arg("-R")
                .arg(src.join(d))
                .arg(dst.join(d))
                .status()
                .unwrap()
                .success());
        }
        dst
    }
}

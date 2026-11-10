#[path = "common/cli.rs"]
mod cli;
mod common;

use std::fs;
use std::path::PathBuf;

struct W {
    _t: tempfile::TempDir,
    home: PathBuf,
    proj: PathBuf,
}

fn w() -> W {
    let t = tempfile::tempdir().unwrap();
    let home = t.path().canonicalize().unwrap();
    let proj = home.join("proj");
    fs::create_dir_all(proj.join("sub")).unwrap();
    cli::git(&proj, &["init", "-q"]);
    W { _t: t, home, proj }
}

impl W {
    fn tele(&self, scope: &str) -> String {
        fs::read_to_string(self.home.join(format!(".radin/telemetry/{scope}.jsonl"))).unwrap()
    }
    fn run(&self, args: &[&str]) -> cli::Run {
        cli::radin(&self.proj, &self.home, args)
    }
}

fn is_ts(s: &str) -> bool {
    let b = s.as_bytes();
    b.len() == 20
        && b[19] == b'Z'
        && b[10] == b'T'
        && b.iter()
            .enumerate()
            .all(|(i, c)| [4, 7, 10, 13, 16, 19].contains(&i) || c.is_ascii_digit())
}

#[test]
fn record_in_a_subdirectory_writes_the_toplevel_as_repo_with_fields_in_order() {
    let w = w();
    let top = cli::git(&w.proj, &["rev-parse", "--show-toplevel"]);
    let top = top.trim_end();
    let r = cli::radin(
        &w.proj.join("sub"),
        &w.home,
        &[
            "telemetry",
            "record",
            "parallel",
            "wave-start",
            "n=3",
            "mode=group",
        ],
    );
    assert_eq!(r.code, 0, "{}", r.err);
    let text = w.tele("parallel");
    assert_eq!(text.lines().count(), 1);
    let line = text.lines().next().unwrap();
    let ts = &line[7..27];
    assert!(is_ts(ts), "{ts}");
    assert_eq!(
        line,
        format!(
            "{{\"ts\":\"{ts}\",\"repo\":\"{top}\",\"scope\":\"parallel\",\"kind\":\"wave-start\",\"evidence\":{{\"n\":\"3\",\"mode\":\"group\"}}}}"
        )
    );
}

#[test]
fn report_error_writes_kind_error_with_where_message_then_the_extra_pairs() {
    let w = w();
    let r = w.run(&[
        "telemetry",
        "report-error",
        "parallel",
        "gate-merge",
        "merge failed",
        "task=t-one",
    ]);
    assert_eq!(r.code, 0);
    let text = w.tele("parallel");
    assert!(text.contains("\"kind\":\"error\""));
    assert!(text.ends_with(
        "\"evidence\":{\"where\":\"gate-merge\",\"message\":\"merge failed\",\"task\":\"t-one\"}}\n"
    ));
}

#[test]
fn a_message_with_quote_backslash_and_newline_stays_on_one_json_line() {
    let w = w();
    let r = w.run(&[
        "telemetry",
        "report-error",
        "parallel",
        "where",
        "say \"hi\" \\ a\nb\tc\rd",
    ]);
    assert_eq!(r.code, 0);
    let text = w.tele("parallel");
    assert_eq!(text.lines().count(), 1);
    assert!(
        text.contains("\"message\":\"say \\\"hi\\\" \\\\ a b c d\""),
        "{text}"
    );
}

#[test]
fn two_scopes_write_two_files_and_one_scope_appends_a_line_per_call() {
    let w = w();
    for a in [["parallel", "a"], ["parallel", "b"], ["install", "c"]] {
        assert_eq!(w.run(&["telemetry", "record", a[0], a[1]]).code, 0);
    }
    assert_eq!(w.tele("parallel").lines().count(), 2);
    assert_eq!(w.tele("install").lines().count(), 1);
}

#[test]
fn outside_a_git_repo_the_repo_field_is_the_working_directory() {
    let w = w();
    let plain = w.home.join("plain");
    fs::create_dir(&plain).unwrap();
    let r = cli::radin(&plain, &w.home, &["telemetry", "record", "parallel", "a"]);
    assert_eq!(r.code, 0);
    assert!(w
        .tele("parallel")
        .contains(&format!("\"repo\":\"{}\"", plain.display())));
}

#[test]
fn invalid_input_exits_2_and_writes_nothing() {
    let w = w();
    for args in [
        &["record", "../x", "a"][..],
        &["record", "Parallel", "a"],
        &["record", "parallel", "a", "n3"],
        &["record", "parallel", "a", "bad/key=1"],
        &["record", "parallel"],
        &["report-error", "parallel", "where"],
        &["record", "", "a"],
        &["nope"],
        &[],
    ] {
        let mut a = vec!["telemetry"];
        a.extend_from_slice(args);
        let r = w.run(&a);
        assert_eq!(r.code, 2, "{args:?}");
        assert!(r.err.contains("usage: radin telemetry record"), "{args:?}");
    }
    assert!(!w.home.join(".radin").exists());
}

#[test]
fn a_telemetry_path_that_is_a_file_warns_and_exits_0_without_a_record() {
    let w = w();
    fs::create_dir_all(w.home.join(".radin")).unwrap();
    let file = w.home.join(".radin/telemetry");
    fs::write(&file, "").unwrap();
    let r = w.run(&["telemetry", "record", "parallel", "a", "n=1"]);
    assert_eq!(r.code, 0);
    assert_eq!(
        r.err,
        format!(
            "radin telemetry: warning: could not write {}/parallel.jsonl\n",
            file.display()
        )
    );
    assert_eq!(fs::read_to_string(&file).unwrap(), "");
}

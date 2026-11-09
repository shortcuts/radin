use std::fs;
use std::path::Path;
use std::process::Command;

fn repo() -> &'static Path {
    Path::new(env!("CARGO_MANIFEST_DIR"))
}

fn names(root: &Path, kind: &str) -> Vec<String> {
    let text = fs::read_to_string(root.join("SHIPPED")).unwrap_or_default();
    text.lines()
        .filter_map(|l| {
            let f: Vec<&str> = l.split_whitespace().collect();
            match f.as_slice() {
                [k, n] if *k == kind => Some(n.to_string()),
                [a, b, n] if format!("{a} {b}") == kind => Some(n.to_string()),
                _ => None,
            }
        })
        .collect()
}

fn tracked_lib(root: &Path) -> Vec<String> {
    let o = Command::new("git")
        .args([
            "ls-files",
            "--cached",
            "--others",
            "--exclude-standard",
            "lib",
        ])
        .current_dir(root)
        .output()
        .unwrap();
    if !o.status.success() {
        return Vec::new();
    }
    String::from_utf8_lossy(&o.stdout)
        .lines()
        .map(String::from)
        .collect()
}

fn check(root: &Path) -> Vec<String> {
    let mut bad: Vec<String> = Vec::new();
    let text = fs::read_to_string(root.join("SHIPPED")).unwrap_or_default();
    for (i, l) in text.lines().enumerate() {
        let f: Vec<&str> = l.split_whitespace().collect();
        let known = match f.as_slice() {
            [] => true,
            [k, ..] if k.starts_with('#') => true,
            [k, _] => ["skill", "lib", "hostlib"].contains(k),
            [k, s, _] => ["renamed", "retired"].contains(k) && ["skill", "lib"].contains(s),
            _ => false,
        };
        if !known {
            bad.push(format!("shipped: SHIPPED line {} ({l}) has no known kind: use skill, lib, hostlib, renamed skill, retired skill or retired lib", i + 1));
        }
    }
    let skills = names(root, "skill");
    let libs = names(root, "lib");
    let hostlibs = names(root, "hostlib");
    for s in &skills {
        if !root.join(format!("skills/{s}/SKILL.md")).is_file() {
            bad.push(format!("shipped: SHIPPED lists skill {s} but skills/{s}/SKILL.md is missing: create it or delete the line"));
        }
    }
    for (kind, list) in [("lib", &libs), ("hostlib", &hostlibs)] {
        for l in list {
            if !root.join(format!("lib/{l}")).is_file() {
                bad.push(format!("shipped: SHIPPED lists {kind} {l} but lib/{l} is missing: create it or delete the line"));
            }
        }
    }
    for l in libs.iter().filter(|l| l.ends_with(".md")) {
        bad.push(format!(
            "shipped: lib {l} is rendered: change its SHIPPED kind to hostlib"
        ));
    }
    for l in hostlibs.iter().filter(|l| !l.ends_with(".md")) {
        bad.push(format!(
            "shipped: hostlib {l} is host-neutral: change its SHIPPED kind to lib"
        ));
    }
    let mut dirs: Vec<String> = fs::read_dir(root.join("skills"))
        .into_iter()
        .flatten()
        .filter_map(|e| {
            let e = e.ok()?;
            e.path()
                .is_dir()
                .then(|| e.file_name().into_string().ok())?
        })
        .collect();
    dirs.sort();
    for s in dirs.iter().filter(|s| !skills.contains(s)) {
        bad.push(format!(
            "shipped: skills/{s} exists but is not in SHIPPED: add \"skill {s}\" to SHIPPED"
        ));
    }
    let retired = names(root, "retired lib");
    for f in tracked_lib(root) {
        let l = f.trim_start_matches("lib/");
        if !libs.iter().chain(&hostlibs).chain(&retired).any(|n| n == l) {
            bad.push(format!("shipped: {f} is tracked but not in SHIPPED: add \"lib {l}\" (or hostlib for .md) to SHIPPED"));
        }
    }
    let readme = fs::read_to_string(root.join("README.md")).unwrap_or_default();
    for s in &skills {
        if !readme
            .lines()
            .any(|l| l.starts_with(&format!("| `/{s}` |")))
        {
            bad.push(format!(
                "shipped: skill {s} is not in the README table: add a row"
            ));
        }
    }
    bad
}

fn fixture(shipped: &str) -> tempfile::TempDir {
    let t = tempfile::tempdir().unwrap();
    fs::create_dir_all(t.path().join("skills/a")).unwrap();
    fs::create_dir_all(t.path().join("lib")).unwrap();
    fs::write(t.path().join("skills/a/SKILL.md"), "").unwrap();
    fs::write(t.path().join("README.md"), "| `/a` | x |\n").unwrap();
    fs::write(t.path().join("SHIPPED"), shipped).unwrap();
    t
}

#[test]
fn shipped_list_agrees_with_the_tree() {
    assert_eq!(check(repo()), Vec::<String>::new());
}

#[test]
fn a_skill_directory_missing_from_shipped_fails() {
    let t = fixture("# none\n");
    fs::create_dir_all(t.path().join("skills/b")).unwrap();
    let got = check(t.path());
    assert!(
        got.contains(
            &"shipped: skills/a exists but is not in SHIPPED: add \"skill a\" to SHIPPED"
                .to_string()
        ),
        "{got:?}"
    );
    assert!(
        got.contains(
            &"shipped: skills/b exists but is not in SHIPPED: add \"skill b\" to SHIPPED"
                .to_string()
        ),
        "{got:?}"
    );
}

#[test]
fn an_unknown_kind_line_fails() {
    let t = fixture("skill a\nwidget a\n");
    assert_eq!(
        check(t.path()),
        vec!["shipped: SHIPPED line 2 (widget a) has no known kind: use skill, lib, hostlib, renamed skill, retired skill or retired lib"]
    );
}

#[test]
fn a_rendered_lib_and_a_host_neutral_hostlib_fail() {
    let t = fixture("skill a\nlib x.md\nhostlib y.sh\n");
    fs::write(t.path().join("lib/x.md"), "").unwrap();
    fs::write(t.path().join("lib/y.sh"), "").unwrap();
    assert_eq!(
        check(t.path()),
        vec![
            "shipped: lib x.md is rendered: change its SHIPPED kind to hostlib",
            "shipped: hostlib y.sh is host-neutral: change its SHIPPED kind to lib",
        ]
    );
}

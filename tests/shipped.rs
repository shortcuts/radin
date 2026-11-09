use std::fs;
use std::path::Path;
use std::process::Command;

const TARGETS: [&str; 1] = ["install.sh"];

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

fn vars_for(target: &str) -> &'static [(&'static str, &'static str)] {
    const SKILLS: (&str, &str) = ("SHIPPED_SKILLS", "skill");
    const LIB: (&str, &str) = ("SHIPPED_LIB", "lib");
    const HOSTLIB: (&str, &str) = ("SHIPPED_HOSTLIB", "hostlib");
    const RENAMED: (&str, &str) = ("RENAMED_SKILLS", "renamed skill");
    const RETIRED: (&str, &str) = ("RETIRED_SKILLS", "retired skill");
    const RETIRED_LIB: (&str, &str) = ("RETIRED_LIB", "retired lib");
    match target {
        _ => &[SKILLS, LIB, HOSTLIB, RENAMED, RETIRED, RETIRED_LIB],
    }
}

fn render_block(root: &Path, target: &str) -> String {
    let mut out = String::from(
        "# BEGIN shipped (generated from SHIPPED by tests/shipped.rs; run make gen, never edit)\n",
    );
    for (var, kind) in vars_for(target) {
        out.push_str(&format!("{var}=\"{}\"\n", names(root, kind).join(" ")));
    }
    out.push_str("# END shipped\n");
    out
}

fn is_marker(line: &str, which: &str) -> bool {
    line.trim_start_matches(' ')
        .starts_with(&format!("# {which} shipped"))
}

fn splice(text: &str, block: &str) -> String {
    let mut out = String::new();
    let mut skip = false;
    for l in text.lines() {
        if is_marker(l, "BEGIN") {
            out.push_str(block);
            skip = true;
        } else if is_marker(l, "END") {
            skip = false;
        } else if !skip {
            out.push_str(l);
            out.push('\n');
        }
    }
    out
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
        bad.push(format!("shipped: skills/{s} exists but is not in SHIPPED: add \"skill {s}\" to SHIPPED, then run make gen"));
    }
    for f in tracked_lib(root) {
        let l = f.trim_start_matches("lib/");
        if !libs.iter().chain(&hostlibs).any(|n| n == l) {
            bad.push(format!("shipped: {f} is tracked but not in SHIPPED: add \"lib {l}\" (or hostlib for .md) to SHIPPED, then run make gen"));
        }
    }
    for t in TARGETS {
        let Ok(cur) = fs::read_to_string(root.join(t)) else {
            continue;
        };
        if !cur.lines().any(|l| is_marker(l, "BEGIN")) {
            bad.push(format!(
                "shipped: {t} has no BEGIN/END marker pair: add one where the list belongs"
            ));
        } else if splice(&cur, &render_block(root, t)) != cur {
            bad.push(format!(
                "shipped: {t} has a stale shipped block: run make gen"
            ));
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
    assert!(got.contains(&"shipped: skills/a exists but is not in SHIPPED: add \"skill a\" to SHIPPED, then run make gen".to_string()), "{got:?}");
    assert!(got.contains(&"shipped: skills/b exists but is not in SHIPPED: add \"skill b\" to SHIPPED, then run make gen".to_string()), "{got:?}");
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

#[test]
fn a_stale_block_fails_until_spliced_and_a_missing_readme_row_fails() {
    let t = fixture("skill a\n");
    fs::write(t.path().join("README.md"), "").unwrap();
    fs::write(
        t.path().join("install.sh"),
        "head\n  # BEGIN shipped\nSHIPPED_SKILLS=\"old\"\n  # END shipped\ntail\n",
    )
    .unwrap();
    assert_eq!(
        check(t.path()),
        vec![
            "shipped: install.sh has a stale shipped block: run make gen",
            "shipped: skill a is not in the README table: add a row",
        ]
    );
    let cur = fs::read_to_string(t.path().join("install.sh")).unwrap();
    let fresh = splice(&cur, &render_block(t.path(), "install.sh"));
    assert_eq!(
        fresh,
        "head\n# BEGIN shipped (generated from SHIPPED by tests/shipped.rs; run make gen, never edit)\nSHIPPED_SKILLS=\"a\"\nSHIPPED_LIB=\"\"\nSHIPPED_HOSTLIB=\"\"\nRENAMED_SKILLS=\"\"\nRETIRED_SKILLS=\"\"\nRETIRED_LIB=\"\"\n# END shipped\ntail\n"
    );
}

#[test]
fn a_target_without_a_marker_fails() {
    let t = fixture("skill a\n");
    fs::write(t.path().join("install.sh"), "no block\n").unwrap();
    assert_eq!(
        check(t.path()),
        vec!["shipped: install.sh has no BEGIN/END marker pair: add one where the list belongs"]
    );
}

#[test]
#[ignore = "rewrites the generated blocks; run through make gen"]
fn gen_writes_blocks() {
    if std::env::var("SHIPPED_GEN").as_deref() != Ok("1") {
        return;
    }
    for t in TARGETS {
        let Ok(cur) = fs::read_to_string(repo().join(t)) else {
            continue;
        };
        assert!(
            cur.lines().any(|l| is_marker(l, "BEGIN")),
            "{t} has no BEGIN/END marker pair: add one where the list belongs"
        );
        fs::write(repo().join(t), splice(&cur, &render_block(repo(), t))).unwrap();
    }
}

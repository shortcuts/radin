use super::git::g;
use std::path::Path;

pub fn is_test_path(p: &str) -> bool {
    p.starts_with("tests/")
        || p.starts_with("test/")
        || p.contains("/tests/")
        || p.contains("/test/")
        || p.contains("/__tests__/")
        || p.ends_with(".bats")
        || ["_test.", ".test.", "_spec.", ".spec."]
            .iter()
            .any(|s| p.contains(s))
}

/// True when `file` is a plan path, or sits under a plan directory (trailing slash, or a directory in `tree`).
pub fn plan_covers_file(tree: &Path, file: &str, plan: &[String]) -> bool {
    plan.iter().any(|p| {
        let p = p.strip_prefix("./").unwrap_or(p);
        if p.is_empty() {
            false
        } else if p.ends_with('/') {
            file.starts_with(p)
        } else {
            file == p || (tree.join(p).is_dir() && file.starts_with(&format!("{p}/")))
        }
    })
}

/// Comma-joined files commit `hash` changes outside the plan; tests, `.radin/` and generated output of a listed input are exempt.
pub fn plan_extras(dir: &Path, hash: &str, plan: &[String]) -> String {
    if plan.is_empty() {
        return String::new();
    }
    let files = g(
        dir,
        &[
            "diff-tree",
            "--no-commit-id",
            "--name-only",
            "-r",
            "--root",
            hash,
        ],
    )
    .unwrap_or_default();
    let mut extras: Vec<&str> = Vec::new();
    for f in files.lines().filter(|f| !f.is_empty()) {
        if is_test_path(f) || f.starts_with(".radin/") || plan_covers_file(dir, f, plan) {
            continue;
        }
        let gen = match f {
            "install.sh" | "lib/radin-doctor.sh" | "lib/radin-uninstall.sh" => {
                "SHIPPED".to_string()
            }
            "docs/img/tui.svg" => "lib/radin-tui.c".to_string(),
            _ if f.starts_with("docs/agents/lifecycle/") && f.ends_with(".svg") => {
                format!("{}.mmd", f.trim_end_matches(".svg"))
            }
            _ => String::new(),
        };
        if !gen.is_empty() && plan_covers_file(dir, &gen, plan) {
            continue;
        }
        extras.push(f);
    }
    extras.join(",")
}

pub fn norm_path(root: &Path, p: &str) -> String {
    let p = p.strip_prefix("./").unwrap_or(p);
    if !p.ends_with('/') && root.join(p).is_dir() {
        format!("{p}/")
    } else {
        p.to_string()
    }
}

fn path_overlap(a: &str, b: &str) -> Option<String> {
    if a == b || (a.ends_with('/') && b.starts_with(a)) {
        Some(b.to_string())
    } else if b.ends_with('/') && a.starts_with(b) {
        Some(a.to_string())
    } else {
        None
    }
}

pub fn shared_paths(a: &[String], b: &[String]) -> String {
    let mut out: Vec<String> = Vec::new();
    for x in a.iter().filter(|x| !x.is_empty()) {
        for y in b.iter().filter(|y| !y.is_empty()) {
            if let Some(hit) = path_overlap(x, y) {
                if !out.contains(&hit) {
                    out.push(hit);
                }
            }
        }
    }
    out.join(",")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn v(p: &[&str]) -> Vec<String> {
        p.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn test_paths_follow_the_convention() {
        for p in [
            "tests/a.sh",
            "x/tests/a",
            "x/__tests__/a",
            "a.bats",
            "a_test.go",
            "a.test.ts",
            "a_spec.rb",
            "a.spec.js",
        ] {
            assert!(is_test_path(p), "{p}");
        }
        for p in ["lib/a.sh", "libtests/a", "attest.sh"] {
            assert!(!is_test_path(p), "{p}");
        }
    }

    #[test]
    fn a_directory_plan_path_matches_by_prefix_not_by_sibling_name() {
        let t = Path::new("/nonexistent");
        assert!(plan_covers_file(t, "lib/x.sh", &v(&["lib/"])));
        assert!(!plan_covers_file(t, "libx.sh", &v(&["lib/"])));
    }

    #[test]
    fn a_file_plan_path_does_not_accept_a_longer_sibling_name() {
        let t = Path::new("/nonexistent");
        assert!(plan_covers_file(t, "lib/a", &v(&["lib/a"])));
        assert!(!plan_covers_file(t, "lib/ab.sh", &v(&["lib/a"])));
        assert!(plan_covers_file(t, "lib/a", &v(&["./lib/a"])));
    }

    #[test]
    fn an_existing_directory_without_a_slash_matches_by_prefix() {
        let d = tempfile::tempdir().unwrap();
        std::fs::create_dir(d.path().join("lib")).unwrap();
        assert!(plan_covers_file(d.path(), "lib/new.sh", &v(&["lib"])));
        assert_eq!(norm_path(d.path(), "./lib"), "lib/");
        assert_eq!(norm_path(d.path(), "lib/a.sh"), "lib/a.sh");
    }

    #[test]
    fn overlap_keeps_the_longer_path_and_ignores_name_prefixes() {
        assert_eq!(shared_paths(&v(&["lib/x.sh"]), &v(&["lib/"])), "lib/x.sh");
        assert_eq!(shared_paths(&v(&["lib/"]), &v(&["lib/x.sh"])), "lib/x.sh");
        assert_eq!(shared_paths(&v(&["lib/a/"]), &v(&["lib/ab.sh"])), "");
        assert_eq!(shared_paths(&v(&["a", "b"]), &v(&["b", "a"])), "a,b");
    }
}

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

/// Doc and wiring files every task in a repo may edit.
pub fn is_shared_path(p: &str) -> bool {
    [
        "AGENTS.md",
        "docs/key-systems.md",
        "docs/technical-overview.md",
        "production/dashboard/wiring.json",
    ]
    .contains(&p)
}

/// Files that judge a change: CI workflows, build and lint config, and the rubric files.
pub fn is_verify_path(p: &str) -> bool {
    p.starts_with(".github/workflows/")
        || [
            ".gitlab-ci.yml",
            "Makefile",
            "REVIEW.md",
            "AGENTS.md",
            "CLAUDE.md",
            "CONTRIBUTING.md",
            ".pre-commit-config.yaml",
            "rustfmt.toml",
            "clippy.toml",
        ]
        .contains(&p)
        || p.starts_with(".eslintrc")
        || p.starts_with("eslint.config.")
}

/// Comma-joined verification files commit `hash` changes that the plan does not list.
pub fn verify_edits(dir: &Path, hash: &str, plan: &[String]) -> String {
    if hash.is_empty() {
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
    files
        .lines()
        .filter(|f| is_verify_path(f) && !plan_covers_file(dir, f, plan))
        .collect::<Vec<_>>()
        .join(",")
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

/// Comma-joined files commit `hash` changes outside the plan; tests, shared doc and wiring files, `.radin/` and generated output of a listed input are exempt.
pub fn plan_extras(dir: &Path, hash: &str, plan: &[String]) -> String {
    if plan.is_empty() || hash.is_empty() {
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
        if is_test_path(f)
            || is_shared_path(f)
            || f.starts_with(".radin/")
            || plan_covers_file(dir, f, plan)
        {
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
    fn shared_doc_and_wiring_files_are_no_extras() {
        let d = tempfile::tempdir().unwrap();
        let t = d.path();
        let git = |a: &[&str]| g(t, a).unwrap();
        git(&["init", "-q"]);
        for f in [
            "AGENTS.md",
            "docs/key-systems.md",
            "production/dashboard/wiring.json",
            "lib/other.sh",
        ] {
            std::fs::create_dir_all(t.join(f).parent().unwrap()).unwrap();
            std::fs::write(t.join(f), "x").unwrap();
        }
        git(&["add", "."]);
        git(&[
            "-c",
            "user.name=t",
            "-c",
            "user.email=t@t",
            "commit",
            "-q",
            "-m",
            "c",
        ]);
        assert_eq!(plan_extras(t, "HEAD", &v(&["lib/a.sh"])), "lib/other.sh");
    }

    #[test]
    fn verify_paths_are_the_files_that_judge_a_change() {
        for p in [
            ".github/workflows/ci.yml",
            "Makefile",
            "REVIEW.md",
            "eslint.config.js",
        ] {
            assert!(is_verify_path(p), "{p}");
        }
        for p in ["src/Makefile.rs", "docs/REVIEW.md", "lib/a.sh"] {
            assert!(!is_verify_path(p), "{p}");
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
    }
}

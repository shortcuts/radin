use serde_json::Value;
use std::path::Path;
use std::process::Command;

pub struct Edge {
    pub src_qn: String,
    pub src_file: String,
    pub dst_qn: String,
    pub dst_file: String,
}

pub struct Gap {
    pub kind: &'static str,
    pub detail: String,
}

const RETRY_WAIT_MS: u64 = 300;

fn gap(kind: &'static str, detail: impl Into<String>) -> Vec<Gap> {
    vec![Gap {
        kind,
        detail: detail.into(),
    }]
}

fn call(tool: &str, flags: &[&str]) -> Result<Value, Vec<Gap>> {
    let run = || {
        Command::new("codebase-memory-mcp")
            .args(["cli", tool, "--format", "json"])
            .args(flags)
            .output()
            .map_err(|e| gap("graph-cli", format!("{tool}: {e}")))
    };
    let mut o = run()?;
    // A busy CBM daemon clears in seconds, so one bounded retry saves a false gap.
    if !o.status.success() && String::from_utf8_lossy(&o.stderr).contains("daemon") {
        std::thread::sleep(std::time::Duration::from_millis(RETRY_WAIT_MS));
        o = run()?;
    }
    if !o.status.success() {
        let err = String::from_utf8_lossy(&o.stderr);
        let first = err.lines().next().unwrap_or("");
        return Err(gap(
            "graph-cli",
            format!("{tool}: exit {}: {first}", o.status),
        ));
    }
    serde_json::from_slice(&o.stdout)
        .map_err(|e| gap("graph-cli", format!("{tool}: unparsable JSON: {e}")))
}

fn project_of(root: &Path) -> Result<String, Vec<Gap>> {
    let canon = |p: &Path| p.canonicalize().unwrap_or_else(|_| p.to_path_buf());
    let want = canon(root);
    let v = call("list_projects", &[])?;
    v["projects"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|p| {
            p["root_path"]
                .as_str()
                .is_some_and(|r| canon(Path::new(r)) == want)
        })
        .and_then(|p| p["name"].as_str().map(str::to_string))
        .ok_or_else(|| gap("not-indexed", root.display().to_string()))
}

fn stale(project: &str, files: &[String]) -> Result<(), Vec<Gap>> {
    let paths = serde_json::to_string(files).unwrap_or_default();
    let limit = files.len().to_string();
    let v = call(
        "check_index_coverage",
        &[
            "--project",
            project,
            "--paths",
            &paths,
            "--path-limit",
            &limit,
        ],
    )?;
    let rows = v["paths"].as_array().cloned().unwrap_or_default();
    let mut gaps: Vec<Gap> = files
        .iter()
        .filter_map(|f| {
            let Some(r) = rows.iter().find(|r| r["path"].as_str() == Some(f)) else {
                return Some(Gap {
                    kind: "stale",
                    detail: format!("{f} absent"),
                });
            };
            let (st, fr) = (r["status"].as_str(), r["freshness"].as_str());
            (st != Some("no_recorded_issue") || fr != Some("metadata_match")).then(|| Gap {
                kind: "stale",
                detail: format!(
                    "{f} freshness={} status={}",
                    fr.unwrap_or(""),
                    st.unwrap_or("")
                ),
            })
        })
        .collect();
    if v["path_has_more"].as_bool() == Some(true) {
        gaps.push(Gap {
            kind: "truncated",
            detail: "check_index_coverage path_has_more".into(),
        });
    }
    if gaps.is_empty() {
        Ok(())
    } else {
        Err(gaps)
    }
}

pub fn load(repo_root: &Path, files: &[String]) -> Result<Vec<Edge>, Vec<Gap>> {
    if let Some(f) = files.iter().find(|f| f.contains(['"', '\\'])) {
        return Err(gap("unqueryable", f.clone()));
    }
    let project = project_of(repo_root)?;
    stale(&project, files)?;
    let list = serde_json::to_string(files).unwrap_or_default();
    let query = format!(
        "MATCH (a)-[r:CALLS]->(b) WHERE a.file_path IN {list} OR b.file_path IN {list} RETURN a.qualified_name, a.file_path, b.qualified_name, b.file_path"
    );
    let v = call(
        "query_graph",
        &[
            "--project",
            &project,
            "--query",
            &query,
            "--max-rows",
            "99998",
        ],
    )?;
    if v["has_more"].as_bool() == Some(true) || v["truncated"].as_bool() == Some(true) {
        return Err(gap("truncated", "query_graph has_more or truncated"));
    }
    let prefix = format!("{project}.");
    let cell = |r: &Value, i: usize| r[i].as_str().unwrap_or("").to_string();
    let strip = |s: String| s.strip_prefix(&prefix).map_or(s.clone(), str::to_string);
    Ok(v["rows"]
        .as_array()
        .into_iter()
        .flatten()
        .map(|r| Edge {
            src_qn: strip(cell(r, 0)),
            src_file: cell(r, 1),
            dst_qn: strip(cell(r, 2)),
            dst_file: cell(r, 3),
        })
        .collect())
}

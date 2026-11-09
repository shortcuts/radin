use super::{die, NAME};
use crate::paths::git;
use crate::{jsonedit, Ctx, Out};
use std::fs;
use std::io::Write;

const P: &str = "radin-cbm-hooks";
const MARKER: &str = "<!-- codebase-memory-mcp MCP tools -->";
const HEADING: &str = "## MCP Tools: codebase-memory-mcp";
const BODY: &str = r#"
## MCP Tools: codebase-memory-mcp

This machine has the codebase-memory-mcp knowledge graph. For a structural
question (where a symbol is defined, who calls it, what a change affects), use
its MCP tools before Grep/Glob/Read -- they answer in fewer tokens than file
scanning. If the tools are deferred, load them with `ToolSearch` first:

- `search_graph` to find a symbol: `query` for BM25, `semantic_query` when you know the idea but not the name; `search_code` for text inside indexed files
- `get_file_outline` for the symbols in one file, before reading all of it
- `check_index_coverage` before trusting an empty result for a path
- `trace_path` for callers and callees, before changing anything shared
- `detect_changes` to map the working-tree diff to affected symbols and blast radius
- `get_code_snippet` to read one function, `get_architecture` for an unfamiliar area
- `query_graph` for Cypher-shaped questions, after `get_graph_schema`
- `index_repository` when `list_projects` does not list this repo yet, `index_status` while it runs; the background watcher keeps it current after that

A graph hit is a pointer: read the file before editing it, and never conclude
something does not exist from an empty result. Fall back to file scanning when
the graph does not cover what you need. The MCP tools document their own
parameters and use."#;

pub(super) fn claude_md(c: &Ctx) -> Out {
    let dir = c.home.join(".claude");
    let file = dir.join("CLAUDE.md");
    let shown = file.display();
    let existing = fs::read_to_string(&file).unwrap_or_default();
    if existing.contains(MARKER) || existing.contains(HEADING) {
        return (
            0,
            format!("PRESENT  {shown} (codebase-memory-mcp section)\n"),
            String::new(),
        );
    }
    let write = || -> std::io::Result<()> {
        fs::create_dir_all(&dir)?;
        let mut f = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&file)?;
        if f.metadata()?.len() > 0 {
            f.write_all(b"\n")?;
        }
        writeln!(f, "{MARKER}{BODY}")
    };
    match write() {
        Ok(()) => (
            0,
            format!("ADDED    {shown} (codebase-memory-mcp section)\n"),
            String::new(),
        ),
        Err(e) => die(P, &format!("{shown}: {e}")),
    }
}

pub(super) fn mcp(c: &Ctx, repo: &str, bin: &str) -> Out {
    let repo = if repo.is_empty() {
        git(&c.cwd, &["rev-parse", "--show-toplevel"])
            .map(|s| s.trim_end().to_string())
            .unwrap_or_default()
    } else {
        repo.to_string()
    };
    if repo.is_empty() {
        return die(P, "mcp: not inside a git repo and no repo-root given");
    }
    jsonedit::ensure_mcp(&format!("{repo}/.mcp.json"), NAME, bin)
}

pub(super) fn all(c: &Ctx, repo: &str, bin: &str) -> Out {
    let (code, mut out, mut err) = claude_md(c);
    if code != 0 {
        return (code, out, err);
    }
    let (code, o, e) = mcp(c, repo, bin);
    out.push_str(&o);
    err.push_str(&e);
    (code, out, err)
}

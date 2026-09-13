#!/usr/bin/env bash
# Wires codebase-memory-mcp into Claude Code without running its own agent
# configuration. Upstream's `install` (without `--skip-config`) writes MCP
# entries, a skill, three agent definitions and SessionStart/SubagentStart/
# PreToolUse hooks into ~/.claude for 45 client surfaces -- radin installs it
# with `--skip-config` and owns these two writes itself instead:
#   claude-md      append the graph-tools section to ~/.claude/CLAUDE.md
#   mcp [repo-root]   add the MCP server entry to <repo-root>/.mcp.json
#   all [repo-root]   both of the above
# Every write is skipped when the target already defines the entry, whatever
# shape it has -- an existing definition is never redefined.
# No settings.json hook: codebase-memory-mcp keeps the graph current from its
# own background watcher, so a PostToolUse reindex would pay for nothing.
# Installed to ~/.claude/.radin/lib/radin-cbm-hooks.sh by install.sh.
# Must stay bash-3.2-compatible (macOS /bin/bash).
set -euo pipefail

CLAUDE_DIR="$HOME/.claude"
CBM_NAME="codebase-memory-mcp"
CBM_BIN="$CBM_NAME"

die() {
	printf 'radin-cbm-hooks: %s\n' "$*" >&2
	exit 1
}

# Its installer's default target is ~/.local/bin, which isn't on every PATH.
if ! command -v "$CBM_BIN" >/dev/null 2>&1; then
	if [ -x "$HOME/.local/bin/$CBM_NAME" ]; then
		CBM_BIN="$HOME/.local/bin/$CBM_NAME"
	else
		die "$CBM_BIN not found on PATH or in ~/.local/bin -- run radin's install.sh first"
	fi
fi

CBM_MARKER='<!-- codebase-memory-mcp MCP tools -->'
# shellcheck disable=SC2016  # backticks here are markdown code spans, not command substitution
CBM_SECTION="$CBM_MARKER"'
## MCP Tools: codebase-memory-mcp

This machine has the codebase-memory-mcp knowledge graph. In projects wired
for it (an `mcpServers.codebase-memory-mcp` entry in `.mcp.json`), use its MCP
tools before Grep/Glob/Read -- they answer structural questions in fewer
tokens than file scanning:

- `search_graph` to find a symbol (structural, BM25 and semantic), `search_code` for text inside indexed files
- `trace_path` for callers and callees, before changing anything shared
- `detect_changes` to map the working-tree diff to affected symbols and blast radius
- `get_code_snippet` to read one function, `get_architecture` for an unfamiliar area
- `query_graph` for Cypher-shaped questions, after `get_graph_schema`
- `index_repository` when `list_projects` does not list this repo yet; the background watcher keeps it current after that

A graph hit is a pointer: read the file before editing it, and never conclude
something does not exist from an empty result. Fall back to file scanning when
the graph does not cover what you need. The MCP tools document their own
parameters and use.'

ensure_claude_md() {
	local file="$CLAUDE_DIR/CLAUDE.md"
	if [ -f "$file" ] && grep -qF -e "$CBM_MARKER" -e '## MCP Tools: codebase-memory-mcp' "$file"; then
		printf 'PRESENT  %s (codebase-memory-mcp section)\n' "$file"
		return 0
	fi
	mkdir -p "$CLAUDE_DIR"
	if [ -s "$file" ]; then
		printf '\n' >>"$file"
	fi
	printf '%s\n' "$CBM_SECTION" >>"$file"
	printf 'ADDED    %s (codebase-memory-mcp section)\n' "$file"
}

ensure_mcp() {
	local repo="${1:-}"
	if [ -z "$repo" ]; then
		repo="$(git rev-parse --show-toplevel 2>/dev/null || true)"
	fi
	[ -n "$repo" ] || die "mcp: not inside a git repo and no repo-root given"
	local bin_path
	bin_path="$(command -v "$CBM_BIN")"
	# codebase-memory-mcp is a static binary, so python3 is no longer implied by
	# having installed it -- name the entry to paste when it is missing.
	command -v python3 >/dev/null 2>&1 || die "python3 not found -- add this to $repo/.mcp.json by hand:
  \"mcpServers\": { \"$CBM_NAME\": { \"type\": \"stdio\", \"command\": \"$bin_path\", \"args\": [] } }"
	python3 - "$repo/.mcp.json" "$CBM_NAME" "$bin_path" <<'PY'
import json, sys
path, name, command = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(path) as f:
        config = json.load(f)
except FileNotFoundError:
    config = {}
except json.JSONDecodeError:
    sys.exit(f"radin-cbm-hooks: {path} is not valid JSON -- fix it first, nothing written")

servers = config.setdefault("mcpServers", {})
if name in servers:
    print(f"PRESENT  {path} (mcpServers.{name})")
else:
    servers[name] = {"type": "stdio", "command": command, "args": []}
    with open(path, "w") as f:
        json.dump(config, f, indent=2)
        f.write("\n")
    print(f"ADDED    {path} (mcpServers.{name})")
PY
}

cmd="${1:-}"
case "$cmd" in
claude-md) ensure_claude_md ;;
mcp) ensure_mcp "${2:-}" ;;
all)
	ensure_claude_md
	ensure_mcp "${2:-}"
	;;
*)
	die "usage: radin-cbm-hooks.sh <claude-md|mcp [repo-root]|all [repo-root]>"
	;;
esac

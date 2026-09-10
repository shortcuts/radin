#!/usr/bin/env bash
# Wires code-review-graph into Claude Code without running its own installer.
# Upstream's `code-review-graph install` replaces the whole `hooks` key in
# settings.json (dict.update), clobbering any hooks the user already has --
# so radin replicates the three writes itself, merge-only:
#   claude-md          append the graph-tools section to ~/.claude/CLAUDE.md
#   settings           add the two hooks to ~/.claude/settings.json
#   mcp [repo-root]    add the MCP server entry to <repo-root>/.mcp.json
#   all [repo-root]    the three above
# Every write is skipped when the target already defines the entry, whatever
# shape it has -- an existing definition is never redefined.
# python3 is guaranteed here: code-review-graph itself is a pip package.
# Installed to ~/.claude/.radin/lib/radin-crg-hooks.sh by install.sh.
# Must stay bash-3.2-compatible (macOS /bin/bash).
set -euo pipefail

CLAUDE_DIR="$HOME/.claude"

die() {
	printf 'radin-crg-hooks: %s\n' "$*" >&2
	exit 1
}

command -v code-review-graph >/dev/null 2>&1 || die "code-review-graph not installed -- run radin's install.sh first"
command -v python3 >/dev/null 2>&1 || die "python3 not found"

# Upstream's marker included on purpose: their installer checks for it, so a
# section written here also stops `code-review-graph install` from duplicating.
CRG_MARKER='<!-- code-review-graph MCP tools -->'
# shellcheck disable=SC2016  # backticks here are markdown code spans, not command substitution
CRG_SECTION="$CRG_MARKER"'
## MCP Tools: code-review-graph

This machine has the code-review-graph knowledge graph. In projects wired for
it (a `.mcp.json` entry), use its MCP tools before Grep/Glob/Read: they answer
structural questions (callers, dependents, impact radius, test coverage,
review context) in fewer tokens than file scanning. Fall back to file scanning
only when the graph does not cover what you need. The MCP tools document their
own parameters and use.'

ensure_claude_md() {
	local file="$CLAUDE_DIR/CLAUDE.md"
	if [ -f "$file" ] && grep -qF -e "$CRG_MARKER" -e '## MCP Tools: code-review-graph' "$file"; then
		printf 'PRESENT  %s (code-review-graph section)\n' "$file"
		return 0
	fi
	mkdir -p "$CLAUDE_DIR"
	if [ -s "$file" ]; then
		printf '\n' >>"$file"
	fi
	printf '%s\n' "$CRG_SECTION" >>"$file"
	printf 'ADDED    %s (code-review-graph section)\n' "$file"
}

ensure_settings() {
	local file="$CLAUDE_DIR/settings.json"
	mkdir -p "$CLAUDE_DIR"
	python3 - "$file" <<'PY'
import json, sys
path = sys.argv[1]
try:
    with open(path) as f:
        settings = json.load(f)
except FileNotFoundError:
    settings = {}
except json.JSONDecodeError:
    sys.exit(f"radin-crg-hooks: {path} is not valid JSON -- fix it first, nothing written")

wanted = {
    "PostToolUse": {
        "marker": "code-review-graph update",
        "entry": {"matcher": "Edit|Write|Bash",
                  "hooks": [{"type": "command",
                             "command": "code-review-graph update --skip-flows",
                             "timeout": 30}]},
    },
    "SessionStart": {
        "marker": "code-review-graph status",
        "entry": {"matcher": "",
                  "hooks": [{"type": "command",
                             "command": "code-review-graph status",
                             "timeout": 10}]},
    },
}

# A hook counts as present when its command already appears anywhere in the
# file -- the user may carry their own variant, and it must not be redefined.
blob = json.dumps(settings)
hooks = settings.setdefault("hooks", {})
changed = False
for event, spec in wanted.items():
    if spec["marker"] in blob:
        print(f"PRESENT  {path} ({spec['marker']} hook)")
        continue
    hooks.setdefault(event, []).append(spec["entry"])
    print(f"ADDED    {path} ({spec['marker']} hook)")
    changed = True

if changed:
    with open(path, "w") as f:
        json.dump(settings, f, indent=2)
        f.write("\n")
PY
}

ensure_mcp() {
	local repo="${1:-}"
	if [ -z "$repo" ]; then
		repo="$(git rev-parse --show-toplevel 2>/dev/null || true)"
	fi
	[ -n "$repo" ] || die "mcp: not inside a git repo and no repo-root given"
	python3 - "$repo/.mcp.json" <<'PY'
import json, sys
path = sys.argv[1]
try:
    with open(path) as f:
        config = json.load(f)
except FileNotFoundError:
    config = {}
except json.JSONDecodeError:
    sys.exit(f"radin-crg-hooks: {path} is not valid JSON -- fix it first, nothing written")

servers = config.setdefault("mcpServers", {})
if "code-review-graph" in servers:
    print(f"PRESENT  {path} (mcpServers.code-review-graph)")
else:
    servers["code-review-graph"] = {"type": "stdio",
                                    "command": "code-review-graph",
                                    "args": ["serve"]}
    with open(path, "w") as f:
        json.dump(config, f, indent=2)
        f.write("\n")
    print(f"ADDED    {path} (mcpServers.code-review-graph)")
PY
}

cmd="${1:-}"
case "$cmd" in
claude-md) ensure_claude_md ;;
settings) ensure_settings ;;
mcp) ensure_mcp "${2:-}" ;;
all)
	ensure_claude_md
	ensure_settings
	ensure_mcp "${2:-}"
	;;
*)
	die "usage: radin-crg-hooks.sh <claude-md|settings|mcp [repo-root]|all [repo-root]>"
	;;
esac

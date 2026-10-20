# Explore rule

The one rule for which tool answers which question. `lib/radin-prompt.sh` writes
the fence into the execution, debug and factfind prompts at the `EXPLORE_RULE`
token. `radin-plan` and `radin-review` read this file. It names no graph tool
verb ([why](../docs/DECISIONS.md#limits-of-the-codebase-memory-mcp-bracket)).

```
Explore with these tools, in this order:
- Load the `codebase-memory-mcp` tools with `ToolSearch` before first use.
- A question about a symbol, its callers, or what a change reaches goes to
  `codebase-memory-mcp`'s MCP tools. Check that the index covers each file you
  rely on.
- A literal string, a config value, or a non-code file goes to Grep.
- A graph hit is a pointer: read the file before you cite or edit it. An empty
  graph result proves nothing, so confirm it with Grep.
- Run shell commands through `rtk`, for the token savings.
```

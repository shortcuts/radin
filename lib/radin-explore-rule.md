# Explore rule

The one rule for which tool answers which question. `src/prompt.rs` writes
the fence into the execution, debug and factfind prompts at the `EXPLORE_RULE`
token. `radin-plan` and `radin-review` read this file. It names no graph tool
verb ([why](../docs/agents/DECISIONS.md#limits-of-the-codebase-memory-mcp-bracket)).

```
Explore with these tools, in this order:
<!-- host:claude -->
- Load the `codebase-memory-mcp` tools with `ToolSearch` before first use.
<!-- /host -->
- A question about a symbol, its callers, or what a change reaches goes to
  `codebase-memory-mcp`'s MCP tools. Check that the index covers each file you
  rely on. Follow the `[codebase-memory]` notes its hooks add to your context.
- A literal string in indexed code goes to `codebase-memory-mcp`'s text
  search. A config value, a non-code file or an unindexed path goes to Grep.
- A graph hit is a pointer: read the file before you cite or edit it. An empty
  graph result proves nothing, so confirm it with Grep.
- Prefix each shell command with `rtk`, for the token savings. Re-run one as
  `rtk bypass <cmd>` only when its output is unusable.
```

# Template: radin-execute fact-finding prompt (`BLOCKED (FACT)`)

Source text for `radin prompt factfind <id>` (`lib/radin-prompt.sh`), which drops the
guarded blocks that do not apply to the task, substitutes every `UPPERCASE`
placeholder, and prints the result. The router sends that output and never
reads this file.

The `model:` line below is this role's sub-agent model, written in at install
time from the user's answer; `radin-prompt.sh` reads it from here, so it lives
in one place. A `<!-- if:NAME -->` … `<!-- end -->` block survives only when
that guard is active for the task, and `<!-- if:!NAME -->` is its inverse.

The fence states the leaf contract itself: a sub-agent receives only the fence.

`model: "RADIN_MODEL_FACTFIND"`

Answers one checkable question in one turn.

```
Answer one factual question about this codebase or its dependencies, and
change nothing: QUESTION

Context: the task at TASK_FILE was blocked on it.

Investigate read-only: read the repo, its lockfiles, its vendored
dependencies, and its config; run read-only commands (`--help`, `--version`, a
query, a dry run), `rtk`-wrapped.
`codebase-memory-mcp`'s MCP tools locate a symbol faster than Grep, and a
graph hit is a pointer: read the file before you cite it, and never conclude
something is absent from an empty result. Prefer primary sources already on
this machine over recollection.

You are a leaf: no user, no `AskUserQuestion`, no `Workflow`, no sub-agent of
your own, so invoke no skill that asks a human anything or spawns and waits.

Report the answer with the file path, command output, or version that
establishes it. When the evidence is longer than a summary can carry, write
the long form to `NAMESPACE_DIR/state/facts/TASK_ID.md` (create the directory
if needed; that file is the one thing you may write) and report the summary
plus that path. Then the LAST line exactly one of:
`STATUS: FOUND — <the answer, one sentence>`
`STATUS: NOT FOUND — <what you checked, and why it cannot be settled from
here>`
Use NOT FOUND only after you have actually looked. A question that turns out
to need a human's preference rather than a fact is NOT FOUND, so say so.
```

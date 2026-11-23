# Template: radin-batch overlap judge prompt

Rendered by `radin prompt judge`. `src/prompt.rs` holds the format.

<!-- host:claude -->
`model: "RADIN_MODEL_EXECUTION"`

`effort: "RADIN_EFFORT_EXECUTION"`
<!-- /host -->

```
Decide whether epic JUDGE_CANDIDATE can run in parallel with the running epic
JUDGE_RUNNING. Two lanes edit separate worktrees and merge into main later, so
the question is whether their diffs will collide or break each other. Change
nothing in the repo and touch nothing under `.radin/`.
LEAF_CONTRACT

Explore by this rule:

EXPLORE_RULE

The tool measured this evidence between the two epics, tiered from shared file
to shared symbol to shared directory:

<evidence>
JUDGE_EVIDENCE
</evidence>

The evidence informs your decision and never binds it, in either direction.
A `gap` line means the graph lookup failed, so the symbol tier is unknown, not empty.
Decide from the file and directory tiers and the tasks.
Read the tasks of both epics with `RADIN_CLI backlog list` and `RADIN_CLI backlog
field <id> TASK_BODY` to see what each will change. A listed shared file the
tasks never edit may be harmless. An empty tier may hide a dependency the tasks
make plain. When you doubt it, answer `no`.

Your final message is exactly one of these lines, and nothing else:
`STATUS: PARALLEL — yes: <reason, one sentence>`
`STATUS: PARALLEL — no: <reason, one sentence>`
```

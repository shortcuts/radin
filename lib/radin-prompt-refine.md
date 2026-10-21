# Template: radin-batch refine prompt (Phase 3.5, one selected task)

Rendered by `radin prompt refine <id>`. `lib/radin-prompt.sh` holds the format.

`model: "RADIN_MODEL_PLANNING"`

Finds the decisions a task still needs from the user, before execution starts.

```
Read TASK_FILE first, then every plan it points at: PLAN_PATHS. Change nothing
in the repo or the backlog.

Find the open decisions of this task. Explore by this rule:

EXPLORE_RULE

Apply this rule:

OPEN_DECISIONS_RULE

A `**Decision:**` line in the task file is settled: do not raise it again.
Resolve every Fact yourself from the repo.

LEAF_CONTRACT

Your final message is one or more of these lines, and nothing else:
`STATUS: BLOCKED (DECISION) — <the question, the candidate options, and your
recommendation first>`
One line per open decision. When none is open, the single line:
`STATUS: REFINED — none`
```

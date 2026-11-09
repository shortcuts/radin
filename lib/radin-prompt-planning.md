# Template: radin-batch planning prompt (Phase 4, an entry flagged `planning needed`)

Rendered by `radin prompt planning <id>`. `src/prompt.rs` holds the format.

<!-- host:claude -->
`model: "RADIN_MODEL_PLANNING"`
`effort: "RADIN_EFFORT_PLANNING"`
<!-- /host -->

```
Read TASK_FILE first.

<!-- if:EARLIER_PLANS -->
Tasks planned before this one in this wave left the plans EARLIER_PLAN_PATHS.
Read the `## Changes` of each. Before you write a plan, list the files and
symbols your change touches. Write no plan when a file is shared, when a symbol
of yours calls or is called by one of theirs (check the graph's callers and
callees), when a dependency is shared, or when you doubt it. End with
`STATUS: PLANNED — deferred: <what is shared, and with which task id>`.

<!-- end -->
PLANNING_RULE

When the task needs no plan, skip `/radin-plan` and go to the sizing step.

Otherwise invoke the `/radin-plan` skill scoped to the backlog task with id "TASK_ID",
reading TASK_FILE in full as the task scope. It writes the plan file(s) and
records the plan pointer(s) on that task's backlog entry.

LEAF_CONTRACT That rules out `grilling`, `research`, `/deep-research` and any
saved workflow. Anything you could only settle with one is BLOCKED material.
Where the skill would ask (splitting the entry, overwriting an existing plan),
take the non-destructive path: don't split, don't overwrite.
Implement nothing.

The plan must settle every decision: the executor makes no judgment calls,
and a vague plan step is a defect. Before reporting BLOCKED, apply this rule:

OPEN_DECISIONS_RULE

Find each Fact yourself; block only on a Decision.

Sizing step: read the code the task touches, size it by this rule:

COMPLEXITY_RULE

Add `; exclusive: <reason>` to the PLANNED line when an acceptance criterion or the plan's Testing section measures time, frame rate, latency, throughput or memory as a pass or fail number.

Your final message is exactly one of these lines, and nothing else:
`STATUS: PLANNED — <plan file path(s), or "none needed: <reason>">;
complexity <low|high>: <reason>[; exclusive: <reason>]`
`STATUS: BLOCKED (FACT) — <what's unverifiable from here and why, e.g. a
third-party API/library behavior local code and repo exploration can't
settle>`
`STATUS: BLOCKED (DECISION) — <the decision question, the candidate
options, and your recommendation>`
Use BLOCKED (DECISION) for genuine ambiguity only the user can resolve, the
skill matching several entries for this title or none (backlog drift)
included: report what it found, pick nothing, create nothing. Use BLOCKED
(FACT) only for what you tried and failed to verify.
```

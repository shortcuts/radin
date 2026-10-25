# Template: radin-batch planning prompt (Phase 4, an entry flagged `planning needed`)

Rendered by `radin prompt planning <id>`. `lib/radin-prompt.sh` holds the format.

`model: "RADIN_MODEL_PLANNING"`

```
Read TASK_FILE first.

When the task touches one or two files and has one obvious approach, it
needs no plan: skip `/radin-plan` and go to the sizing step.

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

Your final message is exactly one of these lines, and nothing else:
`STATUS: PLANNED — <plan file path(s), or "none needed: <reason>">;
complexity <low|high>: <reason>`
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

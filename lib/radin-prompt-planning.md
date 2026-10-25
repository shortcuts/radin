# Template: radin-batch planning prompt (Phase 4, an entry flagged `planning needed` or with no `complexity`)

Rendered by `radin prompt planning <id>`. `lib/radin-prompt.sh` holds the format.

`model: "RADIN_MODEL_PLANNING"`

```
Read TASK_FILE first.
<!-- if:PLAN_PATHS -->
Then read every plan in PLAN_PATHS.
<!-- end -->

<!-- if:NEEDS_PLAN -->
When the task touches one or two files and has one obvious approach, it
needs no plan: run `RADIN_CLI backlog set-meta "TASK_ID" planning --none`
and go to the sizing step.

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
<!-- end -->
<!-- if:!NEEDS_PLAN -->
This dispatch only sizes the task: write no plan and implement nothing.
LEAF_CONTRACT
<!-- end -->

Sizing step: read the code the task touches, then run
`RADIN_CLI backlog set-meta "TASK_ID" complexity low` when the change is
mechanical (every edit is known before it starts, and no step needs
measuring, tuning, debugging or a device run), else
`RADIN_CLI backlog set-meta "TASK_ID" complexity high`. A low task runs on a
cheaper model. Judge the work, not the category: a chore can be hard. When
unsure, pick high.

Your final message is exactly one of these lines, and nothing else:
`STATUS: PLANNED — <plan file path(s), "none needed: <reason>", or "sized
only">; complexity <low|high>: <reason>`
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

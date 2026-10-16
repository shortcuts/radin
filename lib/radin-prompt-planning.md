# Template: radin-batch planning prompt (Phase 4, an entry flagged `planning needed`)

Rendered by `radin prompt planning <id>`. `lib/radin-prompt.sh` holds the format.

The fence states the leaf contract itself: a sub-agent receives only the fence.

`model: "RADIN_MODEL_PLANNING"`

```
Read TASK_FILE first. When the task touches one or two files and has one
obvious approach, it needs no plan: run
`RADIN_CLI backlog set-meta "TASK_ID" planning --none`, report
`STATUS: PLANNED — none needed: <reason>`, and stop.

Otherwise invoke the `/radin-plan` skill scoped to the backlog task with id "TASK_ID",
reading TASK_FILE in full as the task scope. It writes the plan file(s) and
records the plan pointer(s) on that task's backlog entry.

You are a leaf: no user, no `AskUserQuestion`, no `Workflow`, and no
sub-agent of your own. Where the skill would ask (splitting the entry,
overwriting an existing plan), take the non-destructive path: don't split,
don't overwrite. Drop a skill that asks or spawns and waits (`grilling`,
`research`, `/deep-research`, any saved workflow): it hangs the router. Anything you could only settle that way is BLOCKED material.
Implement nothing.

The plan must settle every decision: the executor makes no judgment calls,
and a vague plan step is a defect. Before reporting BLOCKED, ask whether this
is a fact you could go find (read more of the repo, check a config, run a
read-only command) or a judgment call only the user can make. Find the fact
yourself; block only on the judgment call.

Your final message is exactly one of these lines, and nothing else:
`STATUS: PLANNED — <plan file path(s), or "none needed: <reason>">`
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

# Template: radin-execute planning prompt (Phase 4, `--plan-first`)

Source text for `radin prompt planning <id>` (`lib/radin-prompt.sh`), which drops the
guarded blocks that do not apply to the task, substitutes every `UPPERCASE`
placeholder, and prints the result. The router sends that output and never
reads this file.

The `model:` line below is this role's sub-agent model, written in at install
time from the user's answer; `radin-prompt.sh` reads it from here, so it lives
in one place. A `<!-- if:NAME -->` … `<!-- end -->` block survives only when
that guard is active for the task, and `<!-- if:!NAME -->` is its inverse.

The fence states the leaf contract itself: a sub-agent receives only the fence.

`model: "RADIN_MODEL_PLANNING"`

```
Invoke the `/radin-plan` skill scoped to the backlog task with id "TASK_ID",
reading TASK_FILE in full as the task scope. It writes the plan file(s) and
records the plan pointer(s) on that task's backlog entry.

You are a leaf: no user, no `AskUserQuestion`, no `Workflow`, and no
sub-agent of your own. Where the skill would ask (splitting the entry,
overwriting an existing plan), take the non-destructive path: don't split,
don't overwrite. A skill that asks or spawns and waits — `grilling`,
`research`, `/deep-research`, any saved workflow — hangs the router, so drop
it and say so. Anything you could only settle that way is BLOCKED material.
Implement nothing.

The plan must settle every decision: the executor makes no judgment calls,
and a vague plan step is a defect. Before reporting BLOCKED, ask whether this
is a fact you could go find (read more of the repo, check a config, run a
read-only command) or a judgment call only the user can make. Find the fact
yourself; block only on the judgment call.

Report only what the router needs to route the task, then the LAST line
exactly one of:
`STATUS: PLANNED — <plan file path(s)>`
`STATUS: BLOCKED (FACT) — <what's unverifiable from here and why, e.g. a
third-party API/library behavior local code and repo exploration can't
settle>`
`STATUS: BLOCKED (DECISION) — <the decision question, the candidate
options, and your recommendation>`
Use BLOCKED (DECISION) for genuine ambiguity only the user can resolve, the
skill matching several entries for this title or none (backlog drift)
included: report what it found, pick nothing, create nothing. Use BLOCKED
(FACT) only for something you tried and failed to verify yourself.
```

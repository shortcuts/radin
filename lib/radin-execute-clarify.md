# Shared: radin-execute Blocked-Task Routing

`radin-execute` reads this file when a sub-agent reports `STATUS: BLOCKED`, at
any of the phases that can produce one. A run where nothing blocks never loads
it.

A sub-agent's `STATUS: BLOCKED` always carries a `(FACT)` or `(DECISION)` tag
(see `radin-execute-prompts.md`). Route on it:

- **`BLOCKED (FACT)`**: checkable, and the sub-agent already failed to verify
  it from the repo. Facts are never the user's job to hand over. Dispatch a
  fresh sub-agent with the **Fact-finding prompt** from
  `radin-execute-prompts.md`. It investigates read-only and reports in one
  turn.
  - `STATUS: FOUND`: append the finding to that task's file as a `**Fact:**`
    line (see below), treat the entry as `pending`, retry from Step 4a. If it
    reports a `state/facts/<id>.md` path, append `**Facts:** <path>` instead.
    Either way it stays scoped to the one task that needed it: never copy a
    finding onto another entry, and never build a shared notes file. A
    sub-agent's context is small on purpose.
  - `STATUS: NOT FOUND`: it has escalated into a decision. Fall through to
    `(DECISION)`, with its report as context.
- **`BLOCKED (DECISION)`**: a judgment call the entry or plan doesn't settle.
  Put it to the user: the question, the candidate options, your
  recommendation named first. `AskUserQuestion` suits a closed set of
  options; prose suits anything that needs explaining. Getting the decision
  right matters more than finishing quickly.

Once settled, append the resolution to the task's file. Planning and
execution sub-agents read that file, so the answer must live there:

```bash
RADIN_CLI backlog append "<task id>" <<'EOF'
**Decision:** <the settled answer>
EOF
```

Same command, one label per kind of appended material: `**Decision:**` for a
settled judgment call, `**Fact:**` for a fact-finder's answer, `**Root
cause:**` for a diagnosis, `**Facts:** <path>` for the long form of any of
them. Every one of them is task-scoped.

Then treat the entry as `pending` and continue the loop.

If the user defers the decision, it cannot be had this session. Do not guess.
Mark the entry `blocked` with `set-status` (its signature is in the skill
body), `note` holding the question, the options, and the recommendation. Then
report `⏸️ Task <order> '<title>' deferred: <question>. Continuing to next
task.` and continue. Blocked entries surface in the Phase 5 summary, and
re-invoking the skill resumes them: append the decision first, then treat the
entry as `pending`.

A fully planned task leaves nothing to decide, and Step 4b implements the
plan without inventing choices. If execution still surfaces an unsettled
decision, ask or record it `blocked`. Never leave it hanging.

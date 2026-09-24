# Shared: radin-execute Blocked-Task Routing

`radin-execute` reads this file when a sub-agent reports `STATUS: BLOCKED`, at
any of the phases that can produce one.

A sub-agent's `STATUS: BLOCKED` always carries a `(FACT)` or `(DECISION)` tag.
Route on it:

- **`BLOCKED (FACT)`**: checkable, and the sub-agent already failed to verify
  it from the repo. Facts are never the user's job to hand over. Where the
  answer lives decides who goes after it.

  **Inside the working directory** — the repo, its lockfiles, its vendored
  dependencies, its config: dispatch a fresh sub-agent with
  `RADIN_CLI prompt factfind "<task id>" "<the question>"`, which prints a
  `model` and a `prompt` path to dispatch as Phase 4 does. It investigates read-only and reports in one
  turn. Holding more than one at once, every one of those dispatches goes in
  the same message, and each `STATUS: FOUND` is appended to its own task's
  file.

  **Outside the working directory** — third-party API or library behavior, a
  spec, a service's own reference: you invoke `/mattpocock-skills:research`
  yourself, once per question, all the invocations in the same message. This
  dispatch is yours rather than a sub-agent's: it needs no human and no
  working tree, a sub-agent cannot rely on a spawned agent's result, and you
  can — a backgrounded agent's result reaches you as a completion notification
  (Core Constraints). It asking you anything: drop it, never wait on it, and
  treat the question as `STATUS: NOT FOUND` below. Otherwise give it the
  question plus these two demands.

  - Investigate the question against **primary sources** — official docs,
    source code, specs, first-party APIs — not a secondary write-up of them.
    Follow every claim back to the source that owns it.
  - Write the findings to `<repo root>/.claude/.radin/state/facts/<task id>.md`, citing
    each claim's source.

  Then route its report exactly like a fact-finder's: an answer whose claims
  each name the source that owns them is `STATUS: FOUND`; one citing a
  secondary write-up, or nothing, is `STATUS: NOT FOUND`.

  - `STATUS: FOUND`: append the finding to that task's file with
    `backlog append` (labels below), record a reported `state/facts/<id>.md`
    path with `backlog set-meta`, and re-run the task (Phase 4).
    It stays scoped to the one task that needed it: never copy a
    finding onto another entry, and never build a shared notes file.
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
cause:**` for a diagnosis. The long form of any of them is a file the entry
points at, recorded with
`RADIN_CLI backlog set-meta "<task id>" facts "<path>"`. Every one of them is
task-scoped.

Then re-run the task (Phase 4).

If the user defers the decision, it cannot be had this session. Do not guess.
Mark the entry `blocked` with `set-status` (its signature is in
`radin-run.md`), `note` holding the question, the options, and the recommendation. Then
report `⏸️ Task <order> '<title>' deferred: <question>. Continuing to next
task.` and continue. Blocked entries surface in the Phase 5 summary, and
re-invoking the skill resumes them: append the decision first, then treat the
entry as `pending`.

A fully planned task leaves nothing to decide, and its execution sub-agent
implements the plan without inventing choices. If execution still surfaces an unsettled
decision, ask or record it `blocked`. Never leave it hanging.

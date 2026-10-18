# Shared: radin-batch Blocked-Task Routing

`radin-batch` reads this file when a sub-agent reports `STATUS: BLOCKED`, at
any of the phases that can produce one, and when `task-report` answers
`next clarify STUCK`.

A sub-agent's `STATUS: BLOCKED` always carries a `(FACT)` or `(DECISION)` tag.
Route on it:

- **`BLOCKED (FACT)`**: checkable, and the sub-agent already failed to verify
  it from the repo. Facts are never the user's job to hand over.

  **Inside the working directory.** This means the repo, its lockfiles, its vendored
  dependencies and its config. Dispatch a fresh sub-agent with
  `RADIN_CLI prompt factfind "<task id>" "<the question>"`, which prints a
  `model` and a `prompt` path to dispatch as Phase 4 does. With more than one, send every dispatch in
  the same message, and each `STATUS: FOUND` is appended to its own task's
  file.

  **Outside the working directory.** This means third-party API or library behavior, a
  spec, or a service's own reference. Invoke `/mattpocock-skills:research`
  yourself, once per question, all the invocations in the same message. If it
  asks you anything, drop it, never wait on it, and
  treat the question as `STATUS: NOT FOUND` below. Otherwise give it the
  question plus these two demands.

  - Investigate the question against **primary sources**, such as official docs,
    source code, specs and first-party APIs, not a secondary write-up of them.
    Follow every claim back to the source that owns it.
  - Write the findings to `<repo root>/.claude/.radin/state/facts/<task id>.md`, citing
    each claim's source.

  Then route its report exactly like a fact-finder's: an answer whose claims
  each name the source that owns them is `STATUS: FOUND`; one citing a
  secondary write-up, or nothing, is `STATUS: NOT FOUND`.

  - `STATUS: FOUND`: a fact-finder's line goes to
    `RADIN_CLI state task-fact "<task id>" "<the STATUS: line>"`, which appends
    the `**Fact:**` line with its token and records a reported
    `state/facts/<id>.md` path. A research report has no fixed line: append its
    finding with `backlog append` (labels below) and `backlog set-meta`. Then
    re-run the task (Phase 4).
    It stays scoped to the one task that needed it. Never copy a
    finding onto another entry, and never build a shared notes file.
  - `STATUS: NOT FOUND`: it has escalated into a decision. Fall through to
    `(DECISION)`, with its report as context.
- **`BLOCKED (DECISION)`**: a judgment call, a confirmation or a human action
  the entry or plan doesn't settle. Put it to the user: the question, the
  candidate options, your recommendation named first. A human action goes to
  the user as the action to take, and the result they report is what you
  append. `AskUserQuestion` suits a closed set of options; prose suits
  anything that needs explaining.
- **`clarify STUCK`**: the task ended with no commit and no tagged question
  (failed after its debug pass, inconclusive, a dirty tree, no `STATUS:`
  line, or `MAX_ATTEMPTS` reached). Put it to the user: the task, the reason
  from the report line (and the entry's `**Root cause:**` line when it has
  one; for a dirty tree, the stash recovery command in the entry's note), and
  the options: a hint or a different approach, a human action to perform, or
  defer this task. Name your recommendation first. Once settled, append the
  answer as a `**Decision:**` line (below), run
  `RADIN_CLI state answered "<task id>"`, then re-run the task (Phase 4).

Once settled, append the resolution to the task's file:

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
task-scoped. A hand-appended `**Fact:**` line keeps the `[measured]` or
`[inferred]` token of its source, copied after the label; a line with no token
is a guess.

Then re-run the task (Phase 4).

Deferral happens only when the user explicitly says so; silence, "not sure"
or an unrelated reply is asked again. A deferred entry keeps its
`failed`/`blocked` status (`set-status ... blocked` with a `note` that starts `deferred:` and holds the
question, the options and the recommendation, for an entry that has none).
Report `⏸️ Task <order> '<title>' deferred: <question>. Continuing to next
task.` and continue. Deferred entries surface in the Phase 5 summary, and
re-invoking the skill resumes them: append the decision first, then treat the
entry as `pending`.

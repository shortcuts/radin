# Shared: radin-batch Blocked-Task Routing

`radin-batch` reads this file when a sub-agent reports `STATUS: BLOCKED`. The
`(FACT)` or `(DECISION)` tag routes it:

- **`BLOCKED (FACT)`**: checkable, and the sub-agent already failed to verify
  it from the repo. Facts are never the user's job to hand over.

  **Inside the working directory** (repo, lockfiles, vendored dependencies,
  config). Dispatch a fresh sub-agent with
  <!-- host:claude -->
  `RADIN_CLI prompt factfind "<task id>" "<the question>"`, which prints a
  `model`, an optional `effort` and a `prompt` path to dispatch as Phase 4 does.
  <!-- /host -->
  <!-- host:agents -->
  `RADIN_CLI prompt factfind "<task id>" "<the question>"`, which prints an optional `model`, an optional `effort` and a `prompt` path to dispatch as Phase 4 does.
  <!-- /host -->
  Each `STATUS: FOUND` is appended to its own task's file.

  **Outside the working directory** (third-party API or library behavior, a
  spec, a service's own reference). Invoke `@@skill:research@@`
  yourself, once per question. If it asks you anything, drop it and treat the
  question as `STATUS: NOT FOUND` below. Otherwise give it the question plus
  these two demands.

  - Investigate the question against **primary sources**, such as official docs,
    source code, specs and first-party APIs, not a secondary write-up of them.
    Follow every claim back to the source that owns it.
  - Write the findings to `<repo root>/.radin/state/facts/<task id>.md`, citing
    each claim's source.

  Then route its report exactly like a fact-finder's: an answer whose claims
  each name the source that owns them is `STATUS: FOUND`; one citing a
  secondary write-up, or nothing, is `STATUS: NOT FOUND`.

  - `STATUS: FOUND`: a fact-finder's line goes to
    `RADIN_CLI state task-fact "<task id>" "<the STATUS: line>"`, which appends
    the `**Fact:**` line with its token and records a reported
    `state/facts/<id>.md` path. A research report has no fixed line: record its
    finding with `RADIN_CLI backlog fact "<task id>" <label> "<finding>" --long "<path>"`,
    where `<path>` is the `state/facts/<id>.md` file. Then re-run the task (Phase 4).
  - `STATUS: NOT FOUND`: fall through to `(DECISION)`, with its report as context.
- **`BLOCKED (DECISION)`**: a choice, a confirmation or a human action the
  entry or plan doesn't settle. `task-report` recorded the task
  `blocked`. **Park it:** append the question, report `⏸️ Task <order>
  '<title>' parked: <question>. Continuing to next task.`, and carry on with
  every other task and lane. Phase 5 asks it.

  ```bash
  RADIN_CLI backlog append "<task id>" <<'EOF'
  **Open decision:** <question>, <options>, <your recommendation>
  EOF
  ```

  **Ask now** only for irreversible work (force-push, deploy, data deletion,
  external messages): the question, the options, your recommendation first.
  The user's answer or reported result is what you
  <!-- host:claude -->
  append. `AskUserQuestion` suits a closed set of options; prose suits
  <!-- /host -->
  <!-- host:agents -->
  append. Your question tool suits a closed set of options; prose suits
  <!-- /host -->
  anything that needs explaining.

Once settled, append the resolution to the task's file:

```bash
RADIN_CLI backlog append "<task id>" <<'EOF'
**Decision:** <the settled answer>
EOF
```

`append` takes `**Decision:**` for a settled judgment call and `**Root
cause:**` for a diagnosis. `fact` takes a fact-finder's answer:
`RADIN_CLI backlog fact "<task id>" <measured|inferred|guess> "<the line>"`,
with the label the source gave. The long form is a file the entry points at, recorded with
`RADIN_CLI backlog set-meta "<task id>" facts "<path>"`; a `fact` call sets it
with `--long`. Each is task-scoped: never copy one onto another entry.

Then re-run the task (Phase 4).

Deferral happens only when the user explicitly says so; silence, "not sure"
or an unrelated reply is asked again. A deferred entry keeps its
`failed`/`blocked` status (`set-status ... blocked --reason deferred`, with a `note` holding
the question, options and recommendation when it has none).
Append `**Progress:** Deferred by the owner: <question>`, so `task-next` skips it.
Deferred entries surface in the Phase 5 summary, and
re-invoking the skill resumes them: append the decision first, then treat the
entry as `pending`.

## Settling Waiting Entries

Phase 0 and Phase 5 read this section for every `waiting` entry. Handle the entries whose reason is `deferred` apart from the
rest. Ask one yes/no question for all of them, per `RADIN_LIB/radin-ask-rule.md`:
"Should deferred entries remain deferred?" `Yes`: change nothing. `steps-init`
keeps each one `blocked`, so `task-next` and the lanes skip it and the run
selects the other backlog items. `No`: run `RADIN_CLI state answered "<task id>"`
for each, which returns it to `pending`.

Invoke `@@skill:grilling@@` once for the other `waiting` entries,
one question at a time, your recommendation first. Append each answer as
above, then run `RADIN_CLI state answered "<task id>"`. An entry the user
explicitly defers again keeps its `blocked` status and its `deferred` reason, and
gets `**Progress:** Deferred again by the owner: <question>`.

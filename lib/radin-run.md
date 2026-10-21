# Backlog Run

The shared body of `/radin-batch` and `/radin-do`.

You are a **router**: you prioritize the backlog, dispatch every
implementation step to a sub-agent, and record status. You never implement,
and `/radin-plan` is the planner: a task whose entry carries a plan pointer
goes to the sub-agent as-is, its approach already settled.

Your context is the session's budget. Hold the backlog at low resolution,
as ids, titles, order and exit codes, and leave every zoom to a sub-agent: a task
body, a plan file, a diff, and codebase exploration above all are what a leaf
reads and hands back as one `STATUS:` line.

You run in the user's own thread, so you can ask them and they can interrupt
you.

## Core Constraints

- **Claude Code decides foreground or background**, so send every `Agent` call
  with no `run_in_background`. A backgrounded leaf's result reaches you as a
  completion notification in a later turn: wait for it, then report that task's
  outcome. A task reaches its **terminal status** only when `state task-report`
  records one on disk, so a dispatch that hands back nothing leaves it
  unfinished: its `attempts` is already bumped, and Phase 1's stuck-recovery
  owns it next run.
- **The user's answers are binding.** Carry each one forward exactly as given:
  the task selection, the worktree and branch preferences, and the
  concurrency rule below are decisions, not hints. This holds most for a `no`.
  Nothing you find later revises one, not a task file, not a plan, not a leftover
  `radin/<id>` branch.
  Leaving the task undone is the better outcome. The worktree/branch pair is enforced for you: it lives in
  `session.json`, and `RADIN_CLI state prepare` is the only thing that turns
  it into git commands. Never substitute either answer into a sub-agent prompt
  and never name a tree for a sub-agent: `prepare` reads `session.json` and
  decides.
- **The execution order is not confirmed.** `backlog order` computes it and
  Phase 2 prints it. The user is asked only which tasks to tackle now, and
  for any worktree or branch answer still missing, before anything is written
  to `BACKLOG_STEPS.json` and before any sub-agent is dispatched.
- **Read-only dispatches get no worktree.** Planning, refining, fact-finding and
  debugging sub-agents write no repo code and no shared file, so they never
  call `RADIN_CLI state prepare`, whatever Phase 0.5 recorded. Several
  fact-finding or debugging dispatches due at once go out as one message.
- **Phase 0.5's worktree answer sets execution concurrency.** `yes`: execution
  sub-agents whose `task-next` `overlap` line reads `none` may go out in one
  message, since each lands in its own tree. Any other `overlap` value, or
  `no`: dispatch the task alone. Wait for every outstanding sub-agent's
  `STATUS:` line and `task-report`, dispatch it, and wait for its own report
  before the next `task-next`. Parallel agents in one checkout corrupt each
  other's commits. Each task still gets its own `task-next`, its own dispatch,
  and its own `task-report`.

## Clarifying Ambiguity

A sub-agent's `STATUS: BLOCKED` routes through
`RADIN_LIB/radin-batch-clarify.md`: read it and follow it. It holds
the routing for both tags, the fact-finder handoff, the research arm for a
fact that lives outside this repo, and the `backlog append` labels that put a
settled answer where planning and execution sub-agents read it.

Every status change this skill makes goes through one command, and this is its
only signature:

```bash
RADIN_CLI state set-status "<task id>" <pending|in_progress|failed|blocked> "<note>"
```

The `note` is a single shell argument, so quote it whole however many
sentences it holds.

---

## Phase 0: Resolve Project Namespace

`RADIN_CLI backlog` and `RADIN_CLI state` own every radin state file. Never
hand-edit one, and never parse one to decide what to do next.
Every `RADIN_CLI` call resolves the namespace from the current directory, so
no call takes a path. Verify a backlog exists:

```bash
RADIN_CLI backlog count
```

On a non-zero count, continue to Phase 0.5. A count of `0` is not a
stop here. Phase 1 step 1 owns that branch.

## Phase 0.5: Worktree/Branch Preference

Two answers govern where every task's work lands: own git worktree per task,
and own branch per task. They are recorded once per repo in
`state/session.json`. Read the recorded answers first:

```bash
RADIN_CLI state session-get
```

Exit 0 prints `worktree<TAB><yes|no>` and `branch<TAB><yes|no>`: the repo has
already answered, so ask nothing and change nothing. A mid-run change would
land half the tasks in worktrees and half in the checkout. Exit 1
means no answer
is recorded yet, which happens only on the first run in a repo. Read
`RADIN_LIB/radin-batch-session.md` and follow it to ask and
persist them.

## Phase 1: Read and Prioritize

1. If Phase 0's `backlog count` printed `0`: tell the user and ask whether to
   create an empty backlog or stop. Those are the only two outcomes. An empty
   backlog ends the run: report it and stop.
2. Reconcile against completed work. A run that died between recording
   success and removing the entry leaves a finished task in the backlog:

   ```bash
   RADIN_CLI backlog reconcile
   ```

   No-op when there is nothing stale. If reconcile emptied the backlog,
   report and stop per step 1.
3. Recover tasks an interrupted run left mid-flight:

   ```bash
   RADIN_CLI state stuck
   ```

   Exit 1: nothing to recover, continue to step 4. Exit 0 prints one
   `id<TAB>attempts<TAB>note` line per task a previous run dispatched and
   never got a terminal status for. Never re-dispatch one blind. Read
   `RADIN_LIB/radin-batch-recovery.md` and follow it for
   each id. Most runs skip this file entirely.
4. Settle the questions a previous run left open. `steps-init` rewrites
   `BACKLOG_STEPS.json` in Phase 3, so a waiting entry that stays unanswered
   restarts without its decision:

   ```bash
   RADIN_CLI state steps-waiting
   ```

   Exit 1: nothing waits, continue to step 5. Exit 0 prints the id of each
   entry that holds an unanswered question. Read each entry's `note` with
   `RADIN_CLI state steps-list`. Invoke `/mattpocock-skills:grilling` once for
   all of them, one question at a time, your recommendation first. Append each
   answer per `RADIN_LIB/radin-batch-clarify.md`, then run
   `RADIN_CLI state answered "<task id>"`. An entry the user explicitly defers
   again keeps its `blocked` status and its `deferred:` note.

5. Ask the CLI whether a ranking pass is needed at all:

   ```bash
   RADIN_CLI backlog order --rank-needed
   ```

   Exit 1: every entry carries a priority. Read no task body, run no criteria
   pass, infer no dependency. Go to Phase 2. Exit 0: it printed the ids
   whose `priority` is unset. Read
   `RADIN_LIB/radin-prioritization.md` and apply its weighted
   criteria to those ids alone. It produces two things: the unset group in
   your order, as one `--rank <csv-of-ids>` flag, and one
   `--infer-deps <id>=<csv>` flag per entry you inferred a dependency for.
   Carry those flags into every later `order` call this session; carry
   nothing else.
6. Resolve the **scope**, only when the invoking prompt names one (an epic id,
   a task id or a task title). No name, no scope: skip this step.

   ```bash
   RADIN_CLI backlog scope "<name>"
   ```

   Exit 0: line 1 is `ids<TAB><csv>`, the scope with every transitive
   dependency. Keep that csv as the scope. Line 2, when present, is
   `dependencies<TAB><csv>`, the tasks the closure added. Exit 1 or 2: show the
   user `RADIN_CLI backlog epics` and any `candidate` lines, and ask which one
   they meant, via one `AskUserQuestion`. Never guess.

## Phase 2: Print Order, Select Tasks

Phase 0.5's preferences and the scope from Phase 1 step 6 are the only
questions a prompt may pre-answer.

1. Print this verbatim, and compose nothing of your own:

   ```bash
   RADIN_CLI backlog order --report <Phase 1's --rank/--infer-deps flags>
   ```

   One `<order>. <title> (id: <id>)` line per task in final order, then one
   `dependency override:` line per dependency the fix moved up. The verb is
   idempotent, so re-run it here rather than reusing Phase 1's output.
2. Ask via one `AskUserQuestion` call with fixed choices:
   - **Task selection** (unless Phase 1 resolved a scope): "Which
     tasks now?" Options: `All of them` /
     `Only the ones I name` / `Just the first one`. `Only the ones I name`
     defers the rest without changing the order of the others; its free text
     names them ("only 1 and 3", or "do not tackle 5 and 6 now").
   - **Worktree** (if Phase 0.5 unanswered): "Own git worktree per task?"
     Options: `Yes` / `No`.
   - **Branch** (if Phase 0.5 unanswered): "Own branch per task?" Options:
     `Yes` / `No`. Its meaning and wording: `RADIN_LIB/radin-batch-session.md`.
   Write nothing to `BACKLOG_STEPS.json` and launch no sub-agent before the
   answer arrives.
3. The answers are routed independently, and each is routed once.
   - **Task selection** decides Phase 3's selection flag, and nothing else:
     - **A scope from Phase 1**: `--only <the scope csv>`. Name the scope, the
       dependencies it pulled in, and the deferred count in the run summary, so
       the user sees what the run adds and leaves out.
     - **All of them**: no flag.
     - **Just the first one**: `--first`.
     - **Only the ones I name** (or "Other" text): read the selection off the
       free text (order numbers, titles, or ids). Resolve each to a task id,
       and if any reference is ambiguous, ask again rather than guessing which
       task the user meant. `--only <the named ids>`.

## Phase 3: Persist Execution Plan

The order is persisted by exactly this pipe:

```bash
RADIN_CLI backlog order --steps <Phase 1's flags> <Phase 2's selection flag> |
  RADIN_CLI state steps-init
```

Omit the selection flag when Phase 2 chose all of them. Resolving free text
to ids is yours; the deferred set, renumbering and the `depends_on` precedence are not. Every listed
task keeps the `order` number the report printed.

## Phase 3.5: Refine

The selected tasks' open decisions are settled now, so execution runs without
the user. Read the selected ids:

```bash
RADIN_CLI state steps-list
```

For each `pending` line, run `RADIN_CLI prompt refine "<task id>"`, which prints
a `model` and a `prompt` path. Dispatch every one in a single message as a
read-only dispatch (it records no `task-report`), `name:
"radin-refine-<task id>"`, with the Phase 4 dispatch text. Collect every
`STATUS: BLOCKED (DECISION)` line, none from a `STATUS: REFINED — none`. A
reply with no `STATUS:` line counts as none, because execution still blocks on
a decision it meets.

No question left: go to Phase 4. Otherwise invoke
`/mattpocock-skills:grilling` and settle them as Phase 1 step 4 does. A question the user explicitly defers
stays unsettled: append it as an open decision in the entry body, options and
recommendation included, so the leaf blocks on it. Continue to Phase 4.

## Phase 4: Task Execution Loop

One call does everything between two dispatches: it picks the next
**frontier** task (pending, unblocked), checks the entry still exists, claims
it, and writes its prompt to a file. The frontier is the CLI's to compute,
never yours:

```bash
RADIN_CLI state task-next
```

Exit 1 means nothing is left to run, so go to Phase 4.5. Exit 0 prints, in
order:

- zero or more `blocked<TAB><id><TAB><why>` lines for tasks it skipped (an
  unresolved dependency, an entry the backlog lost, `MAX_ATTEMPTS` reached).
  It already marked each one `blocked`. Report each as skipped. The entry stays on the backlog with a `**Progress:**` note, and any work is a wip commit.
- `id`, `order`, `kind`, `model` and `prompt` lines for the task to run now,
  then, for an `execution` task, an `overlap` line: `none`, `unclear`, or the
  ids of live tasks sharing its plan files or a `depends_on` edge.

`kind` is `planning` for an entry radin-record flagged as needing a plan that
has none yet, else `execution`. A `planning` dispatch that reports
`STATUS: PLANNED` skips `task-report`. A planning leaf with no `STATUS:` line goes in as `--no-status` like any other; it retries until `MAX_ATTEMPTS`, then `task-next` blocks it. Re-run `task-next "<task id>"`, which
now hands out its execution prompt. `STATUS: BLOCKED (FACT|DECISION)`
routes per Clarifying Ambiguity. Dispatch the prompt as one
`Agent` call with exactly that model, `name: "radin-<kind>-<task id>"`
(`kind` is `planning`, `execution`, `debug`, `factfind` or `refine`), and this text,
and nothing else. The name lets a usage report show which task and role cost
the most:

```
Read <the prompt path> and follow it.
```

Dispatch under the concurrency rule in Core Constraints. An `execution`
task is already claimed, so Phase 1 step 3's stuck-recovery sees it if the
session dies.

When the sub-agent reports, hand its last line to one call. It verifies the
tree first (a dirty tree fails the task, whatever the `STATUS:` claimed), then
records the terminal state and prints the report line:

```bash
RADIN_CLI state task-report "<task id>" "<the sub-agent's STATUS: line>" --next
```

Two dispatches hand back no such line. A last line that is not a `STATUS:`
line, because the agent asked something, hit an interactive skill, or died mid-turn, goes
in as `--no-status "<its final line>" --next` instead, an API or network error text
included: the CLI sends that task back for a retry. A sub-agent with no content at
all is still working, whatever the elapsed time suggests. Wait, and if your
turn ends first, leave the entry `in_progress` for Phase 1's stuck-recovery.

When the dispatch's completion notification carries a usage block (total tokens,
tool uses, duration in ms), add `--usage "<kind> <tokens> <tool_uses> <duration_ms>"`
to that task's next `task-report` call, `kind` being `planning`, `execution`,
`debug` or `factfind` for the dispatch that produced it. A debug or fact-finder
dispatch's usage rides on the re-run's `task-report`, one `--usage` per dispatch.
No usage block, no flag; a synchronous result's `totalTokens` counts only the
final request, so it never supplies the number.

Your whole message to the user about this task is the call's report: every line above its `next` line, copied verbatim. Then route on that `next` line. A re-run names the task: `task-next "<task id>"`
claims it again and bumps `attempts`, so the cap still ends it.

| `next` | Do |
| --- | --- |
| `continue` | Recorded on disk, and the lines after it are `task-next`'s output for the next task: report any `blocked` lines, then dispatch it as above. Exit 1 after `next continue` means nothing is left, so go to Phase 4.5. |
| `debug` | This task still has its one debug pass. `RADIN_CLI prompt debug "<task id>" "<the reason from the STATUS: line>"` prints a `model` and a `prompt` path: dispatch it the same way. `STATUS: DIAGNOSED`: record it as below, then re-run the task. `STATUS: NOT DIAGNOSED`: re-run `task-report` with the same line and `--next`, which records the failure on the entry and returns `continue`. |
| `clarify FACT` / `clarify DECISION` | Route per Clarifying Ambiguity. Once settled, re-run the task. |

```bash
RADIN_CLI state task-diagnosis "<task id>" "<the STATUS: DIAGNOSED line>"
```

A task report is not a stopping point: send it in the same message as the
next task's dispatch and carry on. The loop stops only at a
`clarify` waiting on the user, Phase 4.5, or Phase 5.

Never verify a `SUCCESS` yourself: no per-task verification sub-agent, and no
re-reading the diff. That read is the cost the leaf's own verify loop and
Phase 4.5's gate exist to avoid. A task is finished when `task-report` has recorded it,
whatever the sub-agent's prose said.

An entry stays `failed` or `blocked` only after the user explicitly deferred
it. A deferred entry is not retried within this session, and does not block
the loop from reaching Phase 4.5.

## Phase 4.5: Session Gate

Execution sub-agents run only the checks their diffs reached, so the whole
suite runs here once, every session. Skip it when the session recorded no
commit.

Read `RADIN_LIB/radin-batch-gate.md` and follow it to dispatch the gate.

## Phase 5: Final Summary

Always runs once the loop exits, and the CLI prints it whole:

```bash
RADIN_CLI state report
```

Print its output verbatim. Read
`RADIN_LIB/radin-batch-reporting.md` for the two things it
cannot do.

## Phase 6: Review

- **The user asked for a post-session review** (in the invoking prompt or
  once the summary is out): read `RADIN_LIB/radin-batch-review.md` and follow
  it.
- **They didn't**: no review. Close the summary with `To review this
  session's work, run /radin-review with scope: <the output of RADIN_CLI state
  session-commits>.`

## Additional Guardrails

- **Resume, and recovery after a compaction**: `BACKLOG_STEPS.json` already
  exists at startup, or earlier turns got summarized away. Either way, read
  `RADIN_LIB/radin-batch-resume.md` and follow it. It holds
  the resume triage, the `MAX_ATTEMPTS` exception, and the state-persistence
  contract that lets you continue from disk rather than memory. A run that
  starts clean and stays in context never loads it.
- **Every commit traces to a backlog entry.**

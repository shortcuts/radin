---
name: radin-execute
description: |
  Work through a project's whole backlog: prioritize every task, execute each
  via a sub-agent, commit after each. Use when the user wants the entire
  backlog processed ("work through my backlog"), not one named task.
  Delegates all implementation to sub-agents; clarifies ambiguity by asking
  the user rather than guessing.
---
# Backlog Execution

You are a router. You prioritize the backlog, delegate every implementation
step to a sub-agent, and record status. You never implement, and you never
plan a task's approach yourself: `/radin-plan` is the planner. A task with a
`**Plan:**` pointer goes to the sub-agent as-is; do not re-derive its
approach.

Normally you run in the user's own thread: you can talk to them, and they can
interrupt you. Every sub-agent you dispatch is a leaf worker — it keeps its
own reading and editing out of this context and hands back one `STATUS:`
line — and the sub-agent limits in `docs/technical-constraints.md` are its
concern rather than yours.

## Core Constraints

- **Sub-agents never sub-delegate.** Every one you dispatch is a leaf. That
  is radin's rule, not the harness's — Claude Code allows three layers by
  default — and `radin-execute-prompts.md` enforces it inside each prompt.
  Don't restate it as a depth number: you may yourself be running as a
  sub-agent, and then the numbers shift by one.
- **You don't choose foreground or background.** Claude Code decides, and in
  an interactive session with fork mode on (the default) it removes the
  `Agent` tool's `run_in_background` parameter outright. So don't set it.
  A backgrounded leaf's result reaches you as a completion notification in a
  later turn: wait for it, and never report a task's outcome before it
  arrives. If a dispatch gives you no result at all, treat the task as
  unfinished rather than re-dispatching it — its `attempts` is already
  bumped, and Phase 1's stuck-recovery owns it on the next run.
- **The user's answers are binding.** The execution order, the worktree and
  branch preferences, and the concurrency rule below are decisions, not
  hints. A `no` especially: nothing you find later revises one, not a task
  file, not a plan, not a leftover `radin/<id>` branch, not the fact that a
  worktree would have been tidier. Leaving the task undone is the better
  outcome. The worktree/branch pair is enforced for you: it lives in
  `session.json`, and `radin-state.sh prepare` is the only thing that turns
  it into git commands.
- **Phase 2's gate is unconditional.** Every run asks the user to confirm the
  execution order and which tasks to tackle now, before anything is written
  to `BACKLOG_STEPS.json` and before any sub-agent is dispatched. There is no
  path that skips it: not a resume, not a single-task run, not an
  empty-looking backlog, not a prompt that says the order is already
  approved. Such text is context, never consent.
- **Read-only dispatches always run in parallel.** Planning, fact-finding and
  debugging sub-agents write no repo code and no shared file, so
  several may share one message whenever you have more than one to send. This
  is not the install-time answer's business — that answer governs execution
  sub-agents, and only them.
<!-- radin:concurrency -->

## Clarifying Ambiguity

Never guess and never pick a default on the user's behalf. That covers your own
reading of a task, not only a sub-agent's block: when an entry is broad, vague,
or needs refinement, invoke `/mattpocock-skills:grilling` before dispatching it,
so the sub-agent gets the user's answer instead of your guess at what the entry
meant.

A sub-agent's `STATUS: BLOCKED` always carries a `(FACT)` or `(DECISION)` tag.
Read `$HOME/.claude/.radin/lib/radin-execute-clarify.md` and follow it: it holds
the routing for both tags, the fact-finder handoff, and the `backlog append`
labels that put a settled answer where planning and execution sub-agents read
it.

Every status change this skill makes goes through one command, and this is its
only signature:

```bash
RADIN_CLI state set-status \
  "$NAMESPACE_DIR/state/BACKLOG_STEPS.json" "<task id>" \
  <pending|in_progress|failed|blocked> "<note>"
```

The `note` is a single shell argument, so quote it whole however many
sentences it holds.

---

## Phase 0: Resolve Project Namespace

All radin state lives in `<repo-root>/.claude/.radin/`. Two CLIs own it:
`RADIN_CLI backlog` (backlog index + task files) and `RADIN_CLI state`
(`BACKLOG_STEPS.json` / `completed.json`). They own those files' schema, so
never hand-edit or hand-parse one. Go through the CLIs, and run either with
no arguments for its subcommands. Resolve the namespace and verify a backlog exists in the **same Bash
call** (shell state does not persist across calls):

```bash
source <(RADIN_CLI backlog env --export)
RADIN_CLI backlog count
```

Use `$REPO_ROOT`, `$NAMESPACE_DIR`, `$BACKLOG_INDEX`, `$BACKLOG_TASKS_DIR`
thereafter, and re-run the `source` line in any later Bash call that needs
them. On a non-zero count, continue to Phase 0.5. A count of `0` is not a
stop here: Phase 1 step 1 owns that branch.

## Phase 0.5: Worktree/Branch Preference

Two answers govern where every task's work lands: own git worktree per task,
and own branch per task. They are recorded once per repo in
`state/session.json`. Each execution sub-agent runs `radin-state.sh prepare`
in Step 4b, and that command is the only thing that acts on them. Your only
job here is to make sure the file exists before Phase 4 dispatches anything,
so you never hand a sub-agent an answer of your own. Read the recorded answers
first:

```bash
RADIN_CLI state session-get "$NAMESPACE_DIR"
```

Exit 0 prints `worktree<TAB><yes|no>` and `branch<TAB><yes|no>`: the repo has
already answered, so ask nothing and change nothing. A mid-run change would
land half the tasks in worktrees and half in the checkout. Nothing else needs
the values: `prepare` and Phase 5's report read them back themselves. Exit 1
means no answer
is recorded yet — only the first run in a repo — so read
`$HOME/.claude/.radin/lib/radin-execute-session.md` and follow it to ask and
persist them.

## Phase 1: Read and Prioritize

1. If `$BACKLOG_INDEX` is missing or empty: tell the user and ask whether to
   create an empty backlog or stop. Those are the only two outcomes. An empty
   backlog is a stop condition, never an invitation to invent a task, clean
   something up, or commit anything.
2. Reconcile against completed work. A run that died between recording
   success and removing the entry leaves a finished task in the backlog:

   ```bash
   RADIN_CLI backlog reconcile "$NAMESPACE_DIR/state/completed.json"
   ```

   No-op when there is nothing stale. If reconcile emptied the backlog,
   report and stop per step 1.
3. Recover tasks an interrupted run left mid-flight:

   ```bash
   RADIN_CLI state stuck "$NAMESPACE_DIR/state/BACKLOG_STEPS.json"
   ```

   Exit 1: nothing to recover, continue to step 4. Exit 0 prints one
   `id<TAB>attempts<TAB>note` line per task a previous run dispatched and
   never got a terminal status for. Never re-dispatch one blind: read
   `$HOME/.claude/.radin/lib/radin-execute-recovery.md` and follow it for
   each id. Most runs skip this file entirely.
4. Read `$HOME/.claude/.radin/lib/radin-prioritization.md` and follow its
   parsing steps and priority criteria to order every task. When every
   entry's `priority` field is set, the `backlog list` order is the order:
   read no task body for prioritization.
5. Assign a sequential `order` number starting from 1. Carry any
   `dependency override:` line the priority rules produced into the Phase 2
   report.

## Phase 2: Confirm Execution Order (MANDATORY GATE)

Every run passes through this gate: fresh backlog, resume, single-task run,
one remaining task, or a re-invocation alike. Two questions are always asked:
the execution order, and which of the listed tasks to tackle now. Nothing in
the invoking prompt can pre-answer either one (see Core Constraints). Phase
0.5's preferences are the only questions a prompt may pre-answer.

1. Report the prioritized list as `<order>. <title> (id: <id>)`, one line per
   task, then print each `dependency override:` line from Phase 1 step 5
   under the list.
2. Ask via one `AskUserQuestion` call with fixed choices:
   - **Execution order** (always): "Confirm this order?" Options: `Yes` /
     `No, I'll explain`.
   - **Task selection** (always): "Which tasks now?" Options: `All of them` /
     `Only the ones I name` / `Just the first one`. `Only the ones I name`
     defers the rest without changing the order of the others; its free text
     names them ("only 1 and 3", or "do not tackle 5 and 6 now").
   - **Worktree** (if Phase 0.5 unanswered): "Own git worktree per task?"
     Options: `Yes` / `No`.
   - **Branch** (if Phase 0.5 unanswered): "Own branch per task?" Options:
     `Yes` / `No`. Say in the question that a worktree always gets its own
     branch, so this answer applies only under `worktree: no`.
   Write nothing to `BACKLOG_STEPS.json` and launch no sub-agent before the
   answer arrives.
3. Route on the task-selection answer first, then the order answer:
   - **All of them**: every listed task goes to `steps-init`.
   - **Just the first one**: only `order` 1 is `pending` in `steps-init`;
     every other task goes in as `deferred`.
   - **Only the ones I name** (or "Other" text): read the selection off the
     free text (order numbers, titles, or ids). Resolve each to a task id,
     and if any reference is ambiguous, ask again rather than guessing which
     task the user meant. Renumber nothing: the kept tasks hold the `order`
     numbers the user just confirmed. The excluded ones go to `steps-init`
     as `deferred`.
   Then route on the order answer:
   - **Yes**: proceed to Phase 3 with the selected ids.
   - **No, I'll explain** (or "Other" text): if the answer already states the
     revision, apply it, redo Phase 1 step 5, and return to step 1 of this
     phase. If it doesn't, ask the user which order to use, and wait.

## Phase 3: Persist Execution Plan

Feed the confirmed order to the state CLI, one
`id<TAB>order<TAB>depends-on-csv<TAB>status` line per **listed** task,
deferred ones included. Pass the backlog index too: the CLI reads each
entry's `depends_on` from its index line, so the third field stays empty for
any entry that already has one there. It carries only deps the ranking pass
inferred for an entry the index has none for. The fourth field is `pending`
for a task Phase 2 selected and `deferred` for one the user excluded — that
is where the deferred set is persisted, so nothing has to carry it to Phase
5.

```bash
RADIN_CLI state steps-init "$NAMESPACE_DIR/state/BACKLOG_STEPS.json" "$BACKLOG_INDEX" <<'EOF'
<id> <order> <inferred depends_on ids, comma-separated; empty when none> <pending|deferred>
EOF
```

The CLI writes the schema itself (empty `note`) and records this session's
baseline counts, which Phase 5's report reads.

## Phase 4: Task Execution Loop

Read `$HOME/.claude/.radin/lib/radin-execute-prompts.md` once now. It holds
every verbatim sub-agent prompt this phase sends: planning, execution,
debugging.

The state CLI picks each task, dependency gate included:

```bash
RADIN_CLI state task-next "$NAMESPACE_DIR"
```

Exit 1 means nothing is left to run, so go to Phase 5. Exit 0 prints, in
order:

- zero or more `blocked<TAB><id><TAB><why>` lines — tasks it skipped because
  a dependency is unresolved. It already marked each one `blocked` with that
  note; report each as skipped.
- `id<TAB><id>` and `order<TAB><n>` for the task to run now.
- zero or more `dep<TAB><id><TAB><commit hash>` lines. Keep the pairs: Step
  4b forwards them so the sub-agent can check whether a dependency's actual
  changes diverged from what this task's plan assumed.

### Step 4a: Ensure a plan exists

Confirm the entry still exists (the backlog may have drifted since Phase 3):

```bash
RADIN_CLI backlog find "<task id>"
```

Zero matches (it errors) or several: mark the task `blocked` with the CLI's
output as its `note` and continue to the next task. Exactly one: the task's
file is the path `RADIN_CLI backlog path "<id>"` prints — read from the
index's own `file` field, never composed, and it never goes stale.

Check for existing plan and skill pointers:

```bash
RADIN_CLI backlog meta "<task id>"
```

It prints one `plan<TAB><path>` line per `**Plan:**` pointer and one
`skill<TAB><instruction>` line per `**Skill:**` line, and one
`acceptance<TAB><criterion>` line per criterion under a `**Acceptance:**`
label. Any `plan` line: skip
to Step 4b (keep the `skill` lines). None: is this a single obvious change
(clear-root-cause bug fix, one-file tweak, mechanical rename)?

- **Straightforward**: skip planning; the sub-agent implements directly from
  the entry text.
- **Needs a plan** (multiple files, structural choice, ambiguous scope):
  delegate planning. Never run `/radin-plan` in this context, because its
  codebase exploration is the biggest context bloat a router can take on; the
  plan file on disk is the only handoff needed. Send the **Planning prompt**
  from `radin-execute-prompts.md`, replacing `TASK_ID`.
  - `STATUS: PLANNED`: proceed to Step 4b.
  - `STATUS: BLOCKED (FACT|DECISION)`: route per Clarifying Ambiguity, then
    retry Step 4a.

### Step 4b: Execution sub-agent

Claim the task on disk before you dispatch it. A session that dies mid-task
must be recoverable by Phase 1 step 3, which only sees what this records:

```bash
RADIN_CLI state start "$NAMESPACE_DIR/state/BACKLOG_STEPS.json" "<task id>"
```

Exit 0 prints `attempts<TAB><n>`. Exit 2 means the task has been dispatched
`MAX_ATTEMPTS` times without ever reaching a terminal status; the CLI already
marked it `blocked`. Report it and continue to the next task. Do not retry.

Only if Step 4a dispatched the planning sub-agent, re-run
`radin-backlog.sh meta "<task id>"` to pick up the plan it wrote. Otherwise
reuse Step 4a's output: nothing since then can have changed it.
Dispatch under the concurrency rule in Core Constraints. It decides whether
this task's `Task` call may share a message with another's. Send the
**Execution prompt** from `radin-execute-prompts.md`, substituting:

- `TASK_FILE`: the path `RADIN_CLI backlog path "<id>"` prints
- `PLAN_PATHS`: the `plan` paths in printed order, or "none — implement
  directly from the entry" if Step 4a skipped planning
- `CATEGORY`: the entry's category from Step 4a's `find` line. It picks which
  discipline skill the sub-agent implements through, so pass it verbatim and
  never substitute your own read of the task's shape.
- `NAMESPACE_DIR`: `$NAMESPACE_DIR`, and `TASK_ID`: the task's id. The
  sub-agent passes both to `radin-state.sh prepare` to get its working tree.
  Never substitute the worktree/branch answers themselves, and never tell the
  sub-agent which tree to use: `prepare` reads `session.json` and decides.
- `SKILLS`: the `skill` instruction(s), or "none". These are standing
  instructions from the user (`radin-record` captured them), so pass them
  through as-is; never second-guess whether one is needed, redundant, or a
  good fit. Drop exactly four classes, never on your own read of fit
  (`docs/technical-constraints.md` has the why for each):
  - it asks the user and waits (`/mattpocock-skills:grilling`),
  - it spawns its own agent or background task and waits
    (`/mattpocock-skills:research`),
  - it launches a workflow (`/deep-research`, any saved workflow command from
    `.claude/workflows/` or `~/.claude/workflows/`),
  - it is a radin entry point that would recurse (`/radin-execute`, and
    `/radin-plan` or `/radin-review`, which the planning and Phase 6
    dispatches own instead).
  Forward every other skill, and name each dropped one in the Phase 5 summary
  so the user can run it themselves.
- `ACCEPTANCE`: substituted exactly as the prompt file's own `ACCEPTANCE`
  narration specifies, the no-criteria case included.
- `DEPENDS_ON`: the `dep` pairs `task-next` printed as `<id>: <commit hash>`,
  or "none"

When the sub-agent reports, its `STATUS:` line drives what happens next,
never your own read of the surrounding prose. But first, verify the tree the
sub-agent actually worked in — the CLI resolves it, stashes it and fails the
task if it is dirty, whatever the `STATUS:` said:

```bash
RADIN_CLI state dirty-recover "$NAMESPACE_DIR" "<task id>" "<STATUS value>"
```

Exit 0: it printed the finished report line, so print that and continue to
the next task. Exit 1: the tree is clean, so route on `STATUS:`:

- **`SUCCESS`**: note the commit hash (or the pre-existing hash it cites),
  then run the bookkeeping command now, not deferred to Phase 5, since a stop
  can prevent Phase 5 from running. It validates the hash, records it in
  `completed.json`, removes the backlog entry, and removes the
  `BACKLOG_STEPS.json` line, in crash-safe order:

  ```bash
  RADIN_CLI state task-done "$NAMESPACE_DIR" "<task id>" "<commit hash>"
  ```

  Report: `✅ Task <order> '<title>' complete. <STATUS detail>. Remaining: <count>.`
  Exit 3 means the hash is not a commit reachable from the task's branch, so
  the `SUCCESS` is unsupported: treat it as `FAILED` below, with the CLI's
  message as the reason.

  Never verify a `SUCCESS` yourself: no verification sub-agent, and no
  re-reading the diff — that read is the cost Phase 6's `/radin-review` pass
  exists to avoid.
- **`BLOCKED (FACT)` / `BLOCKED (DECISION)`**: route per Clarifying
  Ambiguity. Once settled, re-run this task from Step 4a.
- **`FAILED`**: hand the reason to the CLI, which decides whether this task
  still has a debug pass left:

  ```bash
  RADIN_CLI state task-fail "$NAMESPACE_DIR" "<task id>" "<reason from the STATUS: line>"
  ```

  Exit 3 means diagnose first — a retry carrying no new information fails the
  same way and burns another attempt — so send the **Debug prompt** from
  `radin-execute-prompts.md`, substituting `FAILURE` with the reason.
  - `STATUS: DIAGNOSED`: record it, then re-run this task from Step 4b.
    `start` bumps `attempts` again, so the cap still ends it.

    ```bash
    RADIN_CLI state task-diagnosis "$NAMESPACE_DIR" "<task id>" <<'EOF'
    <the diagnosis>
    EOF
    ```

  - `STATUS: NOT DIAGNOSED`, or the task fails again after a diagnosis: run
    `task-fail` again with the reason. It exits 0 this time, having marked
    the entry `failed` with the note, and prints the report line.
- **A report that has no `STATUS:` line** (it asked something, hit an
  interactive skill, or died): no debug pass, straight to failed —
  `RADIN_CLI state task-fail "$NAMESPACE_DIR" "<task id>" --no-status "<its
  final line>"`, then print its line. Never re-read its prose for intent and
  never re-dispatch it in this turn. The task keeps its bumped `attempts`, so
  the cap still applies.
- **No report yet.** Not the same thing, and never `FAILED`: the sub-agent is
  still working, and marking it failed while it is mid-edit sets you racing
  its commit with the next task's `prepare` and Phase 5's `dirty-check`.
  Wait. If your turn ends first, leave the entry `in_progress` and stop —
  Phase 1's stuck-recovery is built for exactly this, and re-invoking picks
  it up.

### Step 4c: Repeat

Re-run `task-next`. Exit 0: process that task. Exit 1: go to Phase 5.
Failed, blocked and deferred entries stay in the file for the user to retry
or decide later. They are not retried within this session, and never block the loop
from reaching Phase 5.

Every task's state is durable the moment it lands (Step 4b's
`task-done`/`task-fail`/`dirty-recover` calls), so an interruption here costs nothing: the
user can stop you at any point and re-invoke to resume, and completed tasks
are never redone. Long backlogs are fine to run straight through.

## Phase 5: Final Summary

Always runs once the loop exits. It is the one place the user learns what
needs manual attention or a decision, and the CLI prints it whole:

```bash
RADIN_CLI state report "$NAMESPACE_DIR" "<one dropped-skill line per skill Step 4b dropped>"
```

Print its output verbatim — it already holds the residual-changes check, the
where-did-commits-land lines, this session's commits, and every `failed`,
`blocked` and `deferred` entry with its note. Read
`$HOME/.claude/.radin/lib/radin-execute-reporting.md` for the two things it
cannot do.

## Phase 6: Review

- **The user asked for a post-session review** (in the invoking prompt or
  once the summary is out): dispatch the reviewer sub-agent below and report
  its outcome.
- **They didn't**: no review. Close the summary with `To review this
  session's work, run /radin-review with scope: <commit hashes recorded in
  Phase 4>.`

Reviewer sub-agent (`model: "RADIN_MODEL_REVIEW"`). The
`radin-review` skill already owns the review-and-log flow, so send exactly:

```
Invoke the `/radin-review` skill with scope: the commit(s) made this session
(<list of commit hashes recorded in Phase 4>), plus any review instructions
from the invoking prompt: <instructions, or "none">.
```

## Additional Guardrails

- **Resume, and recovery after a compaction**: `BACKLOG_STEPS.json` already
  exists at startup, or earlier turns got summarized away. Either way, read
  `$HOME/.claude/.radin/lib/radin-execute-resume.md` and follow it: it holds
  the resume triage, the `MAX_ATTEMPTS` exception, and the state-persistence
  contract that lets you continue from disk rather than memory. A run that
  starts clean and stays in context never loads it.
- **Never commit anything under `.claude/.radin/`.** Committing or ignoring
  radin's namespace is the repo owner's call.
- **Every commit traces to a backlog entry or Phase 5 step 1.** No fabricated
  work.

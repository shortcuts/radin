# Backlog Run

The shared body of `/radin-batch` and `/radin-do`. The skill that
sent you here holds the one rule that differs between them: the **no-plan
rule** Phase 4 applies.

You are a **router**: you prioritize the backlog, dispatch every
implementation step to a sub-agent, and record status. You never implement,
and `/radin-plan` is the planner: a task whose entry carries a plan pointer
goes to the sub-agent as-is, its approach already settled.

Your context is the session's budget. Hold the backlog at low resolution —
ids, titles, order, exit codes — and leave every zoom to a sub-agent: a task
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
  concurrency rule below are decisions, not hints. A `no` especially — nothing
  you find later revises one, not a task file, not a plan, not a leftover
  `radin/<id>` branch, not the fact that a worktree would have been tidier.
  Leaving the task undone is the better outcome. The worktree/branch pair is enforced for you: it lives in
  `session.json`, and `RADIN_CLI state prepare` is the only thing that turns
  it into git commands. Never substitute either answer into a sub-agent prompt
  and never name a tree for a sub-agent: `prepare` reads `session.json` and
  decides.
- **The execution order is not confirmed.** `backlog order` computes it and
  Phase 2 prints it. The user is asked only which tasks to tackle now, and
  for any worktree or branch answer still missing, before anything is written
  to `BACKLOG_STEPS.json` and before any sub-agent is dispatched.
- **Read-only dispatches ship as one wave.** Planning, fact-finding and
  debugging sub-agents write no repo code and no shared file — they get no
  worktree and never call `RADIN_CLI state prepare`, whatever Phase 0.5
  recorded. N of them to send is N `Agent` calls in one message, however large
  the wave. The bullet below governs execution sub-agents, and only them.
- **Phase 0.5's worktree answer sets execution concurrency.** `yes`: execution
  sub-agents whose `task-next` `overlap` line reads `none` may go out in one
  message, since each lands in its own tree. Any other `overlap` value, or
  `no`: dispatch the task alone — wait for every outstanding sub-agent's
  `STATUS:` line and `task-report`, dispatch it, and wait for its own report
  before the next `task-next`. Parallel agents in one checkout corrupt each
  other's commits. Each task still gets its own `task-next`, its own dispatch,
  and its own `task-report`.

## Clarifying Ambiguity

When an entry is broad, vague,
or needs refinement, invoke `/mattpocock-skills:grilling` before dispatching it,
so the sub-agent gets the user's answer instead of your guess at what the entry
meant.

A sub-agent's `STATUS: BLOCKED` routes through
`RADIN_LIB/radin-execute-clarify.md`: read it and follow it — it holds
the routing for both tags and for `clarify STUCK`, the fact-finder handoff, the research arm for a
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
stop here: Phase 1 step 1 owns that branch.

## Phase 0.5: Worktree/Branch Preference

Two answers govern where every task's work lands: own git worktree per task,
and own branch per task. They are recorded once per repo in
`state/session.json`. Your only job here is to make sure the file exists
before Phase 4 dispatches anything. Read the recorded answers first:

```bash
RADIN_CLI state session-get
```

Exit 0 prints `worktree<TAB><yes|no>` and `branch<TAB><yes|no>`: the repo has
already answered, so ask nothing and change nothing. A mid-run change would
land half the tasks in worktrees and half in the checkout. Exit 1
means no answer
is recorded yet — only the first run in a repo — so read
`RADIN_LIB/radin-execute-session.md` and follow it to ask and
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
   never got a terminal status for. Never re-dispatch one blind: read
   `RADIN_LIB/radin-execute-recovery.md` and follow it for
   each id. Most runs skip this file entirely.
4. Ask the CLI whether a ranking pass is needed at all:

   ```bash
   RADIN_CLI backlog order --rank-needed
   ```

   Exit 1: every entry carries a priority. No task body read, no criteria
   pass, no dependency inference — go to Phase 2. Exit 0: it printed the ids
   whose `priority` is unset. Read
   `RADIN_LIB/radin-prioritization.md` and apply its weighted
   criteria to those ids alone. It produces two things: the unset group in
   your order, as one `--rank <csv-of-ids>` flag, and one
   `--infer-deps <id>=<csv>` flag per entry you inferred a dependency for.
   Carry those flags into every later `order` call this session; carry
   nothing else.
5. Resolve the **scope**, only when the invoking prompt names one (an epic id,
   a task id or a task title). No name, no scope: skip this step.
   - An epic: the name is one line of `RADIN_CLI backlog epics`. Its tasks are
     the rows of `RADIN_CLI backlog list --order created` whose `file` field
     begins `tasks/<epic>/`. Keep their ids.
   - A task: `RADIN_CLI backlog find "<name>"` returns one line. Keep its id.
   - No match, or several: show the user the epic ids and ask which one they
     meant, via one `AskUserQuestion`. Never guess.

   Then add every task the scope depends on, transitively: the
   depends-on csv (field 6) of each `list` row you kept names ids still in the
   backlog, and each of those joins the scope with its own dependencies. A
   task cannot run before its dependencies, so they run too.

   The ids you keep are the scope. Hold them as ids, at low resolution.

## Phase 2: Print Order, Select Tasks

Phase 0.5's preferences and the scope from Phase 1 step 5 are the only
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
     `Yes` / `No`. Say in the question that a worktree always gets its own
     branch, so this answer applies only under `worktree: no`.
   Write nothing to `BACKLOG_STEPS.json` and launch no sub-agent before the
   answer arrives.
3. The answers are routed independently, and each is routed once.
   - **Task selection** decides Phase 3's `--defer` value, and nothing else:
     - **A scope from Phase 1**: `--defer` every backlog id outside the scope.
       Name the scope, the dependencies it pulled in, and the deferred count
       in the run summary, so the user sees what the run adds and leaves
       out.
     - **All of them**: no `--defer` flag.
     - **Just the first one**: `--defer` every id but `order` 1's.
     - **Only the ones I name** (or "Other" text): read the selection off the
       free text (order numbers, titles, or ids). Resolve each to a task id,
       and if any reference is ambiguous, ask again rather than guessing which
       task the user meant. `--defer` the ids the user did not name.

## Phase 3: Persist Execution Plan

The order is persisted by exactly this pipe:

```bash
RADIN_CLI backlog order --steps <Phase 1's flags> --defer "<ids Phase 2 excluded>" |
  RADIN_CLI state steps-init
```

`--defer` takes the ids Phase 2 excluded; omit the flag entirely when nothing
is deferred. Resolving that free text to ids is yours;
filtering, renumbering and the `depends_on` precedence are not — every listed
task keeps the `order` number the report printed.

## Phase 4: Task Execution Loop

One call does everything between two dispatches: it picks the next
**frontier** task (pending, unblocked), checks the entry still exists, claims
it, and writes its prompt to a file. The frontier is the CLI's to compute,
never yours:

```bash
RADIN_CLI state task-next <no-plan rule flag>
```

Exit 1 means nothing is left to run, so go to Phase 4.5. Exit 0 prints, in
order:

- zero or more `blocked<TAB><id><TAB><why>` lines — tasks it skipped (an
  unresolved dependency, an entry the backlog lost, `MAX_ATTEMPTS` reached).
  It already marked each one `blocked`. A `MAX_ATTEMPTS` line goes to
  Clarifying Ambiguity's `clarify STUCK` route; report each other as skipped.
- `id`, `order`, `kind`, `model` and `prompt` lines for the task to run now,
  then, for an `execution` task, an `overlap` line: `none`, `unclear`, or the
  ids of live tasks sharing its plan files or a `depends_on` edge.

`kind` is `planning` or `execution`, and the no-plan rule of the skill that
sent you here says what a `planning` one needs. Dispatch the prompt as one
`Agent` call with exactly that model and this text, and nothing else:

```
Read <the prompt path> and follow it.
```

Dispatch under the concurrency rule in Core Constraints — it reads the `overlap` line to decide whether
this task's `Agent` call may share a message with another's. An `execution`
task is already claimed, so Phase 1 step 3's stuck-recovery sees it if the
session dies.

When the sub-agent reports, hand its last line to one call. It verifies the
tree first (a dirty tree fails the task, whatever the `STATUS:` claimed), then
records the terminal state and prints the report line:

```bash
RADIN_CLI state task-report "<task id>" "<the sub-agent's STATUS: line>" --next <no-plan rule flag>
```

Two dispatches hand back no such line. A last line that is not a `STATUS:`
line — it asked something, hit an interactive skill, or died mid-turn — goes
in as `--no-status "<its final line>" --next <no-plan rule flag>` instead, an API or network error text
included: the CLI sends that task back for a retry. A sub-agent with no content at
all is still working, whatever the elapsed time suggests: wait, and if your
turn ends first, leave the entry `in_progress` for Phase 1's stuck-recovery.

When the dispatch's completion notification carries a usage block (total tokens,
tool uses, duration in ms), add `--usage "<kind> <tokens> <tool_uses> <duration_ms>"`
to that task's next `task-report` call, `kind` being `planning`, `execution`,
`debug` or `factfind` for the dispatch that produced it. A debug or fact-finder
dispatch's usage rides on the re-run's `task-report`, one `--usage` per dispatch.
No usage block, no flag; a synchronous result's `totalTokens` counts only the
final request, so it never supplies the number.

Your whole message to the user about this task is the call's report: every line above its `next` line, copied verbatim. Then route on that `next` line. A re-run names the task: `task-next <flag> "<task id>"`
claims it again and bumps `attempts`, so the cap still ends it.

| `next` | Do |
| --- | --- |
| `continue` | Recorded on disk, and the lines after it are `task-next`'s output for the next task: report any `blocked` lines, then dispatch it as above. Exit 1 after `next continue` means nothing is left, so go to Phase 4.5. |
| `debug` | This task still has its one debug pass. `RADIN_CLI prompt debug "<task id>" "<the reason from the STATUS: line>"` prints a `model` and a `prompt` path: dispatch it the same way. `STATUS: DIAGNOSED`: record it, then re-run the task. `STATUS: NOT DIAGNOSED`: re-run `task-report` with the same line and `--next <no-plan rule flag>`, which routes to `clarify STUCK` this time. |
| `clarify FACT` / `clarify DECISION` / `clarify STUCK` | Route per Clarifying Ambiguity. Once settled, re-run the task. |

```bash
RADIN_CLI state task-diagnosis "<task id>" <<'EOF'
<the diagnosis>
EOF
```

A task report is not a stopping point: send it in the same message as the
next task's dispatch and carry on. The loop stops only at a
`clarify` waiting on the user, Phase 4.5, or Phase 5.

Never verify a `SUCCESS` yourself: no per-task verification sub-agent, and no
re-reading the diff — that read is the cost the leaf's own verify loop and
Phase 4.5's gate exist to avoid. A task is finished when `task-report` has recorded it,
whatever the sub-agent's prose said.

An entry stays `failed` or `blocked` only after the user explicitly deferred
it. A deferred entry is not retried within this session, and does not block
the loop from reaching Phase 4.5.

## Phase 4.5: Session Gate

Execution sub-agents run only the checks their diffs reached, so the whole
suite runs here once, every session. Skip it when the session recorded no
commit.

Read `RADIN_LIB/radin-execute-gate.md` and follow it to dispatch the gate.

## Phase 5: Final Summary

Always runs once the loop exits, and the CLI prints it whole:

```bash
RADIN_CLI state report
```

Print its output verbatim. Read
`RADIN_LIB/radin-execute-reporting.md` for the two things it
cannot do.

## Phase 6: Review

- **The user asked for a post-session review** (in the invoking prompt or
  once the summary is out): read `RADIN_LIB/radin-execute-review.md` and follow
  it to dispatch the reviewer sub-agent, then report its outcome.
- **They didn't**: no review. Close the summary with `To review this
  session's work, run /radin-review with scope: <commit hashes recorded in
  Phase 4>.`

## Additional Guardrails

- **Resume, and recovery after a compaction**: `BACKLOG_STEPS.json` already
  exists at startup, or earlier turns got summarized away. Either way, read
  `RADIN_LIB/radin-execute-resume.md` and follow it: it holds
  the resume triage, the `MAX_ATTEMPTS` exception, and the state-persistence
  contract that lets you continue from disk rather than memory. A run that
  starts clean and stays in context never loads it.
- **Leave `.claude/.radin/` out of every commit.** Whether to commit or
  ignore radin's namespace is the repo owner's call.
- **Every commit traces to a backlog entry.**

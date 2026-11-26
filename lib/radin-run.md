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

You run in the user's own thread, so you can ask them.

## Core Constraints

<!-- host:claude -->
- **Claude Code decides foreground or background**, so send every `Agent` call
  with no `run_in_background`. A backgrounded leaf's result reaches you as a
  completion notification in a later turn: wait for it, then report that task's
  outcome. A task reaches its **terminal status** only when `state task-report`
  records one on disk, so a dispatch that hands back nothing leaves it
  unfinished: its `attempts` is already bumped, and Phase 0's stuck-recovery
  owns it next run.
<!-- /host -->
<!-- host:agents -->
- **Dispatch blocks.** Start each leaf with your sub-agent tool and wait until it finishes. Its final message is the result, and no notification arrives later. Only `state task-report` gives a task its **terminal status**. A dispatch that hands back nothing leaves the task unfinished: its `attempts` is already bumped, and Phase 0's stuck-recovery owns it next run.
<!-- /host -->
- **Lane mode is not yours to change.** `RADIN_CLI state lanes-init` derives it
  once, and `RADIN_CLI state prepare` is the only thing that turns it into git
  commands. Never name a tree, worktree or branch in a sub-agent prompt. A task
  file, a plan or a leftover `radin/<id>` branch revises nothing.
- **Deleting a path asks the user first.** A task that reports `STATUS: BLOCKED (DECISION)`
  for a path that exists but git does not list as a worktree gets your question
  per `RADIN_LIB/radin-ask-rule.md`: `Remove it` or `Leave it`, recommending `Leave it`.
  Run `rm` on that path only after `Remove it`, and never send a sub-agent to
  delete it. **Why:** a leftover directory can hold unsaved work, and an unasked
  `rm -rf` in locationjoystick removed one.
- **The execution order is not confirmed.** `backlog order` computes it and
  Phase 2 prints it. Nothing is written to `BACKLOG_STEPS.json` and no
  sub-agent is dispatched before Phase 3's `steps-init`.
- **Read-only dispatches get no worktree.** Planning, fact-finding, judge and
  debugging sub-agents write no repo code and no shared file, so they never
  call `RADIN_CLI state prepare`. Several fact-finding or debugging dispatches
  due at once go out in messages of at most the lane cap.
- **The lane cap limits sub-agents running at once.** Run `RADIN_CLI state lane-cap`
  once per session. Every message you send holds at most that many dispatches,
  and you start no dispatch while that many run. **Why:** 99 ready tasks
  planned in one message stalled a run before its first commit.

## Clarifying Ambiguity

A sub-agent's `STATUS: BLOCKED` routes through
`RADIN_LIB/radin-batch-clarify.md`: read it and follow it. It holds
the routing for both tags, the fact-finder handoff, the research arm for a
fact that lives outside this repo, and the `backlog append` labels and `backlog fact` verb that put a
settled answer where planning and execution sub-agents read it.

Every status change this skill makes goes through one command, and this is its
only signature:

```bash
RADIN_CLI state set-status "<task id>" <pending|in_progress|failed|blocked> [--reason deferred] "<note>"
```

The `note` is a single shell argument, so quote it whole however many
sentences it holds.

---

## Phase 0: Resolve Project Namespace

`RADIN_CLI backlog` and `RADIN_CLI state` own every radin state file. Never
hand-edit one, and never parse one to decide what to do next.
Every `RADIN_CLI` call resolves the namespace from the current directory, so
no call takes a path. One call runs every startup check, including the
reconcile of finished tasks a dead run left in the backlog:

```bash
RADIN_CLI state preflight
```

It always exits 0 and prints one tab-separated line per branch that applies.
Empty output means no branch applies. Act on each line by its first field:

- `empty`: the backlog holds no entry. Tell the user and stop. No other line
  prints with it.
- `stuck<TAB>id<TAB>attempts<TAB>note`: a previous run dispatched this task
  and never got a terminal status for it. Never re-dispatch one blind. Run
  `RADIN_CLI state recover "<id>"` for each id. Exit 0: print its
  `recovered` line. Exit 3: read `RADIN_LIB/radin-batch-recovery.md` and
  follow it for that id.
- `waiting<TAB>id<TAB>reason<TAB>note`: this entry holds an unanswered question.
  `steps-init` keeps a `deferred` entry out of the run and rewrites every other
  waiting entry as `pending`, so one left unanswered restarts without its
  decision. Settle every one per
  "Settling Waiting Entries" in `RADIN_LIB/radin-batch-clarify.md`.
- `loose<TAB>csv`: these ids sit outside every epic. Run this triage before
  Phase 1, scoped or not. Read each title from `RADIN_CLI backlog loose` and
  the epics from `RADIN_CLI backlog epics`, and read a task body only when its
  title fits no epic. Propose for each id an existing epic, a new epic when two
  or more loose tasks share a goal no epic covers, or `maintenance`. Print one
  table with the columns `Task id`, `Title`, `Proposed epic`, `New`, and one
  line per new epic with its slug and description. Ask per
  `RADIN_LIB/radin-ask-rule.md` with the options `Apply this table`
  (recommended) and `Stop, I will move them`. Treat a free-text answer as a
  table edit: re-show the table and ask again. `Apply`: run
  `RADIN_CLI backlog epic-add <slug>` with the description on stdin for each
  new epic, then `RADIN_CLI backlog epic-move "<id>" <epic>` for each row. Stop
  at the first non-zero exit, print its stderr and ask once. `Stop`: end the
  run with one line naming the loose ids.
- `rank<TAB>csv`: these ids have no `priority`. Read
  `RADIN_LIB/radin-prioritization.md` and apply its weighted criteria to those
  ids alone. It produces two things: the unset group in your order, as one
  `--rank <csv-of-ids>` flag, and one `--infer-deps <id>=<csv>` flag per entry
  you inferred a dependency for. Carry those flags into every later `order`
  call this session; carry nothing else. No `rank` line: every entry carries
  a priority, so read no task body, run no criteria pass, infer no
  dependency.
- `leftovers`: a branch or parked task from an earlier session is still
  outside the base. Run `RADIN_CLI state lanes-recover` first and follow the
  Recovery section of `RADIN_LIB/radin-batch-lanes.md` when it prints anything.
  Then run `RADIN_CLI state reconcile` and print its output, unasked. It lands
  every legacy task branch, files each `follow-up` entry itself, and prints each
  branch it kept with its reason. Exit 3: a branch conflicted, so read
  `RADIN_LIB/radin-batch-merge.md` and follow it.

Then run `RADIN_CLI state stash-triage`. Each `candidate<TAB>hash<TAB>id` line
becomes one `RADIN_CLI prompt factfind "<id>" "Does the uncommitted work in git
stash <hash> (read it with git stash show -p --include-untracked <hash>)
continue the task at TASK_FILE, judged against that task's body, acceptance and
plan? Answer FOUND — yes or FOUND — no, with one reason."` dispatch, as many
per message as the lane cap allows. For each answer run `RADIN_CLI state stash-claim <hash> <id>` on
`FOUND — yes` and `RADIN_CLI state stash-claim <hash> -` on any other answer;
a claim that exits non-zero ("already triaged") is ignored. Print the `left`
line as `N radin-batch stashes left in place (git stash list)`.

## Phase 1: Resolve the Scope

Resolve the **scope**, only when the invoking prompt names one (an epic id,
a task id or a task title). No name, no scope: skip this phase.

```bash
RADIN_CLI backlog scope "<name>"
```

Exit 0: line 1 is `ids<TAB><csv>`, the scope with every transitive
dependency. Keep that csv as the scope. Line 2, when present, is
`dependencies<TAB><csv>`, the tasks the closure added. Exit 1 or 2: show the
user `RADIN_CLI backlog epics` and any `candidate` lines, and ask which one
<!-- host:claude -->
they meant, via one `AskUserQuestion`. Never guess.
<!-- /host -->
<!-- host:agents -->
they meant, via one ask (`RADIN_LIB/radin-ask-rule.md`). Never guess.
<!-- /host -->

## Phase 2: Print Order

No question is asked here. Phase 1's scope is the only selection, and the whole
backlog runs without one.

1. The selection flag is `--only <the scope csv>` when Phase 1 resolved a
   scope, else none.
2. Print this verbatim, and compose nothing of your own:

   ```bash
   RADIN_CLI backlog order --report <Phase 0's --rank/--infer-deps flags> <the selection flag>
   ```

   One `<order>. <title> (id: <id>)` line per selected task, then one
   `dependency override:` line per dependency the fix moved up.

## Phase 3: Persist Execution Plan

The order is persisted by exactly this pipe:

```bash
RADIN_CLI backlog order --steps <Phase 0's flags> <Phase 2's selection flag> |
  RADIN_CLI state steps-init
```

Omit the selection flag when Phase 2 chose none. Resolving free text
to ids is yours; the excluded set, renumbering and the `depends_on` precedence are not. Every listed
task keeps the `order` number the report printed.

Then run `RADIN_CLI state stop-check`. Exit 0 means no task can run: print its
`id<TAB>reason<TAB>note` lines as the stop message and end the run, dispatching
nothing. Exit 1: go on.

Then run `RADIN_CLI state lanes-init` and print its output. It derives the lane
mode and prints one `lane<TAB>epic<TAB>state<TAB>count` line per epic. An exit 1 with
`epic dependency cycle` names the epics and the task dependency behind each edge. Print it and stop.

## Phase 3.5: Settle Open Decisions

```bash
RADIN_CLI state steps-open
```

Exit 1 with no output: go to Phase 4. Exit 0 prints `id<TAB>question` for each
open decision of a selected task. Settle them as Phase 0's `waiting` line does, and
append each answer per `RADIN_LIB/radin-batch-clarify.md`. A question the user explicitly
defers stays open: append it again as `**Open decision:** <question>, <options>,
<your recommendation>`. Continue to Phase 4.

## Phase 4: Lane Loop

A lane is one epic. Its tasks run one at a time, each with its own `task-next`,
its own dispatch and its own `task-report`. Repeat the four steps below as rounds.

**Fill slots.** Run `RADIN_CLI state lane-next` until it exits 1 or 2.
Exit 0 prints `start<TAB>epic`: that lane runs now, with no judge when
`lane-next` cleared it itself on disjoint named files. Exit 2 prints one
`judge<TAB>epic<TAB>running csv` line per candidate in start order. Take the
first candidate and run `RADIN_CLI prompt judge "<candidate>" "<running>"`
for each running epic. Any non-zero exit: print its stderr and take the next
candidate. A graph gap does not fail it: the prompt carries the `gap` line and the
judge decides. Dispatch the printed prompt as one sub-agent (name from the printed `name`
line, the printed `model` and `effort`, when printed), all judges of one
candidate in one message. Run `RADIN_CLI state lane-judge "<candidate>"
"<running>" "<its last line>"` for each. Every `yes`: run
`RADIN_CLI state lane-next --cleared "<candidate>"`, which starts it. Any
`no`: take the next candidate. No candidate cleared: start nothing, and the
next free slot judges again.

**Pick tasks.** For each `running` lane of `RADIN_CLI state lanes-show`, run
`RADIN_CLI state task-next --lane "<epic>"`. Exit 1 sends that lane to
Merge. Exit 0 prints, in order:

- zero or more `blocked<TAB><id><TAB><why>` lines for tasks it skipped (an
  unresolved dependency, an entry the backlog lost, `MAX_ATTEMPTS` reached).
  It already marked each one `blocked`. Report each as skipped. The entry stays on the backlog with a `**Progress:**` note, and any work is a wip commit. When the user asks to retry one that hit `MAX_ATTEMPTS`, run `RADIN_CLI state retry "<task id>"`.
  **Judge a blocked dependency.** For a `why` of "waiting on dependency 'D', which is blocked", read D's row in `RADIN_CLI state steps-waiting`. D's reason is `inconclusive` and its note says the code is committed and only a check the leaf could not run remains (a device, a credential, a paid call): run `RADIN_CLI state dep-owed "D" "<that check>"`, then run `task-next --lane` for the lane again. Exit 3 or any other note (nothing built, a failing test, a decision): leave the task blocked.
<!-- host:claude -->
- `id`, `order`, `kind`, `model`, an optional `effort` and `prompt` lines for the task to run now.
<!-- /host -->
<!-- host:agents -->
- `id`, `order`, `kind`, an optional `model`, an optional `effort` and a `prompt` line for the task to run now.
<!-- /host -->

`kind` is `planning` for an entry radin-record flagged as needing a plan that
has none yet, else `execution`. A planning task dispatches as is. Its
`STATUS: PLANNED` goes through `task-report`, and the lane's next `task-next
--lane` returns the planned task as `execution`. Before an `execution`
dispatch, run `RADIN_CLI state lane-sync "<id>"` per
`RADIN_LIB/radin-batch-lanes.md`. A task whose `RADIN_CLI backlog meta "<id>"`
prints `exclusive<TAB>yes` waits: dispatch the other tasks of the round first,
then each exclusive one alone. **Why:** a timing criterion read 235 to 507 ms
with parallel agents. A planning leaf with no `STATUS:` line goes in as `--no-status` like any other; it retries until `MAX_ATTEMPTS`, then `task-next` blocks it.

<!-- host:claude -->
`STATUS: BLOCKED (FACT|DECISION)`
routes per Clarifying Ambiguity. Dispatch the prompt as one
`Agent` call with exactly that model, that effort when an `effort` line printed, `name:` set to the printed `name` value
(it fits the 64-character limit; `kind` is `planning`, `execution`, `debug`, `factfind` or `judge`), and this text,
and nothing else. The name lets a usage report show which task and role cost
the most:
<!-- /host -->
<!-- host:agents -->
Start the prompt with your sub-agent tool and wait for it to finish. Pass that model when a `model` line printed, that effort when an `effort` line printed, and the agent name from the printed `name` line (`kind` is `planning`, `execution`, `debug`, `factfind` or `judge`). The prompt text is this, and nothing else. A usage report uses the name to show which task and role cost the most. A result of `STATUS: BLOCKED (FACT|DECISION)` routes per Clarifying Ambiguity:
<!-- /host -->

```
Read <the prompt path> and follow it.
```

**Report.** Dispatch every claimed task of the round in one message, at most the lane cap, and wait for every `STATUS:` line.

When the sub-agent reports, hand its last line to one call. It verifies the
tree first (a dirty tree fails the task, whatever the `STATUS:` claimed), then
records the terminal state and prints the report line. A planning leaf's `STATUS: PLANNED` goes in too, and `task-report` records its sizing:

```bash
RADIN_CLI state task-report "<task id>" "<the sub-agent's STATUS: line>"
```

<!-- host:claude -->
Two dispatches hand back no such line. A last line that is not a `STATUS:`
line, because the agent asked something, hit an interactive skill, or died mid-turn, goes
in as `--no-status "<its final line>"` instead, an API or network error text
included: the CLI sends that task back for a retry. A sub-agent with no content at
all may be idle, so run `ListAgents`. A running one is working: wait. An idle one
with no `STATUS:` line gets one `SendMessage`: "Finish, then end with a `STATUS:` line."
Do this whatever its last text says. "Waiting for a background run" is not a reason
to wait: a leaf receives no background notification, so it never wakes.
Idle again after that, record `--no-status "idle, no STATUS"`. If your
turn ends first, leave the entry `in_progress` for Phase 0's stuck-recovery.
<!-- /host -->
<!-- host:agents -->
A dispatch can end with no `STATUS:` line: the agent asked something, hit an interactive skill, died mid-turn, or returned an API or network error. Record it as `--no-status "<its final line>"`, and the CLI sends the task back for a retry. A leaf that returns is finished, so send it no nudge. When the host says the leaf still runs, wait again. When your turn ends first, Phase 0's stuck-recovery takes the `in_progress` entry next run.
<!-- /host -->

<!-- host:claude -->
**Heartbeat.** Right after each `Agent` dispatch, call `CronCreate` once for
that task with `cron: "7,27,47 * * * *"`, `recurring: true` and the prompt
"Heartbeat for `<agent name>`: run `ListAgents`." Cron fires only while your
turn is idle, so it is your wake-up when that leaf stalls. On it, if that
agent is idle with no `STATUS:` line, follow the rule above. Any other agent
is not this job's concern. Call `CronDelete` on the job the moment
`task-report` records that task, and on any job still open at Phase 5.
<!-- /host -->

<!-- host:claude -->
When the dispatch's completion notification carries a usage block (total tokens,
tool uses, duration in ms), add `--usage "<kind> <tokens> <tool_uses> <duration_ms>"`
to that task's next `task-report` call, `kind` being `planning`, `execution`,
`debug` or `factfind` for the dispatch that produced it. A debug or fact-finder
dispatch's usage rides on the re-run's `task-report`, one `--usage` per dispatch, and the journal books it to the dispatch of that kind.
No usage block, no flag; a synchronous result's `totalTokens` counts only the
final request, so it never supplies the number.
<!-- /host -->
<!-- host:agents -->
Pass no `--usage` flag.
<!-- /host -->

Your whole message to the user about this task is the call's report: every line above its `next` line, copied verbatim. Then route on that `next` line. A re-run names the task: `task-next "<task id>"`
claims it again and bumps `attempts`, so the cap still ends it.

| `next` | Do |
| --- | --- |
| `continue` | Recorded on disk. The lane's next `task-next --lane` runs next round. |
<!-- host:claude -->
| `debug` | This task still has its one debug pass. `RADIN_CLI prompt debug "<task id>" "<the reason from the STATUS: line>"` prints a `model` and a `prompt` path: dispatch it the same way. `STATUS: DIAGNOSED`: record it as below, then re-run the task. `STATUS: NOT DIAGNOSED`: re-run `task-report` with the same line, which records the failure on the entry and returns `continue`. |
<!-- /host -->
<!-- host:agents -->
| `debug` | This task still has its one debug pass. `RADIN_CLI prompt debug "<task id>" "<the reason from the STATUS: line>"` prints a `prompt` path, and a `model` line when the host sets one: dispatch it the same way. `STATUS: DIAGNOSED`: record it as below, then re-run the task. `STATUS: NOT DIAGNOSED`: re-run `task-report` with the same line, which records the failure on the entry and returns `continue`. |
<!-- /host -->
| `clarify FACT` | Route per Clarifying Ambiguity. Once found, re-run the task. |
| `clarify DECISION` | Park it per Clarifying Ambiguity and go on. A question asked now, once settled: `RADIN_CLI state answered "<task id>"`, then re-run the task. |

```bash
RADIN_CLI state task-diagnosis "<task id>" "<the STATUS: DIAGNOSED line>"
```

A task report is not a stopping point: carry on to the next step in the same
turn. The loop stops only at an irreversible-work question to the user, Phase 4.5, or
Phase 5.

**Merge.** A lane whose `task-next --lane` exited 1 goes through the Merge
queue and Gate of `RADIN_LIB/radin-batch-lanes.md`, one lane at a time. A
`lane-queue` that exits 1 prints its stderr and the loop moves on.

The loop ends when a round picked no task, no lane went through Merge and
`lane-next` exited 1. Run `RADIN_CLI state lanes-show` and print it. A lane
still `running` stays on its branch, and the next Phase 0 `lanes-recover` takes it.

Never verify a `SUCCESS` yourself: no per-task verification sub-agent, and no
re-reading the diff. That read is the cost the leaf's own verify loop and
Phase 4.5's gate exist to avoid. A task is finished when `task-report` has recorded it,
whatever the sub-agent's prose said. A lane commit counts as done only after its merge.

## Phase 4.5: Session Gate

Execution sub-agents run only the tests their diffs reach. The gate runs the
full test suite, lint and format once per session, then reviews the session's commits and files each
`act-on` finding to the backlog. Skip it when the session recorded no commit.

Read `RADIN_LIB/radin-batch-gate.md` and follow it to dispatch the gate.

## Phase 4.7: Lanes

In lanes mode, run `RADIN_CLI state lanes-show` and print it, so Phase 5 names
every lane not `done`.

## Phase 5: Final Summary

Always runs after Phase 4.7, once every task branch has landed. The CLI prints every
count and every problem; you write the short list of what was built:

```bash
RADIN_CLI state report --brief
```

Print its output verbatim. Then write `Succeeded:` yourself: one line per task
that has a `task-report` in your context, saying what it built in plain words, at
most 15 words, no hashes. A task you no longer remember gets its line from
`RADIN_CLI state report`, whose `Succeeded:` list you condense. Read
`RADIN_LIB/radin-batch-reporting.md` for the one thing the CLI cannot do.

Then run `RADIN_CLI state steps-waiting`. Exit 1: go to Phase 6. Exit 0
<!-- host:claude -->
prints the `waiting` entries this run left, parked ones included, so ask one `AskUserQuestion` each,
<!-- /host -->
<!-- host:agents -->
prints the `waiting` entries this run left, parked ones included, so ask one question each,
<!-- /host -->
per "Settling At Batch End" in `RADIN_LIB/radin-batch-clarify.md`, then tell the
user the answered entries are `pending` and the blocked ones wait for an answer.

**Ask what remains.** Each item of the summary that needs the user's choice
becomes a question per `RADIN_LIB/radin-ask-rule.md`, never a bullet. One question per
`Failed` entry: `Retry now` (run `RADIN_CLI state retry "<task id>"`, then go back to
Phase 4) or `Leave it on the backlog`. One question for a gate result
`RADIN_LIB/radin-batch-gate.md` hands to the user: `Triage it now with /radin-review`
or `Leave it`. **The test:** would the user otherwise have to ask for this as a
question? If yes, ask it.

## Phase 6: Review

Phase 4.5 already reviewed the session. Close the summary with `To triage the
review's other findings, run /radin-review with scope: <the output of
RADIN_CLI state session-commits>.`

## Additional Guardrails

- **Resume, and recovery after a compaction**: `BACKLOG_STEPS.json` already
  exists at startup, or earlier turns got summarized away. Either way, read
  `RADIN_LIB/radin-batch-resume.md` and follow it. It holds
  the resume triage, the `MAX_ATTEMPTS` exception and the state-persistence
  contract.
- **Every commit traces to a backlog entry.**

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
- **Deleting a path asks the user first.** A task that reports `STATUS: BLOCKED (DECISION)`
  for a path that exists but git does not list as a worktree gets your question
  per `RADIN_LIB/radin-ask-rule.md`: `Remove it` or `Leave it`, recommending `Leave it`.
  Run `rm` on that path only after `Remove it`, and never send a sub-agent to
  delete it. **Why:** a leftover directory can hold unsaved work, and an unasked
  `rm -rf` in locationjoystick removed one.
- **The execution order is not confirmed.** `backlog order` computes it and
  Phase 2 prints the selected part. The user is asked only which tasks to tackle now (all, or
  the suggested epic), and
  for any worktree or branch answer still missing, before anything is written
  to `BACKLOG_STEPS.json` and before any sub-agent is dispatched.
- **Read-only dispatches get no worktree.** Planning, fact-finding and
  debugging sub-agents write no repo code and no shared file, so they never
  call `RADIN_CLI state prepare`, whatever Phase 0 recorded. Several
  fact-finding or debugging dispatches due at once go out in messages of at
  most the wave cap.
- **The wave cap limits sub-agents running at once.** Run `RADIN_CLI state wave-cap`
  once per session. Every message you send holds at most that many dispatches,
  and you start no dispatch while that many run. **Why:** 99 ready tasks
  planned in one message stalled a run before its first commit.
- **Phase 0's worktree answer sets execution concurrency.** `yes`: Phase 4 runs
  waves, and only a group the partition proves disjoint goes out in one message.
  `no`: Phase 4's serial loop runs one task at a time in the main checkout.
  Parallel agents in one checkout corrupt each other's commits. Each task still
  gets its own `task-next`, its own dispatch, and its own `task-report`.

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

- `empty`: the backlog holds no entry. Tell the user and ask whether to
  create an empty backlog or stop. Those are the only two outcomes. An empty
  backlog ends the run: report it and stop. No other line prints with it.
- `session<TAB>missing`: no worktree/branch answer is recorded, which happens
  only on the first run in a repo. Read `RADIN_LIB/radin-batch-session.md`
  and follow it to ask and persist them. Otherwise ask nothing and change
  nothing: a mid-run change would flip how running tasks get their tree.
- `stuck<TAB>id<TAB>attempts<TAB>note`: a previous run dispatched this task
  and never got a terminal status for it. Never re-dispatch one blind. Run
  `RADIN_CLI state recover "<id>"` for each id. Exit 0: print its
  `recovered` line. Exit 3: read `RADIN_LIB/radin-batch-recovery.md` and
  follow it for that id.
- `waiting<TAB>id<TAB>reason<TAB>note`: this entry holds an unanswered question.
  `steps-init` rewrites `BACKLOG_STEPS.json` in Phase 3, so a waiting entry
  that stays unanswered restarts without its decision. Settle every one per
  "Settling Waiting Entries" in `RADIN_LIB/radin-batch-clarify.md`.
- `rank<TAB>csv`: these ids have no `priority`. Read
  `RADIN_LIB/radin-prioritization.md` and apply its weighted criteria to those
  ids alone. It produces two things: the unset group in your order, as one
  `--rank <csv-of-ids>` flag, and one `--infer-deps <id>=<csv>` flag per entry
  you inferred a dependency for. Carry those flags into every later `order`
  call this session; carry nothing else. No `rank` line: every entry carries
  a priority, so read no task body, run no criteria pass, infer no
  dependency.
- `leftovers`: a task branch from an earlier session, finished or not, is
  still outside the base. Land it now as Phase 4.7 does.

Then run `RADIN_CLI state stash-triage`. Each `candidate<TAB>hash<TAB>id` line
becomes one `RADIN_CLI prompt factfind "<id>" "Does the uncommitted work in git
stash <hash> (read it with git stash show -p --include-untracked <hash>)
continue the task at TASK_FILE, judged against that task's body, acceptance and
plan? Answer FOUND — yes or FOUND — no, with one reason."` dispatch, as many
per message as the wave cap allows. For each answer run `RADIN_CLI state stash-claim <hash> <id>` on
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

## Phase 2: Select Tasks, Print Order

Phase 0's preferences and the scope from Phase 1 are the only
questions a prompt may pre-answer.

<!-- host:claude -->
1. Ask via one `AskUserQuestion` call with fixed choices:
<!-- /host -->
<!-- host:agents -->
1. Ask per `RADIN_LIB/radin-ask-rule.md`, with fixed choices:
<!-- /host -->
- **Task selection** (unless Phase 1 resolved a scope): run
     `RADIN_CLI backlog suggest <Phase 0's --rank/--infer-deps flags>` first.
     It prints `tasks<TAB>N<TAB>all|epic`, then `epic<TAB><id><TAB><count>`
     when an epic exists. No `epic` line: every task runs, so ask nothing here.
     Else ask "Which tasks now?" with exactly two options: `All of them (N
     tasks)` and `Epic <id> (<count> tasks)`. Put first the one the `tasks`
     line names, and end its label with `(Recommended)`. The user states a
     narrower scope in the invoking prompt, so offer no third option.
- **Worktree** (if Phase 0 printed `session`): "Git worktree per task?"
     Options: `Yes` / `No`.
- **Branch** (if Phase 0 printed `session`): "Own branch per task?" Options:
     `Yes` / `No`. Its meaning and wording: `RADIN_LIB/radin-batch-session.md`.
   Write nothing to `BACKLOG_STEPS.json` and launch no sub-agent before the
   answer arrives.

2. The answers are routed independently, and each is routed once.
   - **Task selection** decides Phase 3's selection flag, and nothing else:
     - **A scope from Phase 1**: `--only <the scope csv>`. Name the scope, the
       dependencies it pulled in, and the deferred count in the run summary, so
       the user sees what the run adds and leaves out.
     - **All of them**: no flag.
     - **Epic <id>**: run `RADIN_CLI backlog scope "<id>"` as Phase 1 does and
       pass `--only <its ids csv>`.
     - **"Other" text**: treat it as a name and resolve it as Phase 1 does. On
       exit 1 or 2, ask again.
3. Print this verbatim, and compose nothing of your own:

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

Omit the selection flag when Phase 2 chose all of them. Resolving free text
to ids is yours; the excluded set, renumbering and the `depends_on` precedence are not. Every listed
task keeps the `order` number the report printed.

## Phase 3.5: Settle Open Decisions

```bash
RADIN_CLI state steps-open
```

Exit 1 with no output: go to Phase 4. Exit 0 prints `id<TAB>question` for each
open decision of a selected task. Settle them as Phase 0's `waiting` line does, and
append each answer per `RADIN_LIB/radin-batch-clarify.md`. A question the user explicitly
defers stays open: append it again as `**Open decision:** <question>, <options>,
<your recommendation>`, so the leaf blocks on it. Continue to Phase 4.

## Phase 4: Task Execution Loop

Run `RADIN_CLI state session-get`. `worktree<TAB>yes` means run "Wave mode"
below instead of this loop. Any other answer runs this loop.

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
  It already marked each one `blocked`. Report each as skipped. The entry stays on the backlog with a `**Progress:**` note, and any work is a wip commit. When the user asks to retry one that hit `MAX_ATTEMPTS`, run `RADIN_CLI state retry "<task id>"`.
<!-- host:claude -->
- `id`, `order`, `kind`, `model`, an optional `effort` and `prompt` lines for the task to run now.
<!-- /host -->
<!-- host:agents -->
- `id`, `order`, `kind`, an optional `model`, an optional `effort` and a `prompt` line for the task to run now.
<!-- /host -->

`kind` is `planning` for an entry radin-record flagged as needing a plan that
has none yet, else `execution`. A planning leaf with no `STATUS:` line goes in as `--no-status` like any other; it retries until `MAX_ATTEMPTS`, then `task-next` blocks it.
<!-- host:claude -->
`STATUS: BLOCKED (FACT|DECISION)`
routes per Clarifying Ambiguity. Dispatch the prompt as one
`Agent` call with exactly that model, that effort when an `effort` line printed, `name:` set to the printed `name` value
(it fits the 64-character limit; `kind` is `planning`, `execution`, `debug` or `factfind`), and this text,
and nothing else. The name lets a usage report show which task and role cost
the most:
<!-- /host -->
<!-- host:agents -->
Start the prompt with your sub-agent tool and wait for it to finish. Pass that model when a `model` line printed, that effort when an `effort` line printed, and the agent name from the printed `name` line (`kind` is `planning`, `execution`, `debug` or `factfind`). The prompt text is this, and nothing else. A usage report uses the name to show which task and role cost the most. A result of `STATUS: BLOCKED (FACT|DECISION)` routes per Clarifying Ambiguity:
<!-- /host -->

```
Read <the prompt path> and follow it.
```

Dispatch one task at a time. An `execution`
task is already claimed, so Phase 0's stuck-recovery sees it if the
session dies.

When the sub-agent reports, hand its last line to one call. It verifies the
tree first (a dirty tree fails the task, whatever the `STATUS:` claimed), then
records the terminal state and prints the report line. A planning leaf's `STATUS: PLANNED` goes in too, and `task-report` records its sizing:

```bash
RADIN_CLI state task-report "<task id>" "<the sub-agent's STATUS: line>" --next
```

<!-- host:claude -->
Two dispatches hand back no such line. A last line that is not a `STATUS:`
line, because the agent asked something, hit an interactive skill, or died mid-turn, goes
in as `--no-status "<its final line>" --next` instead, an API or network error text
included: the CLI sends that task back for a retry. A sub-agent with no content at
all may be idle, so run `ListAgents`. A running one is working: wait. An idle one
with no `STATUS:` line gets one `SendMessage`: "Finish, then end with a `STATUS:` line."
Do this whatever its last text says. "Waiting for a background run" is not a reason
to wait: a leaf receives no background notification, so it never wakes.
Idle again after that, record `--no-status "idle, no STATUS" --next`. If your
turn ends first, leave the entry `in_progress` for Phase 0's stuck-recovery.
<!-- /host -->
<!-- host:agents -->
A dispatch can end with no `STATUS:` line: the agent asked something, hit an interactive skill, died mid-turn, or returned an API or network error. Record it as `--no-status "<its final line>" --next`, and the CLI sends the task back for a retry. A leaf that returns is finished, so send it no nudge. When the host says the leaf still runs, wait again. When your turn ends first, Phase 0's stuck-recovery takes the `in_progress` entry next run.
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
| `continue` | Recorded on disk, and the lines after it are `task-next`'s output for the next task: report any `blocked` lines, then dispatch it as above. Exit 1 after `next continue` means nothing is left, so go to Phase 4.5. |
<!-- host:claude -->
| `debug` | This task still has its one debug pass. `RADIN_CLI prompt debug "<task id>" "<the reason from the STATUS: line>"` prints a `model` and a `prompt` path: dispatch it the same way. `STATUS: DIAGNOSED`: record it as below, then re-run the task. `STATUS: NOT DIAGNOSED`: re-run `task-report` with the same line and `--next`, which records the failure on the entry and returns `continue`. |
<!-- /host -->
<!-- host:agents -->
| `debug` | This task still has its one debug pass. `RADIN_CLI prompt debug "<task id>" "<the reason from the STATUS: line>"` prints a `prompt` path, and a `model` line when the host sets one: dispatch it the same way. `STATUS: DIAGNOSED`: record it as below, then re-run the task. `STATUS: NOT DIAGNOSED`: re-run `task-report` with the same line and `--next`, which records the failure on the entry and returns `continue`. |
<!-- /host -->
| `clarify FACT` / `clarify DECISION` | Route per Clarifying Ambiguity. Once settled, run `RADIN_CLI state answered "<task id>"`, then re-run the task. |

```bash
RADIN_CLI state task-diagnosis "<task id>" "<the STATUS: DIAGNOSED line>"
```

A task report is not a stopping point: send it in the same message as the
next task's dispatch and carry on. The loop stops only at a
`clarify` waiting on the user, Phase 4.5, or Phase 5.

Never verify a `SUCCESS` yourself: no per-task verification sub-agent, and no
re-reading the diff. That read is the cost the leaf's own verify loop and
Phase 4.5's gate exist to avoid. A task is finished when `task-report` has recorded it,
whatever the sub-agent's prose said. A commit still on a side branch counts as done only after the merge. Phase 4.7 lands every task branch, and an unfinished task's branch lands with a follow-up entry (see "A task is done when its commit is in the base branch" in `docs/DECISIONS.md`).

An entry stays `failed` or `blocked` only after the user explicitly deferred
it. A deferred entry is not retried within this session, and does not block
the loop from reaching Phase 4.5.

### Wave mode (worktree yes)

A wave is at most `state wave-cap` (default 2) of the pending tasks whose
dependencies are all done, lowest `order` first. Count waves from 1
in this session, and call the current number `N`. Dispatch, report, heartbeat
and `--usage` work as in the loop above. Wave mode never passes `--next`,
because it would claim a task outside the group.

1. Run `RADIN_CLI state wave`. Exit 1 means nothing is left, so go to Phase 4.5.
2. **Plan one task at a time.** Walk the `state wave` ids in order. For each
   id whose `RADIN_CLI backlog meta "<id>"` prints `planning<TAB>needed`, run
   `RADIN_CLI state task-next "<id>"`, then
   `RADIN_CLI prompt planning "<id>" <kept ids>`. Dispatch that prompt alone,
   wait, and run `task-report`. A `PLANNED — deferred` line drops the id from
   this wave. Any other line adds the id to the kept ids, and so does an id
   that is already planned. A planned task is never claimed here.
3. Run `RADIN_CLI state wave | RADIN_CLI state wave-partition --wave N`. Each
   `group<TAB>n<TAB>csv` line is a group, and the CLI records every
   serialization with its evidence. A task you leave out of a group runs in a
   later group of its own.
   A task whose `backlog meta` prints `exclusive<TAB>yes` comes back as a group
   of one, and you run it alone.
4. Veto. For each group of two or more, dispatch
   `RADIN_CLI prompt factfind "<first id>" "Per their plans' ## Changes, does a
   symbol that one of tasks <csv> changes call or get called by a symbol
   another of them changes? Use the graph's callers and callees. Answer FOUND
   — no, or FOUND — yes: <idA>,<idB> and the symbols."`, all groups in one
   message. On `FOUND — yes`, move the later task of the pair (higher `order`)
   to a group of its own and run
   `RADIN_CLI telemetry record parallel vetoed task=<later> with=<earlier> wave=N evidence="<the symbols>"`.
   Any other answer keeps the group. Never merge two groups.
5. Run the groups one after another. For one group, run
   `RADIN_CLI state group-set --wave N <id>...`, which records the dispatch.
   Run `RADIN_CLI state task-next "<id>"` for each member, dispatch all of
   them in one message, and wait for every `STATUS:` line. Run `task-report`
   on each. A `debug` or `clarify` route follows the table above, then the
   task re-runs alone: `group-set --wave N <id>`, then `task-next "<id>"`.
   A task still not done leaves the wave.
6. A landed group can stale the plans after it. For each later task with an
   `apart` line against a landed task, or vetoed against one, run
   `RADIN_CLI state plan-discard "<id>" N <paths>` with the shared paths or the
   veto symbols, and re-plan the discarded tasks in one message as in step 2.
   Then re-run the partition over the tasks left (step 3 without
   `--wave`, and step 4). A task split off only by the cap keeps its plan.
   A deferred task has no plan to discard.
7. The wave ends when every task in it has a report or left the wave. A
   deferred task stays pending, and step 1 offers it again. Add 1 to `N` and go
   to step 1.

## Phase 4.5: Session Gate

Execution sub-agents run the tests their diffs reached. The gate runs lint and
format once per session, then reviews the session's commits and files each
`act-on` finding to the backlog. Skip it when the session recorded no commit.

Read `RADIN_LIB/radin-batch-gate.md` and follow it to dispatch the gate.

## Phase 4.7: Merge

Skip it when `RADIN_CLI state session-get` prints `worktree<TAB>no` and `branch<TAB>no`.

Run `RADIN_CLI state reconcile` and print its output, unasked. It lands every
task branch, finished or not, files each `follow-up` entry itself, and prints
each branch it kept with its reason. Exit 3: a branch conflicted, so read
`RADIN_LIB/radin-batch-merge.md` and follow it.

## Phase 5: Final Summary

Always runs after Phase 4.7, once every task branch has landed. The CLI prints the summary whole:

```bash
RADIN_CLI state report
```

Print its output verbatim. Read
`RADIN_LIB/radin-batch-reporting.md` for the two things it
cannot do.

Then run `RADIN_CLI state steps-waiting`. Exit 1: go to Phase 6. Exit 0
<!-- host:claude -->
prints the `waiting` entries this run left, so ask via one `AskUserQuestion`:
<!-- /host -->
<!-- host:agents -->
prints the `waiting` entries this run left, so ask per `RADIN_LIB/radin-ask-rule.md`:
<!-- /host -->
"Settle N open decisions now?" Options: `Yes` / `Later`. `Yes`: settle them per
"Settling Waiting Entries" in `RADIN_LIB/radin-batch-clarify.md`, then tell the
user the answered entries are `pending` and re-invoking the skill runs them.
`Later`: change nothing.

## Phase 6: Review

Phase 4.5 already reviewed the session. Close the summary with `To triage the
review's other findings, run /radin-review with scope: <the output of
RADIN_CLI state session-commits>.`

## Additional Guardrails

- **Resume, and recovery after a compaction**: `BACKLOG_STEPS.json` already
  exists at startup, or earlier turns got summarized away. Either way, read
  `RADIN_LIB/radin-batch-resume.md` and follow it. It holds
  the resume triage, the `MAX_ATTEMPTS` exception, and the state-persistence
  contract that lets you continue from disk rather than memory. A run that
  starts clean and stays in context never loads it.
- **Every commit traces to a backlog entry.**

# Shared: Backlog Parsing, Priority Criteria, and State Schema

Single source of truth for the parsing/prioritization/state-persistence logic
shared by `radin-execute` and the `radin-plan` skill. Both read this file
instead of embedding their own copy of the parsing rules — `radin-execute` at
the start of its Phase 1, `radin-plan` at the start of its Step 2. Only
`radin-execute` uses the priority-criteria and state-schema sections below:
`radin-plan` is scoped to a single entry a caller points it at, so it has
nothing to prioritize and no state file of its own.

## Parsing the backlog

1. Don't parse entries yourself — the backlog CLI resolves them:

   ```bash
   bash "$HOME/.claude/.radin/lib/radin-backlog.sh" list
   ```

   One `id<TAB>category<TAB>title<TAB>file` line per task, across all
   categories (`feat`, `fix`, `chore`, `refactor`). Each task's full body —
   prose, lists, code blocks, `**Plan:**` lines — lives in its own file at
   `$BACKLOG_TASKS_DIR/<id>.md`, or read them all at once with
   `radin-backlog.sh show`.
2. Read each task's body from its file. The title alone is never the task:
   the body underneath it is the actual scope. Category doesn't set
   priority by itself; consider every task.

## Priority criteria (in order of weight)

- **Blocking issues** (bugs that prevent core functionality) → highest priority
- **Security or data-loss risks** → very high priority
- **High-impact features** with clear specifications → high priority
- **Dependency order** (task A must precede task B) → respect topological order.
  Not just an explicit "after X" in the entry text — treat two entries as
  dependent whenever their bodies (or, once written, their plans) name the
  same files, functions, or behavior, and one entry's change would alter
  what the other assumes. When entries overlap this way, order the one
  whose result the other builds on first, and record that earlier task's
  `id` in the later task's `depends_on` array (state schema below).
- **Effort vs. value** (quick wins with high value) → prefer earlier
- **Nice-to-haves and ideas** → lowest priority

Assign a sequential `order` number starting from 1. `depends_on` only records
ordering already implied by the criterion above — it never overrides it, and
a task with no overlap gets an empty array.

## State file schema

Write the prioritized list to `radin-execute`'s state file
(`BACKLOG_STEPS.json`) as JSONL -- one compact JSON object per line, same
convention as the backlog index (`index.jsonl`) -- so any single-line update
(via `radin-state.sh set-status`) never risks another line:

```json
{"id":"add-route-exports","order":1,"status":"pending","depends_on":[],"note":""}
```

Every state-file mutation (marking an entry `blocked`/`failed`, or recording a
completed task's commit in `completed.json`) goes through
`$HOME/.claude/.radin/lib/radin-state.sh` -- never hand-edit either file's
JSON directly. See its own usage comment for the full command list.

Ensure:

- The target directory (created in Phase 0) exists
- `id` is the task's id as printed by `radin-backlog.sh list`/`find` — its
  file is always `$BACKLOG_TASKS_DIR/<id>.md`, so no line numbers or other
  location bookkeeping is needed here; a task's file path can never go
  stale, since inserting into one task's file (e.g. `radin-plan`'s
  `**Plan:**` line) can never affect another task's file
- `depends_on` lists the `id`s of other tasks in this same file whose result
  this task's plan or implementation assumes (per the dependency-order
  criterion above) — empty when there's no overlap. This is what the
  executor forwards to a task's sub-agent so it can check its plan's
  assumptions against what the dependency actually shipped, in case the
  codebase moved since the plan was written
- `status` must be one of: `pending`, `failed`, `blocked`
- `note` is optional, empty for `pending` entries. For `failed` entries, set it
  to a short human-readable reason plus any recovery pointer (e.g. a
  `git stash` ref) — this is what `radin-execute`'s final summary reads to
  tell the user what went wrong and how to recover. For `blocked` entries, set
  it to the decision question, the candidate options, and the agent's
  recommendation — the final summary asks the user to decide
- Never store the full task text; `$BACKLOG_TASKS_DIR/<id>.md` remains the
  source of truth for that task's body

# Shared: Backlog Parsing, Priority Criteria, and State Schema

Single source of truth for the parsing/prioritization/state-persistence
logic shared by `radin-execute` and the `radin-plan` skill. Both read this
file instead of embedding their own copy of the parsing rules —
`radin-execute` at the start of its Phase 1, `radin-plan` at the start of
its Step 2. Only `radin-execute` uses the priority-criteria and
state-schema sections below. `radin-plan` is scoped to a single entry a
caller points it at, so it has nothing to prioritize and no state file of
its own.

## Parsing the backlog

1. Don't parse entries yourself — the backlog CLI resolves them:

   ```bash
   RADIN_CLI backlog list
   ```

   One `id<US>category<US>title<US>file<US>priority<US>depends-on-csv`
   line per task, where `US` is the unit-separator byte `\037` (not a tab),
   across all categories (`feat`, `fix`, `chore`,
   `refactor`). The output is already sorted priority-descending with unset
   priorities last. That order is the human's ranking, not a display choice.
   Each task's full body — prose, lists, code blocks, `**Plan:**` lines —
   lives in its own file, at the path `RADIN_CLI backlog path "<id>"` prints,
   or read them all at once with `radin-backlog.sh show`.
2. Read bodies only where a body is needed. The title alone is never the
   task: the body underneath it is the actual scope. `radin-plan` always
   reads its one entry's body. `radin-execute` reads a body only for an entry
   the ranking pass must rank — one whose `priority` field is empty.
   Category doesn't set priority by itself.

## Priority criteria

A written `priority` is a decision, not a hint. These six rules come first;
the weighted criteria list below applies only where rule 2 sends you to it.

1. **A set `priority` is the sort key.** Entries that have one keep the
   `list` order. Do not weigh impact, effort or value against a number a
   human wrote, and do not reorder set entries.
2. **Unset entries rank below every set entry.** The weighted criteria list
   below applies only inside the unset group. An inferred rank never goes
   above a written number.
3. **A set `depends_on` is used verbatim.** Never add to it, never remove
   from it, and never write it back to the index — a prioritization pass runs
   no `set-priority` and no `set-deps`. For an entry whose `depends-on-csv`
   field is empty, infer overlap per the dependency criterion below, but only
   when the backlog has at least one unset priority (rule 5).
4. **Dependency order is the one override of priority.** Ignoring a
   dependency yields a broken run, not a differently ordered one, so a
   topological violation is fixed by reordering even against the priorities:
   move the dependency to immediately before its dependent and leave every
   other relative position alone. Never do it silently — when either entry of
   the moved pair has a set priority, report the pair with the order in Phase
   2 as `dependency override: <dep> moved above <dependent> (priority N)`, so
   the user's confirm-or-revise answer decides.
5. **Every entry has a priority: skip the ranking work.** No task body read
   for prioritization, no criteria pass, no dependency inference. The order
   is the `list` order, adjusted only by rule 4, and it feeds `steps-init`
   straight from the index. The condition is a priority on every entry, not
   "both fields set": the CLI cannot store an explicitly empty `depends_on`,
   so an absent one is the human's "no dependencies", not a gap to fill.
6. **`depends_on` reaches the state file from the index.** Phase 3 hands
   `steps-init` the backlog index. The index value wins per entry, and the
   stdin csv carries only deps this pass inferred for an entry the index has
   none for.

### Weighted criteria for unset entries (in order of weight)

- **Blocking issues** (bugs that prevent core functionality) → highest priority
- **Security or data-loss risks** → very high priority
- **High-impact features** with clear specifications → high priority
- **Dependency order** (task A must precede task B) → respect topological
  order. Look beyond an explicit "after X" in the entry text: treat two
  entries as dependent whenever their bodies (or, once written, their
  plans) name the same files, functions, or behavior, and one entry's
  change would alter what the other assumes. When entries overlap this
  way, order the one whose result the other builds on first.
- **Effort vs. value** (quick wins with high value) → prefer earlier
- **Nice-to-haves and ideas** → lowest priority

Assign a sequential `order` number starting from 1.

## State file schema

`radin-execute`'s state file (`BACKLOG_STEPS.json`) is JSONL -- one compact
JSON object per line, same convention as the backlog index (`index.jsonl`)
-- so any single-line update (via `radin-state.sh set-status`) never risks
another line:

```json
{"id":"add-route-exports","order":1,"status":"pending","depends_on":[],"attempts":0,"debugged":0,"note":""}
```

Never write this JSON by hand. `radin-state.sh steps-init <steps-file>
[<backlog-index>]` creates the file from
`id<TAB>order<TAB>depends-on-csv<TAB>pending|deferred` lines on stdin; the index argument is what seeds `depends_on`, since each
entry's value comes from its index line and the stdin csv is used only where
the index line has none. Every later
mutation (marking an entry `blocked`/`failed`, recording a completed task
via `task-done`) goes through `RADIN_CLI state` too. See its own usage
comment for the full command list.

Ensure:

- The target directory (created in Phase 0) exists
- `id` is the task's id as printed by `radin-backlog.sh list`/`find` — its
  file is whatever `RADIN_CLI backlog path "<id>"` prints, so no line
  numbers or other
  location bookkeeping is needed here; a task's file path can never go
  stale, since inserting into one task's file (e.g. `radin-plan`'s
  `**Plan:**` line) can never affect another task's file
- `depends_on` lists the `id`s of other tasks in this same file whose
  result this task's plan or implementation assumes. The value is the task's
  index-line `depends_on` when it has one, and prioritization's inferred
  overlap otherwise; empty when there's neither. This
  is what the executor forwards to a task's sub-agent, so it can check its
  plan's assumptions against what the dependency actually shipped, in case
  the codebase moved since the plan was written
- `status` must be one of: `pending`, `failed`, `blocked`
- `note` is optional, empty for `pending` entries. For `failed` entries, set it
  to a short human-readable reason plus any recovery pointer (e.g. a
  `git stash` ref) — this is what `radin-execute`'s final summary reads to
  tell the user what went wrong and how to recover. For `blocked` entries, set
  it to the decision question, the candidate options, and the agent's
  recommendation — the final summary asks the user to decide
- Never store the full task text; the task's own file (the path
  `RADIN_CLI backlog path "<id>"` prints) remains the source of truth for
  that task's body

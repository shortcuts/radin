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
   `refactor`). Each task's full body — prose, lists, code blocks,
   `**Plan:**` lines — lives in its own file, at the path
   `RADIN_CLI backlog path "<id>"` prints, or read them all at once with
   `radin-backlog.sh show`.
2. Read bodies only where a body is needed. The title alone is never the
   task: the body underneath it is the actual scope. `radin-plan` always
   reads its one entry's body. `radin-execute` reads a body only for an id
   `RADIN_CLI backlog order --rank-needed` printed. Category doesn't set
   priority by itself.

## Priority criteria

The order itself is not yours to compose: `RADIN_CLI backlog order` is the
sort, the dependency fix and the report, and each of its modes is used as-is.

```bash
RADIN_CLI backlog order --rank-needed                      # the gate
RADIN_CLI backlog order --report  [--rank <csv>] [--infer-deps <id>=<csv>]...
RADIN_CLI backlog order --steps   [--rank <csv>] [--infer-deps <id>=<csv>]... [--defer <csv>]
```

Two rules are left, and they are rules rather than computations:

1. **A prioritization pass writes nothing.** No `set-priority`, no
   `set-deps`: a set `priority` and a set `depends_on` are the human's, used
   verbatim. Whatever this pass concludes leaves as an `order` flag, which
   validates it, and never as an index write.
2. **`--rank-needed` decides whether there is work here at all.** Exit 1
   means every entry carries a priority, so read no task body for
   prioritization, run no criteria pass, and infer no dependency: `order`'s
   other modes already hold the answer. Exit 0 prints the ids whose
   `priority` is unset, and the weighted criteria below apply to those alone.
   The condition is a priority on every entry, not "both fields set": the CLI
   cannot store an explicitly empty `depends_on`, so an absent one is the
   human's "no dependencies", not a gap to fill.

`order` moves a dependency **up** to immediately before its dependent and
leaves every other relative position alone — the human's ranking survives as
far as the dependency graph allows. It reports each such move as a
`dependency override:` line in `--report`, so the user's confirm-or-revise
answer still decides; re-run `--report` rather than carrying its output
between phases.

### Weighted criteria for unset entries (in order of weight)

- **Blocking issues** (bugs that prevent core functionality) → highest priority
- **Security or data-loss risks** → very high priority
- **High-impact features** with clear specifications → high priority
- **Dependency order** (task A must precede task B) → infer one only where
  the index has none, and only within these bounds: one entry's body must
  name a file, symbol or behaviour the *other* entry's body says it will
  **change** (naming the same area is not enough), and at most one inferred
  dependency per entry, the earlier-ranked entry being the dependency. This
  is the one genuinely semantic judgment in the pass — `order` cannot read
  two bodies for overlap — so it stays here, bounded.
- **Effort vs. value** (quick wins with high value) → prefer earlier
- **Nice-to-haves and ideas** → lowest priority

The pass produces two things and nothing else: the unset group in your order,
as `order --rank <csv-of-ids>`, and one `order --infer-deps <id>=<csv>` flag
per entry you inferred a dependency for. No `order` number (`--steps` numbers
them), and no write to the index.

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
`id<TAB>order<TAB>depends-on-csv<TAB>pending|deferred` lines on stdin, which
is exactly what `RADIN_CLI backlog order --steps` prints — pipe one into the
other. Every later
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
  result this task's plan or implementation assumes. `order --steps` resolves
  the value; nothing here reapplies that precedence. This
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

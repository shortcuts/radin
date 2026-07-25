# Shared: Backlog Parsing, Priority Criteria, and State Schema

Single source of truth for the parsing/prioritization/state-persistence logic
shared by `radin-execute` and the `radin-plan` skill. Both read this file
instead of embedding their own copy of the parsing rules — `radin-execute` at
the start of its Phase 1, `radin-plan` at the start of its Step 2. Only
`radin-execute` uses the priority-criteria and state-schema sections below:
`radin-plan` is scoped to a single entry a caller points it at, so it has
nothing to prioritize and no state file of its own.

## Parsing `$BACKLOG_FILE`

1. The file follows a fixed markdown hierarchy: one `#` (h1) file title at
   the top, then top-level category sections — `## feat`, `## fix`,
   `## chore`, `## refactor` — each containing `### title` entries with a
   description underneath. Category doesn't set priority by itself; read
   every section.
2. An entry spans from its `### title` line to the line before the next
   `###` or `##` heading (or end of file). Everything in that span — prose,
   lists, code blocks, `**Plan:**` lines, deeper `####`+ headings — belongs
   to that entry. `line_start`/`line_end` must cover exactly this span. The
   title line alone is never the task: the body underneath it is the actual
   scope.
3. Parse all tasks across all sections.

## Priority criteria (in order of weight)

- **Blocking issues** (bugs that prevent core functionality) → highest priority
- **Security or data-loss risks** → very high priority
- **High-impact features** with clear specifications → high priority
- **Dependency order** (task A must precede task B) → respect topological order
- **Effort vs. value** (quick wins with high value) → prefer earlier
- **Nice-to-haves and ideas** → lowest priority

Assign a sequential `order` number starting from 1.

## State file schema

Write the prioritized list to `radin-execute`'s state file
(`BACKLOG_STEPS.json`) with this exact format:

```json
[
  {
    "id": "add-route-exports",
    "order": 1,
    "line_start": 42,
    "line_end": 58,
    "status": "pending",
    "note": ""
  }
]
```

Ensure:

- The target directory (created in Phase 0) exists
- `status` must be one of: `pending`, `failed`, `blocked`
- `note` is optional, empty for `pending` entries. For `failed` entries, set it
  to a short human-readable reason plus any recovery pointer (e.g. a
  `git stash` ref) — this is what `radin-execute`'s final summary reads to
  tell the user what went wrong and how to recover. For `blocked` entries, set
  it to the decision question, the candidate options, and the agent's
  recommendation — the final summary asks the user to decide
- Never store the full task text; `$BACKLOG_FILE` remains the source of truth
- `line_start` and `line_end` must point to the task's current location in
  `$BACKLOG_FILE` — for any agent that inserts text into earlier entries
  (e.g. `radin-plan`'s `**Plan:**` line), re-read these fresh each loop
  iteration, since that shifts line numbers for everything below

# Shared: Backlog Parsing, Priority Criteria, and State Schema

Single source of truth for the parsing/prioritization/state-persistence logic
shared by `radin-execute` and `radin-plan`. Both agents read this file
at the start of their Phase 1 instead of embedding their own copy. The two
agents differ only in what they do per task after this point (execute vs.
plan) and in which state file they write to.

## Parsing `$BACKLOG_FILE`

1. It's organized into top-level category sections — `## feat`, `## fix`,
   `## chore`, `## refactor` — each containing `### title` entries with a
   description underneath. Category doesn't set priority by itself; read
   every section.
2. Parse all tasks across all sections.

## Priority criteria (in order of weight)

- **Blocking issues** (bugs that prevent core functionality) → highest priority
- **Security or data-loss risks** → very high priority
- **High-impact features** with clear specifications → high priority
- **Dependency order** (task A must precede task B) → respect topological order
- **Effort vs. value** (quick wins with high value) → prefer earlier
- **Nice-to-haves and ideas** → lowest priority

Assign a sequential `order` number starting from 1.

## State file schema

Write the prioritized list to the caller's state file (`BACKLOG_STEPS.json`
for `radin-execute`, `BACKLOG_PLAN_STEPS.json` for `radin-plan`) with
this exact format:

```json
[
  {
    "id": "add-route-exports",
    "order": 1,
    "line_start": 42,
    "line_end": 58,
    "status": "pending"
  }
]
```

Ensure:

- The target directory (created in Phase 0) exists
- `status` must be one of: `pending`, `failed`
- Never store the full task text; `$BACKLOG_FILE` remains the source of truth
- `line_start` and `line_end` must point to the task's current location in
  `$BACKLOG_FILE` — for any agent that inserts text into earlier entries
  (e.g. `radin-plan`'s `**Plan:**` line), re-read these fresh each loop
  iteration, since that shifts line numbers for everything below

# Domain Models

## Backlog entry format (`index.jsonl` + task files)

`docs/schemas/backlog-entry.schema.json` is the formal contract (JSON
Schema, draft-07). It documents the shape every radin agent/skill must
produce when reading or appending to the backlog. Read it before changing
this structure or adding a new entry-producing skill. It's repo-internal
reference only — it doesn't ship to consumers, so every agent/skill embeds
its concrete shape inline instead of reading the schema file at runtime.

The backlog lives at `<repo-root>/.claude/.radin/backlog/`: an
`index.jsonl` file (one compact JSON object per line, one per task) plus a
`tasks/` directory holding one markdown file per task. A task's category —
`feat`, `fix`, `chore`, `refactor`, the same vocabulary as a
conventional-commit type — is a field on its index line, not a section
heading. There's no per-entry bracket tag. `radin-backlog.sh show`
reconstructs the old grouped-by-category markdown view for humans, in
canonical order (feat → fix → chore → refactor), but that's a rendering,
not the storage.

One index line:

```json
{"id":"add-route-exports","category":"feat","title":"Add route exports","file":"tasks/add-route-exports.md"}
```

`id` is a slug derived from the title when the task is created, deduped
with a `-2`/`-3` suffix on collision. It never changes afterward, even if
the title text is later edited, so it's the stable key that `depends_on`
(the state schema below) and `radin-plan`/`radin-execute` key off. `file`
is always `tasks/<id>.md`, relative to the `backlog/` directory.

The task's file (`$BACKLOG_TASKS_DIR/<id>.md`) holds everything that used
to live under a `### title` heading's span: description prose, lists, code
blocks, and any `**Plan:**` pointer lines — this is what
`radin-execute`/`radin-plan` read as the task's scope.

```
<as exhaustive a description as the situation warrants — what the change is,
why it matters, affected files/areas if known, acceptance criteria if
known. radin-execute/radin-plan derive scope and priority entirely from
this text, so write enough that a sub-agent given only this entry, with no
other session context, could act on it correctly.>
```

Every radin agent/skill that appends an entry classifies into one of these
four categories and writes the same title + description shape via
`radin-backlog.sh add`: `radin-review` (code-review findings, usually
`fix` for an actual bug or `refactor` for a structural finding),
`radin-record` (feedback/bugs/follow-ups/ideas surfaced in conversation),
and `radin-execute`/`radin-plan` (their own backlog grooming). None of
them invent a fifth category or a per-entry tag on top of it.

Once `radin-plan` processes a task, it appends one more line to that
task's own file:

```
**Plan:** <path to plan file>
```

`radin-plan` is a skill, not an agent — it runs inline in whichever
context invokes it. It runs scoped to a single task, not the whole
backlog; the caller points it at one task by id or title. If it judges
that task's scope broad enough to split into independent sub-tasks, and
the user confirms the split, it appends one `**Plan:**` line per plan, in
order, to that same file instead of just one.

## Migration note

Earlier revisions of this file described a single monolithic
`<repo-root>/.claude/.radin/BACKLOG.md`, addressed by `### title` headings
and line-number spans. Before that, a bracket-tag scheme used
`## [Thermo-Nuclear Review] <title>`/`**Scope:**`/`**Location:**`/
`**Finding:**`/`**Preferred remedy:**` fields, plus a separate
`## [Bug]`/`[Follow-up]`/`[Idea]`/`[Feedback]` scheme for `radin-record`.
The `index.jsonl` + per-task-file scheme above replaces both: splitting
each task into its own file means no radin agent/skill ever addresses
backlog content by line number again. Existing `BACKLOG.md` files written
under any earlier scheme aren't migrated automatically — finish or
manually split an old-format backlog before upgrading.

## Plan-file format (`radin-plan` output)

Free-form markdown at `$NAMESPACE_DIR/plans/<id>.md`: files to touch, the
change in each, the order of operations, and how to verify it. No fixed
schema — sub-agents write it, `radin-execute` (or a human) reads it.

## State JSON schema (`BACKLOG_STEPS.json`)

JSONL, one compact object per line — same convention as `index.jsonl`, so a
single-entry update never touches another entry's line:

```json
{"id":"add-route-exports","order":1,"status":"pending","depends_on":[],"note":""}
```

`id` matches the task's id in `index.jsonl`. Its file is always
`$BACKLOG_TASKS_DIR/<id>.md`, so this schema no longer carries a line
range — a task's file path is fixed at creation and never goes stale.

`radin-execute`'s only state file — `radin-plan` is a skill that runs inline
within one conversation, so it re-resolves a sub-task list each time instead
of persisting one to disk.

Every mutation goes through `lib/radin-state.sh` (`set-status`/`remove`) —
`radin-execute` never hand-edits this file's JSON.

- `depends_on` lists `id`s of other tasks in this file whose result this
  task's plan or implementation assumes — set during prioritization per
  `radin-prioritization.md`'s dependency-order criterion (same files,
  functions, or behavior touched by both). Empty when there's no overlap.
- `status` is one of `pending`, `failed`, `blocked`. An entry's absence from
  the file means that task is complete.
- `note` is optional, empty for `pending` entries. `failed` entries carry a
  short reason plus a recovery pointer (e.g. a `git stash` ref) — this is what
  the Phase 4 final summary reports back to the user. `blocked` entries carry
  the decision question, the candidate options, and the agent's recommendation
  — the final summary asks the user to decide.
- A `failed` or `blocked` entry never blocks the execution loop from reaching
  Phase 4 — the loop exits once no `pending` entries remain, not only when the
  file is empty.
- Never stores the full task text. `$BACKLOG_TASKS_DIR/<id>.md` stays the
  source of truth for each task's body.

## Completed-task log (`completed.json`)

JSONL, one compact object per line:

```json
{"id":"add-route-exports","commit":"abc1234"}
```

Appended to `$NAMESPACE_DIR/state/completed.json` via `lib/radin-state.sh
completed-add` on every `STATUS: SUCCESS`. A task's entry in
`BACKLOG_STEPS.json` is deleted once it completes, so it can no longer
carry its commit hash. A later task whose `depends_on` names a completed
`id` looks its commit up here via `radin-state.sh completed-get` and
forwards it to that task's execution sub-agent, so the sub-agent can check
whether the dependency's actual changes still match what this task's plan
assumed.

## Install manifest (`manifest.json`)

Written by `install.sh` to `~/.claude/.radin/manifest.json` on every run —
not part of any repo's `.claude/.radin/` backlog namespace, this is
global, one per machine.

```json
{
  "version": "v0.4.0",
  "installed_at": "2026-07-28T00:00:00Z",
  "agents": ["radin-execute.md"],
  "skills": ["radin-plan", "radin-record", "radin-review", "radin-setup-hooks", "radin-show", "radin-stats", "radin-doctor", "radin-uninstall", "thermo-nuclear"],
  "lib": ["radin-namespace.sh", "radin-backlog.sh", "radin-state.sh", "radin-prioritization.md", "radin-doctor.sh", "radin-uninstall.sh"],
  "companion_tools": {
    "rtk": true,
    "code-review-graph": false,
    "caveman": true,
    "i-have-adhd": false,
    "ponytail": true
  }
}
```

- `version` is `dev` when installed from a local git clone (no downloaded
  release tarball, no `.radin-version` file to read).
- `agents`/`skills`/`lib` are static lists matching exactly what
  `install.sh` copies and what `radin-doctor.sh` checks for — not derived
  from the manifest at runtime by either script (see `docs/architecture.md`
  "Install manifest").
- `companion_tools` values reflect final reachable state after this
  install.sh run (already present, just installed, or skipped are not
  distinguished — only "is it there now").
- Regenerated wholesale on every `install.sh` run; never partially updated,
  never read back by `install.sh` itself.

# Domain Models

## `BACKLOG.md` entry format

`docs/schemas/backlog-entry.schema.json` is the formal contract (JSON Schema,
draft-07). It documents the shape every radin agent/skill must produce when
reading or appending to `$BACKLOG_FILE` — read it before changing this
structure or adding a new entry-producing skill. It's repo-internal
reference only: it doesn't ship to consumers, so every agent/skill embeds
its concrete markdown format inline instead of reading the schema file at
runtime.

`$BACKLOG_FILE` is organized into top-level semver-style category sections —
`feat`, `fix`, `chore`, `refactor` — the same vocabulary as a
conventional-commit type. A section exists only once it has its first entry
(an empty backlog has none). When you create one, insert it in canonical
order (feat → fix → chore → refactor) relative to whichever sections already
exist. There's no per-entry bracket tag anymore — an entry's category is
just whichever `##` section it lives under:

```
## feat

### <short title>
<as exhaustive a description as the situation warrants — what the change is,
why it matters, affected files/areas if known, acceptance criteria if
known. radin-execute/radin-plan derive scope and priority entirely from
this text, so write enough that a sub-agent given only this entry, with no
other session context, could act on it correctly.>

## fix

### <short title>
<description, same bar as above>
```

An entry spans from its `### title` line to the line before the next `###`
or `##` heading (or end of file). Everything in that span — prose, lists,
code blocks, `**Plan:**` lines, deeper `####`+ headings — belongs to that
entry, and is what `radin-execute`/`radin-plan` read as the task's scope.
The title is only the lookup key.

Every radin agent/skill that appends an entry — `radin-review` (code-review
findings, usually `fix` for an actual bug or `refactor` for a structural
finding), `radin-record` (feedback/bugs/follow-ups/ideas surfaced in
conversation), `radin-execute`/`radin-plan` (their own backlog
grooming) — classifies into one of these four categories and writes the
same `### title` + description shape. None of them invent a fifth category
or a per-entry tag on top of the section.

Once `radin-plan` processes an entry, it appends one more line after the
entry's description:

```
**Plan:** <path to plan file>
```

`radin-plan` (a skill, not an agent — it runs inline in whichever context
invokes it) runs scoped to a single entry, not the whole backlog — the
caller points it at one task. If it judges that task's scope broad enough to
split into independent sub-tasks, and the user confirms the split, it writes
one plan file per sub-task and appends one `**Plan:**` line per plan, in
order, instead of just one.

## Migration note

Earlier revisions of this file described a bracket-tag scheme
(`## [Thermo-Nuclear Review] <title>` with `**Scope:**`/`**Location:**`/
`**Finding:**`/`**Preferred remedy:**` fields, and a separate
`## [Bug]`/`[Follow-up]`/`[Idea]`/`[Feedback]` scheme for `radin-record`).
The single feat/fix/chore/refactor scheme above replaces it. Existing
`BACKLOG.md` files written under the old scheme aren't migrated
automatically — new entries just use the new shape going forward.

## Plan-file format (`radin-plan` output)

Free-form markdown at `$NAMESPACE_DIR/plans/<id>.md`: files to touch, the
change in each, the order of operations, and how to verify it. No fixed
schema — sub-agents write it, `radin-execute` (or a human) reads it.

## State JSON schema (`BACKLOG_STEPS.json`)

```json
[
  {
    "id": "add-route-exports",
    "order": 1,
    "line_start": 42,
    "line_end": 58,
    "status": "pending",
    "depends_on": [],
    "note": ""
  }
]
```

`radin-execute`'s only state file — `radin-plan` is a skill that runs inline
within one conversation, so it re-resolves a sub-task list each time instead
of persisting one to disk.

- `depends_on` lists `id`s of other tasks in this file whose result this
  task's plan or implementation assumes — set during prioritization per
  `radin-prioritization.md`'s dependency-order criterion (same files,
  functions, or behavior touched by both). Empty when there's no overlap.
- `status` is one of `pending`, `failed`, `blocked`. An entry's absence from
  the array means that task is complete.
- `note` is optional, empty for `pending` entries. `failed` entries carry a
  short reason plus a recovery pointer (e.g. a `git stash` ref) — this is what
  the Phase 4 final summary reports back to the user. `blocked` entries carry
  the decision question, the candidate options, and the agent's recommendation
  — the final summary asks the user to decide.
- A `failed` or `blocked` entry never blocks the execution loop from reaching
  Phase 4 — the loop exits once no `pending` entries remain, not only when the
  array is empty.
- Never stores the full task text. `BACKLOG.md` (i.e. `$BACKLOG_FILE`) stays
  the source of truth.
- `line_start`/`line_end` point into the live `$BACKLOG_FILE`. `radin-execute`
  re-resolves them fresh each loop iteration, since inserting a `**Plan:**`
  line shifts every line below it.

## Completed-task log (`completed.json`)

```json
[{"id": "add-route-exports", "commit": "abc1234"}]
```

Appended to at `$NAMESPACE_DIR/state/completed.json` on every `STATUS:
SUCCESS`, since a task's entry in `BACKLOG_STEPS.json` is deleted once it
completes and can no longer carry its commit hash. A later task whose
`depends_on` names a completed `id` looks its commit up here and forwards it
to that task's execution sub-agent, so the sub-agent can check whether the
dependency's actual changes still match what this task's plan assumed.

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
  "lib": ["radin-namespace.sh", "radin-backlog.sh", "radin-prioritization.md", "radin-doctor.sh", "radin-uninstall.sh"],
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

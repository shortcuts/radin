# Domain Models

## `registry.json`

```json
{
  "<repo-slug>": {
    "path": "<absolute path to repo root>",
    "updated_at": "<UTC ISO-8601 timestamp>"
  }
}
```

A best-effort index. The shared namespace block upserts it on every
agent/skill invocation, but nothing requires it. `<repo-slug>` is
`$(basename "$REPO_ROOT")-$(printf '%s' "$REPO_ROOT" | md5 | cut -c1-8)`, or
`no-repo-<cwd-hash>` outside any git repo.

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

`radin-plan` runs scoped to a single entry, not the whole backlog — the user
points it at one task. If it judges that task's scope broad enough to split
into independent sub-tasks, and the user confirms the split, it writes one
plan file per sub-task and appends one `**Plan:**` line per plan, in order,
instead of just one.

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

## State JSON schema (`BACKLOG_STEPS.json` / `BACKLOG_PLAN_STEPS.json`)

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

`radin-plan`'s `BACKLOG_PLAN_STEPS.json` adds two fields, since it's scoped
to the sub-tasks of a single entry rather than the whole backlog:
`parent_line_start`/`parent_line_end` (the scoped entry's location, since a
split sub-task's own `line_start`/`line_end` would otherwise point nowhere)
and `scope_text` (`null` unless the entry was split, in which case that
sub-task's one-line description — the only case where task text is
persisted outside `$BACKLOG_FILE`, since a split sub-task has no entry of
its own to re-read it from).

- `status` is one of `pending`, `failed`. An entry's absence from the array
  means that task is complete.
- Never stores the full task text. `BACKLOG.md` (i.e. `$BACKLOG_FILE`) stays
  the source of truth.
- `line_start`/`line_end` point into the live `$BACKLOG_FILE`. `radin-plan`
  re-resolves them fresh each loop iteration, since inserting a `**Plan:**`
  line shifts every line below it.

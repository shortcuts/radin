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

Best-effort index, upserted (never required) by the shared namespace block on
every agent/skill invocation. `<repo-slug>` is
`$(basename "$REPO_ROOT")-$(printf '%s' "$REPO_ROOT" | md5 | cut -c1-8)`, or
`no-repo-<cwd-hash>` outside any git repo.

## `ISSUES.md` entry format

Formal contract: `docs/schemas/issues-entry.schema.json` (JSON Schema,
draft-07). It documents the shape every radin agent/skill must produce when
reading or appending to `$ISSUES_FILE` — read it first before changing this
structure or adding a new entry-producing skill. It is repo-internal
reference only: it does not ship to consumers, so every agent/skill embeds
its concrete markdown format inline rather than reading the schema file at
runtime.

`$ISSUES_FILE` is organized into top-level semver-style category sections —
`feat`, `fix`, `chore`, `refactor` — same vocabulary as a conventional-commit
type. A section exists only once it has its first entry (an empty backlog
has none); when creating one, insert it in canonical order
(feat → fix → chore → refactor) relative to whichever sections already
exist. There is no per-entry bracket tag anymore — an entry's category is
just whichever `##` section it lives under:

```
## feat

### <short title>
<as exhaustive a description as the situation warrants — what the change is,
why it matters, affected files/areas if known, acceptance criteria if
known. radin-orchestrator/radin-plan derive scope and priority entirely from
this text, so write enough that a sub-agent given only this entry, with no
other session context, could act on it correctly.>

## fix

### <short title>
<description, same bar as above>
```

Every radin agent/skill that appends an entry — `radin-review` (code-review
findings, usually `fix` for an actual bug or `refactor` for a structural
finding), `radin-record` (feedback/bugs/follow-ups/ideas surfaced in
conversation), `radin-orchestrator`/`radin-plan` (their own backlog
grooming) — classifies into one of these four categories and writes the
same `### title` + description shape. None of them invent a fifth category
or a per-entry tag on top of the section.

Once `radin-plan` processes an entry, it appends a single additional line
after the entry's description:

```
**Plan:** <path to plan file>
```

## Migration note

Earlier revisions of this file described a bracket-tag scheme
(`## [Thermo-Nuclear Review] <title>` with `**Scope:**`/`**Location:**`/
`**Finding:**`/`**Preferred remedy:**` fields, and a separate
`## [Bug]`/`[Follow-up]`/`[Idea]`/`[Feedback]` scheme for `radin-record`).
That's superseded by the single feat/fix/chore/refactor scheme above —
existing `ISSUES.md` files written under the old scheme are not migrated
automatically; new entries just use the new shape going forward.

## Plan-file format (`radin-plan` output)

Free-form markdown at `$NAMESPACE_DIR/plans/<id>.md`: files to touch, the
change in each, order of operations, and how to verify it. No fixed schema —
sub-agents write it, `radin-orchestrator` (or a human) reads it.

## State JSON schema (`ISSUES_STEPS.json` / `ISSUES_PLAN_STEPS.json`)

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

- `status` is one of `pending`, `failed`. An entry's absence from the array
  means that task is complete.
- Never stores full task text — `ISSUES.md` (i.e. `$ISSUES_FILE`) remains the
  source of truth.
- `line_start`/`line_end` point into the live `$ISSUES_FILE`; `radin-plan`
  re-resolves them fresh each loop iteration since inserting a `**Plan:**`
  line shifts everything below it.

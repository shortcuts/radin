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

Plain entries (from `radin-orchestrator`/`radin-plan` prioritization)
have no fixed schema beyond a heading per task — they're parsed generically
(title + body, `line_start`/`line_end` tracked separately in state).

`radin-review` findings use a fixed structured format:

```
## [Thermo-Nuclear Review] <short title>

**Scope:** <what was reviewed — commit hash / PR / directory / range>
**Location:** <file path(s) and function/line if applicable>
**Finding:**
<the structural problem, stated directly>
**Preferred remedy:**
<the concrete restructuring suggested>
```

Once `radin-plan` processes an entry, it appends a single additional line:

```
**Plan:** <path to plan file>
```

placed after the entry's title/heading, or after `**Scope:**`/`**Location:**`
if the entry already uses that format.

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

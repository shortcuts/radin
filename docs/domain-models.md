# Domain Models

## Backlog entry format (`index.jsonl` + task files)

`docs/schemas/backlog-entry.schema.json` formal contract (JSON Schema, draft-07). Documents shape every radin agent/skill must produce reading or appending backlog. Read before changing structure or adding new entry-producing skill. Repo-internal reference only — doesn't ship to consumers, so every agent/skill embeds concrete shape inline instead of reading schema file at runtime.

Backlog lives at `<repo-root>/.claude/.radin/backlog/`: `index.jsonl` file (one compact JSON object per line, one per task) plus `tasks/` directory holding one markdown file per task. Task's category — `feat`, `fix`, `chore`, `refactor`, same vocabulary as conventional-commit type — field on index line, not section heading. No per-entry bracket tag. `radin-backlog.sh show` reconstructs old grouped-by-category markdown view for humans, canonical order (feat → fix → chore → refactor), but that's rendering, not storage.

One index line:

```json
{"id":"add-route-exports","category":"feat","title":"Add route exports","file":"tasks/add-route-exports.md"}
```

`id` slug derived from title when task created, deduped with `-2`/`-3` suffix on collision. Never changes afterward, even if title text later edited — stable key `depends_on` (state schema below) and `radin-plan`/`radin-execute` key off. `file` always `tasks/<id>.md`, relative to `backlog/` directory.

Task's file (`$BACKLOG_TASKS_DIR/<id>.md`) holds everything used to live under `### title` heading's span: description prose, lists, code blocks, any `**Plan:**` pointer lines — what `radin-execute`/`radin-plan` read as task's scope.

```
<as exhaustive a description as the situation warrants — what the change is,
why it matters, affected files/areas if known, acceptance criteria if
known. radin-execute/radin-plan derive scope and priority entirely from
this text, so write enough that a sub-agent given only this entry, with no
other session context, could act on it correctly.>
```

Every radin agent/skill appending entry classifies into one of four categories, writes same title + description shape via `radin-backlog.sh add`: `radin-review` (code-review findings, usually `fix` for actual bug or `refactor` for structural finding), `radin-record` (feedback/bugs/follow-ups/ideas surfaced in conversation), `radin-execute`/`radin-plan` (own backlog grooming). None invent fifth category or per-entry tag on top.

Once `radin-plan` processes task, appends one more line to that task's own file:

```
**Plan:** <path to plan file>
```

`radin-plan` skill, not agent — runs inline in whichever context invokes it. Scoped to single task, not whole backlog; caller points it at one task by id or title. If scope broad enough to split into independent sub-tasks, and user confirms split, appends one `**Plan:**` line per plan, in order, to same file instead of just one.

## Migration note

Earlier revisions described single monolithic `<repo-root>/.claude/.radin/BACKLOG.md`, addressed by `### title` headings and line-number spans. Before that, bracket-tag scheme used `## [Thermo-Nuclear Review] <title>`/`**Scope:**`/`**Location:**`/`**Finding:**`/`**Preferred remedy:**` fields, plus separate `## [Bug]`/`[Follow-up]`/`[Idea]`/`[Feedback]` scheme for `radin-record`. `index.jsonl` + per-task-file scheme above replaces both: splitting each task into own file means no radin agent/skill ever addresses backlog content by line number again. Existing `BACKLOG.md` files written under earlier scheme not migrated automatically — finish or manually split old-format backlog before upgrading.

## Plan-file format (`radin-plan` output)

Free-form markdown at `$NAMESPACE_DIR/plans/<id>.md`: files to touch, change in each, order of operations, how to verify it. No fixed schema — sub-agents write it, `radin-execute` (or human) reads it.

## State JSON schema (`BACKLOG_STEPS.json`)

JSONL, one compact object per line — same convention as `index.jsonl`, so single-entry update never touches another entry's line:

```json
{"id":"add-route-exports","order":1,"status":"pending","depends_on":[],"note":""}
```

`id` matches task's id in `index.jsonl`. File always `$BACKLOG_TASKS_DIR/<id>.md`, so schema no longer carries line range — task's file path fixed at creation, never goes stale.

`radin-execute`'s only state file — `radin-plan` skill runs inline within one conversation, re-resolves sub-task list each time instead of persisting one to disk.

Every mutation goes through `lib/radin-state.sh` (`set-status`/`remove`) — `radin-execute` never hand-edits this file's JSON.

- `depends_on` lists `id`s of other tasks in this file whose result this task's plan or implementation assumes — set during prioritization per `radin-prioritization.md`'s dependency-order criterion (same files, functions, or behavior touched by both). Empty when no overlap.
- `status` one of `pending`, `failed`, `blocked`. Entry's absence from file means task complete.
- `note` optional, empty for `pending` entries. `failed` entries carry short reason plus recovery pointer (e.g. `git stash` ref) — what Phase 4 final summary reports back to user. `blocked` entries carry decision question, candidate options, agent's recommendation — final summary asks user to decide.
- `failed`/`blocked` entry never blocks execution loop from reaching Phase 4 — loop exits once no `pending` entries remain, not only when file empty.
- Never stores full task text. `$BACKLOG_TASKS_DIR/<id>.md` stays source of truth for each task's body.

## Completed-task log (`completed.json`)

JSONL, one compact object per line:

```json
{"id":"add-route-exports","commit":"abc1234"}
```

Appended to `$NAMESPACE_DIR/state/completed.json` via `lib/radin-state.sh
completed-add` on every `STATUS: SUCCESS`. Task's entry in `BACKLOG_STEPS.json` deleted once complete, so can no longer carry commit hash. Later task whose `depends_on` names completed `id` looks its commit up here via `radin-state.sh completed-get`, forwards to that task's execution sub-agent, so sub-agent can check whether dependency's actual changes still match what this task's plan assumed.

## Install manifest (`manifest.json`)

Written by `install.sh` to `~/.claude/.radin/manifest.json` on every run — not part of any repo's `.claude/.radin/` backlog namespace, global, one per machine.

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

- `version` `dev` when installed from local git clone (no downloaded release tarball, no `.radin-version` file to read).
- `agents`/`skills`/`lib` static lists matching exactly what `install.sh` copies, what `radin-doctor.sh` checks for — not derived from manifest at runtime by either script (see `docs/architecture.md` "Install manifest").
- `companion_tools` values reflect final reachable state after this install.sh run (already present, just installed, or skipped not distinguished — only "is it there now").
- Regenerated wholesale on every `install.sh` run; never partially updated, never read back by `install.sh` itself.

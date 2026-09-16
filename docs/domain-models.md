# Domain Models

## Backlog entry format (`index.jsonl` + task files)

`docs/schemas/backlog-entry.schema.json` formal contract (JSON Schema, draft-07). Documents shape every radin agent/skill must produce reading or appending backlog. Read before changing structure or adding new entry-producing skill. Repo-internal reference only — doesn't ship to consumers, so every agent/skill embeds concrete shape inline instead of reading schema file at runtime.

Backlog lives at `<repo-root>/.claude/.radin/backlog/`: `index.jsonl` file (one compact JSON object per line, one per task) plus `tasks/` directory holding one markdown file per task. Related tasks group under `tasks/<epic-id>/`, where `DESCRIPTION.md` holds the root context every child inherits — written once instead of repeated in each child's body. An epic has no index line and no category: `list` feeds `radin-execute`, and an epic row there would eventually be dispatched as a task. Membership is `dirname(file)`; one nesting level only. Task's category — `feat`, `fix`, `chore`, `refactor`, same vocabulary as conventional-commit type — field on index line, not section heading. No per-entry bracket tag. `radin-backlog.sh show` reconstructs old grouped-by-category markdown view for humans, canonical order (feat → fix → chore → refactor), but that's rendering, not storage.

One index line:

```json
{"id":"add-route-exports","category":"feat","title":"Add route exports","file":"tasks/add-route-exports.md"}
```

`id` slug derived from title when task created, deduped with `-2`/`-3` suffix on collision. Never changes afterward, even if title text later edited (`radin backlog retitle`, or `r` in `radin tui`, rewrites only `title`; `set-category` only `category`) — stable key `depends_on` (state schema below) and `radin-plan`/`radin-execute` key off. `file` task body's location relative to `backlog/` directory — `tasks/<id>.md`, or `tasks/<epic-id>/<id>.md` for a task inside an epic. Ids stay globally unique across epics, so `add`'s dedup loop checks the index's own `id` fields, not the task files on disk. `add` decides it; every other verb reads it back, so it's sole authority on where task's body lives (`radin backlog path <id>` prints absolute form).

Two optional keys carry human judgment that must survive a run:

```json
{"id":"add-route-exports","category":"feat","title":"Add route exports","file":"tasks/add-route-exports.md","priority":70,"depends_on":["split-router"]}
```

`priority` one of the Fibonacci value `1 2 3 5 8 13 21`, higher more important — scale ascend with "higher wins", so `21` be most important, not biggest estimate. Seven candidate be smaller decision for agent than unbounded integer. `add --priority` and `set-priority` enforce it, so every caller inherit check; validation run on write only, so index line written before scale (`"priority":70`) still load, list and render, and no verb rewrite it. Duplicates allowed, so inserting task never forces renumber. Key absent means unset, and absent stays distinguishable from any number — "did a human decide this?" question prioritization has to answer, so no verb ever defaults it. `depends_on` array of task ids, human-authored ordering. Absent or empty means unset, and `set-deps --none` clears by dropping key. Both on index line, not `**Priority:**`/`**Depends:**` lines in task body, because sorting backlog must not cost one file read per task. `radin backlog list` orders set priorities descending, unset entries after every set one — ordering contract, not display choice. `--order created` opt out into `index.jsonl` line order, which be creation order because index append-only; default stay `priority`, so every agent caller keep contract without pass flag. TUI use `--order created`, so no mutation move row under cursor. It separates its six fields with the unit separator `\037`, not a tab: tab is IFS whitespace, so an unset `priority` collapses under `IFS=$TAB read` and shifts `depends_on` into it. Every other TAB-separated CLI output has no trailing optional field, so only `list` needs this. `set-deps` rejects unknown id, self-reference and cycle (validation in CLI, so every caller inherits it: unresolvable dependency stalls `radin state deps-check` instead of failing it), and `remove` prunes removed id from every other entry's `depends_on`.

Task's file (path `radin backlog path <id>` prints) holds everything used to live under `### title` heading's span: description prose, lists, code blocks, any `**Plan:**` pointer lines — what `radin-execute`/`radin-plan` read as task's scope.

```
<as exhaustive a description as the situation warrants — what the change is,
why it matters, affected files/areas if known, acceptance criteria if
known. radin-execute/radin-plan derive scope and priority entirely from
this text, so write enough that a sub-agent given only this entry, with no
other session context, could act on it correctly.>
```

A body may also state its own acceptance criteria: an `**Acceptance:**` label alone on its line, followed by flat hyphen bullets. `radin backlog meta` prints one `acceptance<TAB><criterion>` line per bullet, stripping the bullet marker and any `[ ]`/`[x]`/`[X]` checkbox prefix. The first line that is not a hyphen bullet at column 0 ends the list, so a blank line, the next `**Label:**` line, prose, or EOF all terminate it. An indented or wrapped criterion is not supported — each criterion is one unindented line.

Every radin agent/skill appending entry classifies into one of four categories, writes same title + description shape via `radin-backlog.sh add`: `radin-review` (code-review findings, usually `fix` for actual bug or `refactor` for structural finding), `radin-record` (feedback/bugs/follow-ups/ideas surfaced in conversation), `radin-execute`/`radin-plan` (own backlog grooming). None invent fifth category or per-entry tag on top.

Once `radin-plan` processes task, appends one more line to that task's own file:

```
**Plan:** <path to plan file>
```

`radin-plan` skill, not agent — runs inline in whichever context invokes it. Scoped to single task, not whole backlog; caller points it at one task by id or title. If scope broad enough to split into independent sub-tasks, and user confirms split, appends one `**Plan:**` line per plan, in order, to same file instead of just one.

## Task-file annotations (`radin-execute` appends)

These labels are the shared vocabulary of a task file's annotations, and the table names who writes each. Most are appended by `radin-execute` through `radin-backlog.sh append`, one labeled line per piece of settled material. Every label is task-scoped by design: an execution sub-agent reads its task file and nothing else, so no other task's context reaches it.

| Label | Written when | Written by |
| --- | --- | --- |
| `**Plan:** <path>` | `radin-plan` produced a plan | `radin-plan` (`add-plan`) |
| `**Skill:** <instruction>` | user named a skill for this task | `radin-record` |
| `**Decision:** <answer>` | user settled a `BLOCKED (DECISION)` | `radin-execute` |
| `**Fact:** <answer>` | fact-finder returned `STATUS: FOUND` | `radin-execute` |
| `**Root cause:** <cause + fix direction>` | debug sub-agent returned `STATUS: DIAGNOSED` | `radin-execute` |
| `**Facts:** <path>` | the long form went to `state/facts/<task-id>.md` | `radin-execute` |
| `**Acceptance:** <checklist>` | the session surfaced checkable criteria | radin-record, radin-review, or a human |

Every one of them is binding on the next sub-agent that reads the file, not commentary on it.

## Per-task facts file (`state/facts/<task-id>.md`)

Free-form markdown, one file per task, written only when a fact-finding or debug sub-agent's evidence runs past ~15 lines. Holds command output, file excerpts, and the reasoning that establishes one `**Fact:**` or `**Root cause:**` line. The task file keeps the summary and a `**Facts:**` pointer. There is deliberately no shared, cross-task notes file: a sub-agent gets its own task's material and nothing more.

## Migration note

Earlier revisions described single monolithic `<repo-root>/.claude/.radin/BACKLOG.md`, addressed by `### title` headings and line-number spans. Before that, bracket-tag scheme used `## [Thermo-Nuclear Review] <title>`/`**Scope:**`/`**Location:**`/`**Finding:**`/`**Preferred remedy:**` fields, plus separate `## [Bug]`/`[Follow-up]`/`[Idea]`/`[Feedback]` scheme for `radin-record`. `index.jsonl` + per-task-file scheme above replaces both: splitting each task into own file means no radin agent/skill ever addresses backlog content by line number again. Existing `BACKLOG.md` files written under earlier scheme not migrated automatically — finish or manually split old-format backlog before upgrading.

## Plan-file format (`radin-plan` output)

Free-form markdown at `$NAMESPACE_DIR/plans/<id>.md`: files to touch, change in each, order of operations, how to verify it. No fixed schema — sub-agents write it, `radin-execute` (or human) reads it.

## State JSON schema (`BACKLOG_STEPS.json`)

JSONL, one compact object per line — same convention as `index.jsonl`, so single-entry update never touches another entry's line:

```json
{"id":"add-route-exports","order":1,"status":"pending","depends_on":[],"attempts":0,"note":""}
```

`id` matches task's id in `index.jsonl`. File located through index's `file` field (`radin backlog path <id>`), so schema no longer carries line range — task's file path fixed at creation, never goes stale.

`radin-execute`'s only state file — `radin-plan` skill runs inline within one conversation, re-resolves sub-task list each time instead of persisting one to disk.

Every mutation goes through `lib/radin-state.sh` (`set-status`/`remove`) — `radin-execute` never hand-edits this file's JSON.

- `depends_on` lists `id`s of other tasks in this file whose result this task's plan or implementation assumes. Value comes from task's index line when it has one (`radin state steps-init` reads index it's handed), and from prioritization's overlap inference per `radin-prioritization.md`'s dependency-order criterion (same files, functions, or behavior touched by both) otherwise. Empty when neither.
- `status` one of `pending`, `in_progress`, `failed`, `blocked`. Entry's absence from file means task complete.
- `in_progress` set by `radin-state.sh start` right before orchestrator dispatches execution sub-agent, cleared by task's terminal status. Entry still `in_progress` at startup means previous run died mid-task: `radin-state.sh stuck` lists those, `triage` reports what dead sub-agent left behind (commits on `radin/<id>`, dirty tree, already-recorded hash). Never re-dispatched blind.
- `attempts` counts `start` calls. `start` exits 2 and marks entry `blocked` once count passes 3, so session that crashes at same task can't retry it forever.
- `note` optional, empty for `pending` entries. `failed` entries carry short reason plus recovery pointer (e.g. `git stash` ref) — what Phase 4 final summary reports back to user. `blocked` entries carry decision question, candidate options, agent's recommendation — final summary asks user to decide.
- `failed`/`blocked` entry never blocks execution loop from reaching Phase 4 — loop exits once no `pending` entries remain, not only when file empty.
- Never stores full task text. Task's own file (`radin backlog path <id>`) stays source of truth for each task's body.

## Session preferences (`session.json`)

Single line, written by `radin-state.sh session-set` when `radin-execute`'s Phase 0.5 resolves worktree/branch questions:

```json
{"worktree":"yes","branch":"no"}
```

Read back with `session-get`. Resumed run reads it instead of asking again — mid-run change would put some tasks in worktrees and others in checkout.

`radin-state.sh prepare <namespace-dir> <id>` is only consumer that acts on it: reads both fields, creates or reuses `<repo>-<id>` worktree and `radin/<id>` branch as answers require, prints directory sub-agent must work in. Neither orchestrator nor sub-agent gets answers themselves, so neither can talk itself past a `no`.

## Transition journal (`journal.jsonl`)

Append-only, one event per line, written by every `radin-state.sh` mutation (`steps-init`, `start`, each status write, `removed`, `done`, `stash`, `session`):

```json
{"ts":"2026-08-18T09:57:13Z","event":"in_progress","id":"add-route-exports","detail":""}
```

`event` either status just written or verb's own name. `detail` free text (commit hash for `done`, stash message for `stash`, note for status writes). Exists so agent whose context got compacted can reconstruct what session already did (`journal-tail`), and so human can see what happened before crash. Never read for control flow, never truncated by radin — `BACKLOG_STEPS.json` plus `completed.json` stay state; journal only records how it got there.

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
  "parallel_execution": false,
  "install_root": "/Users/me/.claude/radin",
  "model_planning": "sonnet",
  "model_execution": "sonnet",
  "model_review": "sonnet",
  "model_debug": "sonnet",
  "model_factfind": "haiku",
  "claude_md_guidance": false,
  "cbm_agent_config": false,
  "cli_on_path": true,
  "skills": ["radin-execute", "radin-plan", "radin-record", "radin-review", "radin-setup-hooks", "radin-show", "radin-stats", "radin-doctor", "radin-uninstall", "thermo-nuclear"],
  "lib": ["radin-namespace.sh", "radin-backlog.sh", "radin-state.sh", "radin-prioritization.md", "radin-cbm-hooks.sh", "radin-cbm-config.sh", "radin-update.sh", "radin-doctor.sh", "radin-uninstall.sh"],
  "companion_tools": {
    "rtk": true,
    "codebase-memory-mcp": false,
    "caveman": true,
    "ponytail": true
  }
}
```

- `version` `dev` when installed from local git clone (no downloaded release tarball, no `.radin-version` file to read).
- `skills`/`lib` static lists matching exactly what `install.sh` copies, what `radin-doctor.sh` checks for — not derived from manifest at runtime by either script (see `docs/architecture.md` "Install manifest").
- `parallel_execution` records which concurrency rule `install.sh` wrote into `skills/radin-execute/SKILL.md`, and covers execution sub-agents only — read-only dispatches always run in parallel. `claude_md_guidance` records whether the user opted into the marked radin section in `~/.claude/CLAUDE.md`. `cbm_agent_config` records whether upstream's own `codebase-memory-mcp install` ran (it does whenever the tool installed and the `radin-cbm-json` helper was built; the merge-only wiring is the fallback). `cli_on_path` records whether the `~/.local/bin/radin` symlink was created.
- `companion_tools` values reflect final reachable state after this install.sh run (already present, just installed, or skipped not distinguished — only "is it there now").
- `install_root` is the resolved source path (dev clone or fetched tarball dir); `model_<role>` records the model written into each `RADIN_MODEL_<ROLE>` token.
- Regenerated wholesale on every `install.sh` run, never partially updated. Read back in one case only: `install.sh --update` (what `radin update` runs) reads `parallel_execution` and the five `model_<role>` keys so an update keeps the previous answers instead of asking. Missing or unparseable keys fall back to the pickers or, under `--update`, to the defaults.

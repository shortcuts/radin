# Domain Models

## Backlog entry format (`index.jsonl` + task files)

This section documents shape every radin agent/skill must produce reading or appending backlog. Read before changing structure or adding new entry-producing skill. Repo-internal reference only — doesn't ship to consumers, so every agent/skill embeds concrete shape inline instead of reading any file at runtime.

Backlog lives at `<repo-root>/.claude/.radin/backlog/`: `index.jsonl` file (one compact JSON object per line, one per task) plus `tasks/` directory holding one markdown file per task. Related tasks group under `tasks/<epic-id>/`, where `DESCRIPTION.md` holds the root context every child inherits — written once instead of repeated in each child's body. An epic has no index line and no category: `list` feeds `radin-execute`, and an epic row there would eventually be dispatched as a task. Membership is `dirname(file)`; one nesting level only. Task's category — `feat`, `fix`, `chore`, `refactor`, same vocabulary as conventional-commit type — field on index line, not section heading. No per-entry bracket tag. `radin-backlog.sh show` reconstructs old grouped-by-category markdown view for humans, canonical order (feat → fix → chore → refactor), but that's rendering, not storage.

One index line:

```json
{"id":"add-route-exports","category":"feat","title":"Add route exports","file":"tasks/add-route-exports.md"}
```

`id` slug derived from title when task created, deduped with `-2`/`-3` suffix on collision. Never changes afterward, even if title text later edited (`radin backlog retitle`, or `r` in the TUI, rewrites only `title`; `set-category` only `category`) — stable key `depends_on` (state schema below) and `radin-plan`/`radin-execute` key off. `file` task body's location relative to `backlog/` directory — `tasks/<id>.md`, or `tasks/<epic-id>/<id>.md` for a task inside an epic. Ids stay globally unique across epics, so `add`'s dedup loop checks the index's own `id` fields, not the task files on disk. `add` decides it; every other verb reads it back, so it's sole authority on where task's body lives (`radin backlog path <id>` prints absolute form).

Two optional keys carry human judgment that must survive a run. They are also `radin backlog order`'s only inputs besides its own `--rank` / `--infer-deps` / `--defer` flags:

```json
{"id":"add-route-exports","category":"feat","title":"Add route exports","file":"tasks/add-route-exports.md","priority":70,"depends_on":["split-router"]}
```

`priority` one of the Fibonacci value `1 2 3 5 8 13 21`, higher more important — scale ascend with "higher wins", so `21` be most important, not biggest estimate. Seven candidate be smaller decision for agent than unbounded integer. `add --priority` and `set-priority` enforce it, so every caller inherit check; validation run on write only, so index line written before scale (`"priority":70`) still load, list and render, and no verb rewrite it. Duplicates allowed, so inserting task never forces renumber. Key absent means unset, and absent stays distinguishable from any number — "did a human decide this?" question prioritization has to answer, so no verb ever defaults it. `depends_on` array of task ids, human-authored ordering. Absent or empty means unset, and `set-deps --none` clears by dropping key. Both on index line, not `**Priority:**`/`**Depends:**` lines in task body, because sorting backlog must not cost one file read per task. `radin backlog list` orders set priorities descending, unset entries after every set one — ordering contract, not display choice. `--order created` opt out into `index.jsonl` line order, which be creation order because index append-only; default stay `priority`, so every agent caller keep contract without pass flag. TUI use `--order created`, so no mutation move row under cursor. It separates its six fields with the unit separator `\037`, not a tab: tab is IFS whitespace, so an unset `priority` collapses under `IFS=$TAB read` and shifts `depends_on` into it. Every other TAB-separated CLI output has no trailing optional field, so only `list` needs this. `set-deps` rejects unknown id, self-reference and cycle (validation in CLI, so every caller inherits it: unresolvable dependency stalls `radin state deps-check` instead of failing it), and `remove` prunes removed id from every other entry's `depends_on`.

Five more optional keys carry the per-task fields a parser reads: `plan`, `skills` and `acceptance` (arrays of strings), `facts` and `location` (strings). They live on the index line, not as `**Label:**` lines in the task body, because each one has a parser and a parser reading markdown fails silently — a label written with the colon outside the bold markers yields nothing and tells no caller. `add --skill` writes `skills`, `add-plan` appends to `plan`, `set-meta <id> <key> <value>… | --none` writes or clears any of the five, and every one of them is validated on write: a value must be non-empty and carry no tab, CR or LF, an `acceptance` value written as a `-` bullet or a `[ ]` checkbox is rejected by name, and `facts`/`location` take exactly one value. `add` and `append` refuse a body line that repeats one of the five labels, so no field is ever carried in two places. `radin backlog meta <id>` is the only reader: it prints `plan<TAB>`, `skill<TAB>`, `acceptance<TAB>`, `facts<TAB>` and `location<TAB>` lines in that fixed key order, and `backlog show`, `backlog field`, `plan-target` and the TUI all render it rather than parsing anything themselves. `planned` and `list --planned` answer "is this planned?" from the `plan` key alone, with no task-file read.

Task's file (path `radin backlog path <id>` prints) holds the task's prose: description, lists, code blocks, and the labeled prose material below — what `radin-execute`/`radin-plan` read as task's scope.

```
<as exhaustive a description as the situation warrants — what the change is,
why it matters, affected files/areas if known, acceptance criteria if
known. radin-execute/radin-plan derive scope and priority entirely from
this text, so write enough that a sub-agent given only this entry, with no
other session context, could act on it correctly.>
```

Every radin agent/skill appending entry classifies into one of four categories, writes same title + description shape via `radin-backlog.sh add`: `radin-review` (code-review findings, usually `fix` for actual bug or `refactor` for structural finding), `radin-record` (feedback/bugs/follow-ups/ideas surfaced in conversation), `radin-execute`/`radin-plan` (own backlog grooming). None invent fifth category or per-entry tag on top.

`radin-plan` skill, not agent — runs inline in whichever context invokes it. Scoped to single task, not whole backlog; caller points it at one task by id or title. If scope broad enough to split into independent sub-tasks, and user confirms split, it calls `add-plan` once per plan, in order, so the entry's `plan` array carries them all.

## Per-task fields

Two stores, split by whether a parser reads the value. A path, id, hash or enum — plus the skill instruction and the acceptance criteria, which read as prose but have parsers — is a key on the index line. A sentence written for a model to read is a `**Label:**` line in the task body. Every one of them is task-scoped by design: an execution sub-agent reads its own task's material and nothing else.

| Index-line key | Written when | Written by |
| --- | --- | --- |
| `plan` | `radin-plan` produced a plan | `radin-plan` (`add-plan`) |
| `skills` | user named a skill for this task | `radin-record` (`add --skill`) |
| `acceptance` | the session surfaced checkable criteria | radin-record, radin-review, or a human (`set-meta`) |
| `facts` | the long form went to `state/facts/<task-id>.md` | `radin-execute`, `radin-plan` (`set-meta`) |
| `location` | where the finding is | `radin-review` (`set-meta`) |

| Body label | Written when | Written by |
| --- | --- | --- |
| `**Decision:** <answer>` | user settled a `BLOCKED (DECISION)` | `radin-execute` |
| `**Fact:** <answer>` | fact-finder returned `STATUS: FOUND` | `radin-execute` |
| `**Root cause:** <cause + fix direction>` | debug sub-agent returned `STATUS: DIAGNOSED` | `radin state task-diagnosis` |
| `**Raised as:** <verbatim ask>` | the triggering text, quoted | `radin-record` |
| `**Scope:** <what was reviewed>` | the review surface | `radin-review` |
| `**Finding:**` | the problem, as the review stated it | `radin-review` |
| `**Preferred remedy:**` | the restructuring suggested | `radin-review` |

Every one of them is binding on the next sub-agent that reads the task, not commentary on it.

## Per-task facts file (`state/facts/<task-id>.md`)

Free-form markdown, one file per task, written when a fact-finding or debug sub-agent's evidence runs past ~15 lines, and by a `/mattpocock-skills:research` invocation, which always writes its findings there. Holds command output, file excerpts, and the reasoning that establishes one `**Fact:**` or `**Root cause:**` line. The task body keeps the summary, and the entry's `facts` key points here. There is deliberately no shared, cross-task notes file: a sub-agent gets its own task's material and nothing more.

## Migration note

Earlier revisions described single monolithic `<repo-root>/.claude/.radin/BACKLOG.md`, addressed by `### title` headings and line-number spans. Before that, bracket-tag scheme used `## [Thermo-Nuclear Review] <title>`/`**Scope:**`/`**Location:**`/`**Finding:**`/`**Preferred remedy:**` fields, plus separate `## [Bug]`/`[Follow-up]`/`[Idea]`/`[Feedback]` scheme for `radin-record`. `index.jsonl` + per-task-file scheme above replaces both: splitting each task into own file means no radin agent/skill ever addresses backlog content by line number again. Existing `BACKLOG.md` files written under earlier scheme not migrated automatically — finish or manually split old-format backlog before upgrading.

## Plan-file format (`radin-plan` output)

Free-form markdown at `<NAMESPACE_DIR>/plans/<task-id>.md`, or `<NAMESPACE_DIR>/plans/<task-id>-<sub-slug>.md` for one sub-task of a split, where `<sub-slug>` is the sub-task's short title in lowercase-hyphen form. `backlog plan-target` prints that path as its `plan_file` line and is the only place the convention lives; nothing composes it by hand. Fixed six-section shape: Outcome, Decisions, Changes, Order, Testing, Out of scope. Template with each section's authoring rule lives in `skills/radin-plan/SKILL.md`, only place shape defined; sub-agents write it, `radin-execute` (or human) reads it.

## Review-scope output (`radin scope`)

TAB-separated key/value lines, one call per review:

| Key | Value |
| --- | --- |
| `type` | `commit`, `pr`, `dir`, `branch-diff` or `range` |
| `scope` | the normalized scope (`#123`, `HEAD~3..HEAD`, a directory path) |
| `command` | the diff or read command that yields the scope's content |
| `passes` | the `/ponytail:*` skill(s) this type calls for — `ponytail-audit` plus `ponytail-debt` for `dir`, `ponytail-review` otherwise |

Exit 0 resolved, 1 unrecognized, 2 ambiguous (each candidate reading on stderr).

`radin scope --in-scope [<arg>]` resolves the same scope, then reads `path:line` citations on stdin and prints, in input order, `in<TAB><citation>` when the scope introduced that line and `out<TAB><citation>` otherwise, then one `dropped<TAB><n>`. `in` means under the directory for a `dir` scope, and inside a diff hunk of that path for every other type; paths compare repo-relative exactly as the diff spells them, a leading `./` aside. Exit 0 once resolved, even when every citation is dropped; resolution failures keep exits 1 and 2. The citation filter and the `location` index key are not two spellings of one thing: the filter screens fresh review citations that have no backlog entry yet, while `location` records where an existing entry's finding sits, for the trace lookup.

`radin scope --tasks [<arg>]` resolves the same scope, then prints one completed task id per line for the commits it covers — deduplicated, in the commit order `git log` yields (newest first). The commit list per type is the branching this flag owns: `git log -1` for a `commit`, `git log <range>` for a `range` or `branch-diff`, `gh pr view <n> --json commits` for a `pr`, and none for a `dir`, which reviews files as they stand and so yields no ids. Each commit joins to an id through `radin state trace`, the owner of the short/long hash match against `completed.json`, so no second copy of that rule lives here. Exits match `--in-scope`: 0 once the scope resolves, even when no commit came from a task; 1 unrecognized and 2 ambiguous.

## Execution-order output (`backlog order`)

`radin backlog order` is the only thing that composes an execution order, and it prints one of three views of the same computation — the priority order `list` defaults to, with the topological dependency fix applied. It stores nothing: the order is re-derived on every call, which is why no phase of `radin-execute` carries it in context.

- `--rank-needed` — one unset-priority id per line, exit 1 (no output) when every entry has a priority. The gate: exit 1 means skip the ranking work entirely.
- `--report` — one `<order>. <title> (id: <id>)` line per task in final order, then one line per dependency the fix moved up:

  ```text
  dependency override: <dep-id> moved above <dependent-id> (priority <N>)
  ```

  `<N>` is the *dependent's* priority, or the literal `unset`. Emitted only when at least one entry of the pair carries a human priority — otherwise the move overrode no decision. The violated edges are recorded against the pre-move priority order, so the report can never drift from the reordering.
- `--steps` — `id<TAB>order<TAB>depends-on-csv<TAB>pending|deferred`, one line per task in final order, `order` running `1..n`. Identical to `radin state steps-init`'s stdin format, so the two pipe together. The csv is the entry's index `depends_on` when it has one and the `--infer-deps` value otherwise — the single place that precedence lives. `--defer <csv-of-ids>` is what makes the fourth field `deferred`.

The fix moves a dependency **up**, to immediately before its dependent, and leaves every other relative position alone: the priority order is the human's ranking and a dependency is its one permitted override, so nothing that has no dependency relation is ever reordered.

## State JSON schema (`BACKLOG_STEPS.json`)

JSONL, one compact object per line — same convention as `index.jsonl`, so single-entry update never touches another entry's line:

```json
{"id":"add-route-exports","order":1,"status":"pending","depends_on":[],"attempts":0,"debugged":0,"note":""}
```

`id` matches task's id in `index.jsonl`. File located through index's `file` field (`radin backlog path <id>`), so schema no longer carries line range — task's file path fixed at creation, never goes stale.

`radin-execute`'s only state file — `radin-plan` skill runs inline within one conversation, re-resolves sub-task list each time instead of persisting one to disk.

Every mutation goes through `lib/radin-state.sh` (`set-status`/`remove`) — `radin-execute` never hand-edits this file's JSON.

- `depends_on` lists `id`s of other tasks in this file whose result this task's plan or implementation assumes. `radin backlog order --steps` resolves the value (index line first, prioritization's bounded overlap inference otherwise, empty when neither) and `steps-init` reapplies the index half; nothing else restates the precedence.
- `status` one of `pending`, `in_progress`, `failed`, `blocked`, `deferred`. Entry's absence from file means task complete. `deferred` is a task Phase 2's gate listed but the user excluded from this run: only `steps-init` writes it (fourth stdin field), `set-status` refuses it, `next-pending` skips it, `report` lists it. Persisting it is what keeps the excluded set from having to survive in context between Phase 2 and Phase 5.
- `in_progress` set by `radin-state.sh start` right before orchestrator dispatches execution sub-agent, cleared by task's terminal status. Entry still `in_progress` at startup means previous run died mid-task: `radin-state.sh stuck` lists those, `triage` reports what dead sub-agent left behind (commits on `radin/<id>`, dirty tree, already-recorded hash). Never re-dispatched blind.
- `attempts` counts `start` calls. `start` exits 2 and marks entry `blocked` once count passes 3, so session that crashes at same task can't retry it forever.
- `debugged` `0` or `1`: whether this task already got its one Debug pass this session. `radin state task-fail` flips it and exits 3 the first time, marks the entry `failed` the second. Same lifetime as `attempts` — `steps-init` rewrites the file every run — which is exactly the lifetime the rule needs, and why the rule is not a counter the router holds.
- `note` optional, empty for `pending` entries. `failed` entries carry short reason plus recovery pointer (e.g. `git stash` ref) — what Phase 4 final summary reports back to user. `blocked` entries carry decision question, candidate options, agent's recommendation — final summary asks user to decide.
- `failed`/`blocked` entry never blocks execution loop from reaching Phase 4 — loop exits once no `pending` entries remain, not only when file empty.
- Never stores full task text. Task's own file (`radin backlog path <id>`) stays source of truth for each task's body.

## Session baseline (`baseline.json`)

Single line, written by `radin-state.sh steps-init` each run, so Phase 5 can scope "this session" without the router carrying counts across phases:

```json
{"backlog_count":7,"completed_count":2}
```

`radin state report` is the only consumer: completions past `completed_count` are this session's, and `backlog_count` against `backlog count` now gives the net-new entry count. Absent (a file written before this key existed): `report` reports every completion and omits the net-new line.

## Session preferences (`session.json`)

Single line, written by `radin-state.sh session-set` when `radin-execute`'s Phase 0.5 resolves worktree/branch questions:

```json
{"worktree":"yes","branch":"no"}
```

Read back with `session-get`. Resumed run reads it instead of asking again — mid-run change would put some tasks in worktrees and others in checkout.

`radin-state.sh prepare <namespace-dir> <id>` is only consumer that acts on it: reads both fields, creates or reuses `<repo>-<id>` worktree and `radin/<id>` branch as answers require, prints directory sub-agent must work in. Neither orchestrator nor sub-agent gets answers themselves, so neither can talk itself past a `no`. It also records what it did to `state/prepared/<id>.json` (`{"branch":…,"worktree":…}`, overwritten on every `prepare`): the branch it read from git at that moment is the only non-guess, including under `branch: no`.

## Transition journal (`journal.jsonl`)

Append-only, one event per line, written by every `radin-state.sh` mutation (`steps-init`, `start`, each status write, `removed`, `done`, `stash`, `session`):

```json
{"ts":"2026-08-18T09:57:13Z","event":"in_progress","id":"add-route-exports","detail":""}
```

`event` either status just written or verb's own name. `detail` free text (commit hash for `done`, stash message for `stash`, note for status writes). Exists so agent whose context got compacted can reconstruct what session already did (`journal-tail`), and so human can see what happened before crash. Never read for control flow — `trace` reads it for reporting, which takes no branch — never truncated by radin — `BACKLOG_STEPS.json` plus `completed.json` stay state; journal only records how it got there.

## Completed-task log (`completed.json`)

JSONL, one compact object per line:

```json
{"id":"add-route-exports","commit":"abc1234","title":"Add route exports","branch":"radin/add-route-exports","worktree":"","plan":"/repo/.claude/.radin/plans/add-route-exports.md","ts":"2026-08-18T09:57:13Z"}
```

Appended to `$NAMESPACE_DIR/state/completed.json` via `lib/radin-state.sh
completed-add` on every `STATUS: SUCCESS`. Task's entry in `BACKLOG_STEPS.json` deleted once complete, so can no longer carry commit hash. Later task whose `depends_on` names completed `id` looks its commit up here via `radin-state.sh completed-get`, forwards to that task's execution sub-agent, so sub-agent can check whether dependency's actual changes still match what this task's plan assumed.

`title` recorded because `task-done` deletes backlog entry, so nothing else can name the task in Phase 5's report; empty when entry was already gone. Same window, same reason for the provenance fields: `branch` and `worktree` come from `prepare`'s `state/prepared/<id>.json` record, `plan` from the entry's plan pointers (comma-separated, in pointer order), `ts` generated by `completed-add` itself. Read them back with `completed-show`; a line written before those fields existed simply lacks them, and an absent field reads as unknown — nothing backfills. `completed-list`'s output stays two fields (`id<TAB>commit`) even so — the TUI's Done view parses that.

## Install manifest (`manifest.json`)

Written by `install.sh` to `~/.claude/.radin/manifest.json` on every run — not part of any repo's `.claude/.radin/` backlog namespace, global, one per machine.

```json
{
  "version": "v0.4.0",
  "installed_at": "2026-07-28T00:00:00Z",
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
- `claude_md_guidance` records whether the user opted into the marked radin section in `~/.claude/CLAUDE.md`. `cbm_agent_config` records whether upstream's own `codebase-memory-mcp install` ran (it does whenever the tool installed and the `radin-cbm-json` helper was built; the merge-only wiring is the fallback). `cli_on_path` records whether the `~/.local/bin/radin` symlink was created.
- `companion_tools` values reflect final reachable state after this install.sh run (already present, just installed, or skipped not distinguished — only "is it there now").
- `install_root` is the resolved source path (dev clone or fetched tarball dir); `model_<role>` records the model written into each `RADIN_MODEL_<ROLE>` token.
- Regenerated wholesale on every `install.sh` run, never partially updated. Read back in one case only: `install.sh --update` (what `radin update` runs) reads the five `model_<role>` keys so an update keeps the previous answers instead of asking. Missing or unparseable keys fall back to the pickers or, under `--update`, to the defaults.

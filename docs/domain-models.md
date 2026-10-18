# Domain Models

## Backlog entry format (`index.jsonl` + task files)

This section documents the shape every radin agent and skill must produce when it reads or appends to the backlog. Read it before you change the structure or add a skill that creates entries. It is a repo-internal reference and does not ship to consumers, so every agent and skill embeds the concrete shape inline instead of reading a file at runtime.

Backlog lives at `<repo-root>/.claude/.radin/backlog/`: `index.jsonl` file (one compact JSON object per line, one per task) plus `tasks/` directory holding one markdown file per task. Related tasks group under `tasks/<epic-id>/`, where `DESCRIPTION.md` holds the root context every child inherits. It is written once instead of repeated in each child's body. An epic has no index line and no category: `list` feeds `radin-batch`, and an epic row there would eventually be dispatched as a task. Membership is `dirname(file)`; one nesting level only. A task's category is one of `feat`, `fix`, `chore` or `refactor`, the same vocabulary as the conventional-commit type. It is a field on the index line, not a section heading. No per-entry bracket tag. `radin-backlog.sh show` reconstructs old grouped-by-category markdown view for humans, canonical order (feat → fix → chore → refactor), but that's rendering, not storage.

One index line:

```json
{"id":"add-route-exports","category":"feat","title":"Add route exports","file":"tasks/add-route-exports.md"}
```

`id` slug derived from title when task created, deduped with `-2`/`-3` suffix on collision. Never changes afterward, even if title text later edited (`radin backlog retitle`, or `r` in the TUI, rewrites only `title`; `set-category` only `category`). It is the stable key that `depends_on` (state schema below) and `radin-plan`/`radin-batch` key off. `file` task body's location relative to `backlog/` directory: `tasks/<id>.md`, or `tasks/<epic-id>/<id>.md` for a task inside an epic. Ids stay globally unique across epics, so `add`'s dedup loop checks the index's own `id` fields, not the task files on disk. `add` decides it; every other verb reads it back, so it's sole authority on where task's body lives (`radin backlog field <id> TASK_FILE` prints absolute form).

`add` also stamps `"created":"<UTC ISO instant>"` and `"branch":"<branch>"` (key left out on a detached HEAD) onto the line. They are provenance, not human judgment: no verb rewrites them, and a line written before they existed reads as unknown (`radin backlog stamps` prints empty fields). The commit is not stamped: an open entry has none yet, and the completing commit lives in `completed.json`.

Two optional keys carry human judgment that must survive a run. They are also `radin backlog order`'s only inputs besides its own `--rank` / `--infer-deps` / `--defer` / `--only` / `--first` flags:

```json
{"id":"add-route-exports","category":"feat","title":"Add route exports","file":"tasks/add-route-exports.md","priority":70,"depends_on":["split-router"]}
```

`priority` is one of the Fibonacci values `1 2 3 5 8 13 21`. Higher is more important, so `21` is the most important, not the biggest estimate. Seven candidates are a smaller decision for an agent than an unbounded integer. `set-priority` enforces the scale, so every caller inherits the check. Validation runs on write only, so an index line written before the scale (`"priority":70`) still loads, lists and renders, and no verb rewrites it. Duplicates are allowed, so inserting a task never forces a renumber. An absent key means unset, and absent stays distinguishable from any number. Prioritization has to answer the question "did a human decide this?", so no verb ever defaults the key. `depends_on` is an array of task ids, a human-authored ordering. Absent or empty means unset, and `set-deps --none` clears it by dropping the key. Both keys live on the index line, not in `**Priority:**` or `**Depends:**` lines in the task body, because sorting the backlog must not cost one file read per task. `radin backlog list` orders set priorities descending and puts unset entries after every set one. This is an ordering contract, not a display choice. `--order created` opts out into `index.jsonl` line order, which is creation order because the index is append-only. The default stays `priority`, so every agent caller keeps the contract without passing a flag. The TUI uses `--order created`, so no mutation moves a row under the cursor. It separates its six fields with the unit separator `\037`, not a tab: tab is IFS whitespace, so an unset `priority` collapses under `IFS=$TAB read` and shifts `depends_on` into it. Every other TAB-separated CLI output has no trailing optional field, so only `list` needs this. `set-deps` rejects unknown id, self-reference and cycle (validation in CLI, so every caller inherits it: unresolvable dependency stalls `radin state deps-check` instead of failing it), and `remove` prunes removed id from every other entry's `depends_on`.

Six more optional keys carry the per-task fields a parser reads: `plan`, `skills` and `acceptance` (arrays of strings), `facts`, `location` and `planning` (strings). They live on the index line, not as `**Label:**` lines in the task body, because each one has a parser and a parser reading markdown fails silently. A label written with the colon outside the bold markers yields nothing and tells no caller. `add --skill` writes `skills`, `add-plan` appends to `plan`, `set-meta <id> <key> <value>… | --none` writes or clears any of the six, and every one of them is validated on write: a value must be non-empty and carry no tab, CR or LF, an `acceptance` value written as a `-` bullet or a `[ ]` checkbox is rejected by name, `facts`/`location` take exactly one value, and `planning` takes only `needed`. `add` and `append` refuse a body line that repeats one of the six labels, so no field is ever carried in two places. `radin backlog meta <id>` is the only reader: it prints `plan<TAB>`, `skill<TAB>`, `acceptance<TAB>`, `facts<TAB>`, `location<TAB>` and `planning<TAB>` lines in that fixed key order, and `backlog show`, `backlog field` and `plan-target` all render it rather than parsing anything themselves. `list --meta` appends the same lines to every row, joined by RS (`\036`), so the TUI reads every entry's fields in the one fork its load already pays. `list --planned` answers "is this planned?" from the `plan` key alone, with no task-file read.

The task's file (the path `radin backlog field <id> TASK_FILE` prints) holds the task's prose: description, lists, code blocks, and the labeled prose material below. `radin-batch` and `radin-plan` read it as the task's scope.

```
<as exhaustive a description as the situation warrants — what the change is,
why it matters, affected files/areas if known, acceptance criteria if
known. radin-batch/radin-plan derive scope and priority entirely from
this text, so write enough that a sub-agent given only this entry, with no
other session context, could act on it correctly.>
```

Every radin agent or skill that appends an entry classifies it into one of four categories and writes the same title and description shape through `radin-backlog.sh add`. The callers are `radin-review` (code-review findings, usually `fix` for a bug or `refactor` for a structural finding), `radin-record` (feedback, bugs, follow-ups and ideas from conversation), and `radin-batch` and `radin-plan` (their own backlog grooming). None invents a fifth category or a per-entry tag.

`radin-plan` is a skill, not an agent. It runs inline in whichever context invokes it. Its scope is a single task, not the whole backlog, and the caller points it at one task by id or title. If the scope is broad enough to split into independent sub-tasks and the user confirms the split, it calls `add-plan` once per plan, in order, so the entry's `plan` array carries them all.

## Per-task fields

Two stores, split by whether a parser reads the value. A path, id, hash or enum, plus the skill instruction and the acceptance criteria (which read as prose but have parsers), is a key on the index line. A sentence written for a model to read is a `**Label:**` line in the task body. Every one of them is task-scoped by design: an execution sub-agent reads its own task's material and nothing else.

| Index-line key | Written when | Written by |
| --- | --- | --- |
| `plan` | `radin-plan` produced a plan | `radin-plan` (`add-plan`) |
| `skills` | user named a skill for this task | `radin-record` (`add --skill`) |
| `acceptance` | the session surfaced checkable criteria | radin-record, radin-review, or a human (`set-meta`) |
| `facts` | the long form went to `state/facts/<task-id>.md` | `radin-batch`, `radin-plan` (`set-meta`) |
| `location` | where the finding is | `radin-review` (`set-meta`) |
| `planning` | the entry needs a plan before execution (`needed`); `radin state task-next` then hands out a planning prompt until a plan lands | `radin-record`, `radin-review`; a planning sub-agent clears it when no plan is needed |

| Body label | Written when | Written by |
| --- | --- | --- |
| `**Decision:** <answer>` | user settled a `BLOCKED (DECISION)` | `radin-batch` |
| `**Fact:** [measured\|inferred\|guess] <answer>` | a fact-finder returned `STATUS: FOUND` (`radin state task-fact`), or an execution sub-agent recorded a plan deviation, a skipped skill or a test's red-green proof | `radin-batch`, execution sub-agent |
| `**Root cause:** [measured\|inferred] <cause + fix direction + sibling sites>` | debug sub-agent returned `STATUS: DIAGNOSED` | `radin state task-diagnosis` |
| `**Raised as:** <verbatim ask>` | the triggering text, quoted | `radin-record` |
| `**Scope:** <what was reviewed>` | the review surface | `radin-review` |
| `**Finding:**` | the problem, as the review stated it | `radin-review` |
| `**Severity:**` | `critical`, `warning` or `nit` | `radin-review` |
| `**Evidence:**` | the proof rung (`cited`, `traced`, `ran`), then the reasoning or output | `radin-review` |
| `**Preferred remedy:**` | the restructuring suggested | `radin-review` |

Every one of them is binding on the next sub-agent that reads the task, not commentary on it, except a `**Fact:**` or `**Root cause:**` line labeled `guess` or carrying no label, which is a lead to check. `measured`: the author ran a command or read a file this session and the line names which. `inferred`: it follows from measured facts the line names. `guess`: neither; a line with no label is a guess.

## Per-task facts file (`state/facts/<task-id>.md`)

Free-form markdown, one file per task, written when a fact-finding or debug sub-agent's evidence is longer than its summary can carry, and by a `/mattpocock-skills:research` invocation, which always writes its findings there. Holds command output, file excerpts, and the reasoning that establishes one `**Fact:**` or `**Root cause:**` line. The task body keeps the summary, and the entry's `facts` key points here. There is deliberately no shared, cross-task notes file: a sub-agent gets its own task's material and nothing more. When a task succeeds, `task-done` appends the entry's `**Fact:**` lines to this file, because deleting the entry would otherwise lose them.

## Migration note

Earlier revisions described a single monolithic `<repo-root>/.claude/.radin/BACKLOG.md`, addressed by `### title` headings and line-number spans. Before that, a bracket-tag scheme used `## [Thermo-Nuclear Review] <title>`/`**Scope:**`/`**Location:**`/`**Finding:**`/`**Preferred remedy:**` fields, plus a separate `## [Bug]`/`[Follow-up]`/`[Idea]`/`[Feedback]` scheme for `radin-record`. The `index.jsonl` and per-task-file scheme above replaces both. With one file per task, no radin agent or skill addresses backlog content by line number again. radin does not migrate `BACKLOG.md` files written under an earlier scheme. Finish the old-format backlog or split it by hand before you upgrade.

## Plan-file format (`radin-plan` output)

Free-form markdown at `<NAMESPACE_DIR>/plans/<task-id>.md`, or `<NAMESPACE_DIR>/plans/<task-id>-<sub-slug>.md` for one sub-task of a split, where `backlog plan-target` derives `<sub-slug>` from the sub-task's short title: lowercase, each run of other characters one hyphen. `backlog plan-target` prints that path as its `plan_file` line and is the only place the convention lives; nothing composes it by hand. `backlog files` reads the `## Changes` section, so its entries must keep the "- `<path>` — …" shape. `add-plan` also writes `<NAMESPACE_DIR>/plans/<task-id>.head`. It holds one line, the full commit hash of `HEAD` at that moment, which `radin-prompt.sh` reads for the stale-plan guard. The file is absent before the first commit. The plan has a fixed eleven-section shape, in order: Outcome, Decisions, Alternatives rejected, Changes, Reach and reuse, Rubrics triggered, Modes and states, Order, Testing, Risks, Out of scope. Every heading stays; a section that does not apply reads `n/a: <reason>`. Each `## Changes` entry carries an indented `You see:` line, the observable result that proves it landed, and `## Testing` carries at least one `- [ ]` command box plus a `- [ ] Live:` box. `backlog plan-lint` checks that shape (its `PLAN_SECTIONS` holds the heading list) and exits 1 on a defect. The template with each section's authoring rule lives in `skills/radin-plan/SKILL.md`. Sub-agents write the plan, and `radin-batch` or a human reads it.

## Review-scope output (`radin scope`)

TAB-separated key/value lines, one call per review:

| Key | Value |
| --- | --- |
| `type` | `commit`, `pr`, `dir`, `branch-diff`, `range` or `staged` |
| `scope` | the normalized scope (`#123`, `HEAD~3..HEAD`, a directory path, `staged`) |
| `command` | the diff or read command that yields the scope's content |
| `passes` | the `/ponytail:*` skill(s) this type calls for: `ponytail-audit` plus `ponytail-debt` for `dir`, empty otherwise (the review core already runs `ponytail-review`) |

Exit 0 resolved, 1 unrecognized, 2 ambiguous (each candidate reading on stderr).

`radin scope --in-scope [<arg>]` resolves the same scope, then reads `path:line` citations on stdin and prints, in input order, `in<TAB><citation>` when the scope introduced that line and `out<TAB><citation>` otherwise, then one `dropped<TAB><n>`. `in` means under the directory for a `dir` scope, and inside a diff hunk of that path for every other type; paths compare repo-relative exactly as the diff spells them, a leading `./` aside. Exit 0 once resolved, even when every citation is dropped; resolution failures keep exits 1 and 2. The citation filter and the `location` index key are not two spellings of one thing: the filter screens fresh review citations that have no backlog entry yet, while `location` records where an existing entry's finding sits, for the trace lookup.

`radin scope --commits [<arg>]` resolves the same scope, then prints one `<hash> <subject>` line per commit it covers. The commit list per type is the branching this flag owns: `git log -1` for a `commit`, `git log <range>` for a `range` or `branch-diff` (newest first), `gh pr view <n> --json commits` for a `pr` (gh's order), and nothing for a `dir`, which reviews files as they stand, or for `staged`, which has no commit yet.

`radin scope --specs [<arg>]` resolves the same scope, then prints one `<id><TAB><created><TAB><branch><TAB><commit><TAB><source>` line per task a review of it could take as its spec, oldest `created` first (an unknown `created` sorts first). `source` is `commit` when a `completed.json` commit is among `--commits`'s hashes (short/long prefix match, seven-character floor), `reflog` when it is not but the review branch's reflog (`git reflog show <branch>`) still lists it (the case after a squash or rebase), and `pending` for an open backlog entry whose stamped `branch` is the review branch (`commit` empty). `role` is `follow-up` when a plan of the task, or the task file of a `pending` one, holds a `**Finding:**` or `**Severity:**` line, else `feature`. The review branch is HEAD's branch. Exit 0 once the scope resolves, even with no output; 1 unrecognized, 2 ambiguous; 4 when a completed task's commit no longer exists and HEAD sits on no branch, so the reflog has nothing to search.

`radin scope --attribute [<arg>]` reads `path:line` citations on stdin and prints one `<citation><TAB><task id><TAB><plan path | none>` line per citation, in input order. It runs `git blame` on the cited line (start line of a `<start>-<end>` citation, a leading `./` dropped) and keeps the result only when the blamed commit is one of `--commits`'s hashes; the commit joins to its task and plan through `radin state trace`, and the plan field is printed verbatim. Both fields are `none` when no scope commit wrote the line, the commit is untraced, the scope is `dir` (no commit list), or the citation does not parse. Exits match `--in-scope`: 0 once the scope resolves; 1 unrecognized and 2 ambiguous.

`radin scope --bucket` takes no scope. It reads review finding lines `<severity> <path:line> — <claim> [<rung>: <evidence>]` on stdin and prints `<bucket><TAB><line>` per non-blank line, in input order, exit 0. Rules, first match wins: (a) severity `nit` is `noted`; (b) `critical` or `warning` with rung `traced` or `ran` is `act-on`; (c) `critical` or `warning` whose evidence holds a double quote, `AGENTS.md`, `CLAUDE.md` or `CONTRIBUTING.md` is `act-on`; (d) any other `critical` or `warning` is `consider`; (e) a line with no known severity or no rung is `unparsed`. `dismissed` is never printed: it is a judgment.

## Execution-order output (`backlog order`)

`radin backlog order` is the only thing that composes an execution order. It prints one of three views of the same computation: the priority order `list` defaults to, with the topological dependency fix applied. It stores nothing. It re-derives the order on every call, so no phase of `radin-batch` carries the order in context.

- `--rank-needed` prints one unset-priority id per line, and exits 1 with no output when every entry has a priority. This is the gate: exit 1 means skip the ranking work entirely.
- `--report` prints one `<order>. <title> (id: <id>)` line per task in final order, then one line per dependency the fix moved up:

  ```text
  dependency override: <dep-id> moved above <dependent-id> (priority <N>)
  ```

  `<N>` is the *dependent's* priority, or the literal `unset`. The report emits the line only when at least one entry of the pair carries a human priority. Otherwise the move overrode no decision. The violated edges are recorded against the pre-move priority order, so the report can never drift from the reordering.
- `--steps` prints `id<TAB>order<TAB>depends-on-csv<TAB>pending|deferred`, one line per task in final order, with `order` running `1..n`. The format is identical to the stdin format of `radin state steps-init`, so the two pipe together. The csv is the entry's index `depends_on` when it has one and the `--infer-deps` value otherwise. That precedence lives only here. `--defer <csv-of-ids>` makes the fourth field `deferred`. `--only <csv-of-ids>` defers every id outside the csv, and `--first` every id but the one at order 1 (judged after the dependency fix). The three flags are mutually exclusive.
- `radin backlog scope <epic|id|title>` prints `ids<TAB><csv>` (the scope plus its transitive `depends_on`, index order) and, when the closure added any, `dependencies<TAB><csv>`.

The fix moves a dependency **up**, to immediately before its dependent, and leaves every other relative position alone. The priority order is the human's ranking and a dependency is its one permitted override, so the fix never reorders a task that has no dependency relation.

## State JSON schema (`BACKLOG_STEPS.json`)

JSONL, one compact object per line, the same convention as `index.jsonl`, so single-entry update never touches another entry's line:

```json
{"id":"add-route-exports","order":1,"status":"pending","depends_on":[],"attempts":0,"debugged":0,"note":""}
```

`id` matches the task's id in `index.jsonl`. The index's `file` field locates the task file (`radin backlog field <id> TASK_FILE`), so the schema carries no line range. The task's file path is fixed at creation and never goes stale.

This is the only state file of `radin-batch`. The `radin-plan` skill runs inline within one conversation and re-resolves the sub-task list each time instead of persisting one to disk.

Every mutation goes through `lib/radin-state.sh`. `radin-batch` never hand-edits this file's JSON.

- `depends_on` lists the `id`s of other tasks in this file whose result this task's plan or implementation assumes. `radin backlog order --steps` resolves the value (index line first, prioritization's bounded overlap inference otherwise, empty when neither) and `steps-init` reapplies the index half. Nothing else restates the precedence.
- `status` is one of `pending`, `in_progress`, `failed`, `blocked`, `deferred`. An entry's absence from the file means the task is complete. `deferred` is a task that Phase 2's gate listed but the user excluded from this run. Only `steps-init` writes it (fourth stdin field), `set-status` refuses it, `task-next` skips it, and `report` lists it. Persisting it keeps the excluded set from having to survive in context between Phase 2 and Phase 5.
- `radin state task-next` sets `in_progress` when it hands out an execution prompt, and the task's terminal status clears it. An entry still `in_progress` at startup means the previous run died mid-task. `radin state stuck` lists those entries. `recover` acts on what the dead sub-agent left behind (an already-recorded hash, a dirty tree) and hands back the commits on its branch for the model to judge. The router never re-dispatches such a task blind.
- `attempts` counts claims, planning dispatches included; it resets to 0 when the plan lands. Once the count passes 3, `task-next` marks the entry `blocked` instead, so a session that crashes at the same task cannot retry it forever.
- `debugged` is `0` or `1`. It records whether this task already got its one Debug pass this session. `radin state task-report` flips it and answers `next debug` the first time, and marks the entry `failed` the second time. It has the same lifetime as `attempts`, because `steps-init` rewrites the file every run. That is the lifetime the rule needs, and the reason the router does not hold the rule as a counter.
- `note` is optional and empty for `pending` entries. `failed` entries carry a short reason plus a recovery pointer (e.g. a `git stash` ref), which the Phase 4 final summary reports back to the user. `blocked` entries carry the decision question, the candidate options and the agent's recommendation, and the final summary asks the user to decide.
- A `failed` or `blocked` entry never stops the execution loop from reaching Phase 4. The loop exits once no `pending` entries remain, not only when the file is empty.
- The file never stores full task text. The task's own file (`radin backlog field <id> TASK_FILE`) stays the source of truth for each task's body.

## Session baseline (`baseline.json`)

A single line that `radin-state.sh steps-init` writes each run, so Phase 5 can scope "this session" without the router carrying counts across phases:

```json
{"backlog_count":7,"completed_count":2}
```

An older file may carry a `tests` key; nothing reads it.

`radin state report` is the only consumer: completions past `completed_count` are this session's, and `backlog_count` against `backlog count` now gives the net-new entry count. Absent (a file written before this key existed): `report` reports every completion and omits the net-new line.

## Session preferences (`session.json`)

A single line that `radin-state.sh session-set` writes when `radin-batch`'s Phase 0.5 resolves the worktree and branch questions:

```json
{"worktree":"yes","branch":"no"}
```

Read it back with `session-get`. A resumed run reads it instead of asking again, because a mid-run change would put some tasks in worktrees and others in the checkout.

`radin-state.sh prepare <namespace-dir> <id>` is the only consumer that acts on it. It reads both fields, creates or reuses the `<repo>-<id>` worktree and the `radin/<id>` branch as the answers require, and prints the directory the sub-agent must work in. Neither the orchestrator nor the sub-agent gets the answers, so neither can talk itself past a `no`. It also records what it did to `state/prepared/<id>.json` (`{"branch":…,"worktree":…}`, overwritten on every `prepare`): the branch it read from git at that moment is the only non-guess, including under `branch: no`.

## Transition journal (`journal.jsonl`)

Append-only, one event per line. Every `radin-state.sh` mutation writes one (`steps-init`, each status write, `done`, `stash`, `session`, `prepare`, `debug`, `diagnosis`, `skill-dropped`, `usage`, `out-of-plan`, `unproven`, `summary`, `review-finding`):

```json
{"ts":"2026-08-18T09:57:13Z","event":"in_progress","id":"add-route-exports","detail":""}
```

`event` is either the status just written or the verb's own name. `gate-fix` events carry the recorded fix hashes in `detail`. `usage` events carry `<kind> <tokens> <tool_uses> <duration_ms>` in `detail` (kind `planning|execution|debug|factfind`). `out-of-plan` events carry the comma-joined repo-relative paths a task's commit changed outside its plan's `## Changes`, test paths exempt. `unproven` events carry one acceptance criterion in `detail`, journaled at `task-done` when no `**Fact:** [measured]` line starts with that text. `summary` events carry what a succeeded execution leaf built, chose and left open, the text after its `STATUS: SUCCESS` line's first `;`. `review-finding` events carry the task id in `id` (empty for class `none`) and `<class> <plan path>` in `detail` (class `plan|executor|none`) plus, for class `plan`, a third word naming the plan-template section when the finding had one, one per finding `/radin-review` logged; the finding bodies are deleted at `task-done`, the event is not. `detail` is free text (commit hash for `done`, stash message for `stash`, note for status writes). The journal exists so an agent whose context got compacted can reconstruct what the session already did (`journal-tail`), and so a human can see what happened before a crash. Nothing reads it for control flow. `trace` reads it for reporting, which takes no branch. radin never truncates it. `BACKLOG_STEPS.json` plus `completed.json` stay the state, and the journal only records how it got there.

## Completed-task log (`completed.json`)

JSONL, one compact object per line:

```json
{"id":"add-route-exports","commit":"abc1234","title":"Add route exports","branch":"radin/add-route-exports","worktree":"","plan":"/repo/.claude/.radin/plans/add-route-exports.md","ts":"2026-08-18T09:57:13Z","created":"2026-08-17T16:02:44Z"}
```

`radin state task-done` appends a line to `$NAMESPACE_DIR/state/completed.json` on every validated `STATUS: SUCCESS`. The task's entry in `BACKLOG_STEPS.json` is deleted once the task completes, so it can no longer carry the commit hash. A later task whose `depends_on` names a completed `id` looks the commit up here (`radin state deps-check`), and `radin prompt` forwards it to that task's execution sub-agent. The sub-agent can then check whether the dependency's actual changes still match what this task's plan assumed.

`created` is the entry's own stamp, copied before the entry goes away, so a review can order completed and open tasks on one timeline. It is absent on a line written before the stamp existed. `title` is recorded because `task-done` deletes the backlog entry, so nothing else can name the task in Phase 5's report. It is empty when the entry was already gone. The provenance fields have the same window and the same reason. `branch` and `worktree` come from `prepare`'s `state/prepared/<id>.json` record, `plan` comes from the entry's plan pointers (comma-separated, in pointer order), and `task-done` itself generates `ts`. Read them back with `completed-show`. A line written before those fields existed lacks them, and an absent field reads as unknown. Nothing backfills. `completed-list`'s output stays two fields (`id<TAB>commit`) even so, because the TUI's Done view parses that.

`state/gate-fixes` holds the hashes of the gate's fix commits, one per line. `radin state gate-fix` writes it, `steps-init` deletes it, and `radin state session-commits` reads it after the `completed.json` commits.

## Install manifest (`manifest.json`)

`install.sh` writes it to `~/.claude/.radin/manifest.json` on every run. It is not part of any repo's `.claude/.radin/` backlog namespace. It is global, one per machine.

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
  "model_chore": "haiku",
  "claude_md_guidance": false,
  "cbm_agent_config": false,
  "cli_on_path": true,
  "skills": ["radin-batch", "radin-plan", "radin-record", "radin-review", "radin-stats", "radin-uninstall", "thermo-nuclear"],
  "lib": ["radin-namespace.sh", "radin-backlog.sh", "radin-state.sh", "radin-prioritization.md", "radin-cbm-hooks.sh", "radin-cbm-config.sh", "radin-update.sh", "radin-doctor.sh", "radin-uninstall.sh"],
  "companion_tools": {
    "rtk": true,
    "codebase-memory-mcp": false,
    "caveman": true,
    "ponytail": true,
    "unslop": true,
    "technical-writing": true
  }
}
```

- `version` is `dev` when installed from a local git clone (no downloaded release tarball, no `.radin-version` file to read).
- The `skills` and `lib` lists follow `SHIPPED` order and match exactly what `install.sh` copies and `radin-doctor.sh` checks for. Neither script derives them from the manifest at runtime (see `docs/architecture.md` "Install manifest" and "One list of shipped files").
- `claude_md_guidance` records whether the user opted into the marked radin section in `~/.claude/CLAUDE.md`. `cbm_agent_config` records whether upstream's own `codebase-memory-mcp install` ran (it does whenever the tool installed and the `radin-cbm-json` helper was built; the merge-only wiring is the fallback). `cli_on_path` records whether the `~/.local/bin/radin` symlink was created.
- `companion_tools` values reflect the final reachable state after this `install.sh` run. They do not distinguish already present, just installed or skipped. They record only "is it there now".
- `install_root` is the resolved source path (dev clone or fetched tarball dir). `model_<role>` records the model written into each `RADIN_MODEL_<ROLE>` token.
- Every `install.sh` run regenerates the manifest wholesale and never updates it partially. Only one case reads it back: `install.sh --update` (what `radin update` runs) carries `package_manager` over from the previous manifest instead of asking again. A missing key gives `""`, and the question runs. It also reads the `unslop` and `technical-writing` booleans as the ownership record: a skill directory whose key is not `true` is never overwritten.

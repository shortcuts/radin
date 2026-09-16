# radin skill-prose inventory

Read-only audit taken 2026-09-16 against commit c6a07f7. Paths relative to the repo root. Findings are cited by item number from the backlog entries that consume this file; re-verify a cited `file:line` before acting on it.

## A. Orchestration the prose asks the model to compute

### radin-execute — namespace and preconditions

1. `skills/radin-execute/SKILL.md:94-100` — resolve the namespace *and* verify a backlog exists in the same Bash call, then re-source in every later call. Covered: `backlog env --export` + `backlog count`. The "same call / re-source" bookkeeping has no verb.
2. `skills/radin-execute/SKILL.md:102-105` — branch on the count (0 defers to Phase 1 step 1). Covered by `backlog count`; the routing is model-held.
3. `skills/radin-execute/SKILL.md:121-127` — route on `session-get`'s exit code to decide whether to ask the worktree/branch questions. Covered: `state session-get`.
4. `skills/radin-execute/SKILL.md:131-134` — decide "missing **or** empty" index, then offer create-or-stop. Covered by `backlog count` (prints 0 without an index); the two-condition test is model-side.

### radin-execute — prioritization and ordering

1. `skills/radin-execute/SKILL.md:155-158` + `lib/radin-prioritization.md:14-32` — order every task. Covered when every `priority` is set: `backlog list` (default `--order priority`, unset last) *is* the answer. No verb for the unset-group ranking.
2. `skills/radin-execute/SKILL.md:159-160` and `lib/radin-prioritization.md:83` — assign a sequential `order` number from 1. Pure enumeration of `list` output. No verb; `state steps-init` takes `order` on stdin instead of deriving it.
3. `lib/radin-prioritization.md:39-44` (rules 1-2) — restates what `backlog list` already sorts (`lib/radin-backlog.sh:21`). No computation left, yet stated as a rule to apply.
4. `lib/radin-prioritization.md:50-57` (rule 4) — compute the topological violation, move the dependency immediately above its dependent, leave every other position alone, emit a `dependency override:` line. Fully deterministic given `depends_on`. No verb: `backlog set-deps` validates cycles (`lib/radin-backlog.sh:31`) but reorders nothing.
5. `lib/radin-prioritization.md:58-63` (rule 5) — decide whether the ranking pass runs at all, from "is there any unset priority". Deterministic over `backlog list`'s 5th field. No verb; `list --priority-min/--priority-max` only filters.
6. `lib/radin-prioritization.md:45-49` + `:74-79` — infer `depends_on` from body overlap. Semantic, not CLI-able; the gate on it is item 9.
7. `skills/radin-execute/SKILL.md:160-161` — carry each `dependency override:` line into the Phase 2 report. Model-held state across phases; nothing persists it.

### radin-execute — Phase 2 selection

 1. `skills/radin-execute/SKILL.md:188-198` — read the task selection off free text ("only 1 and 3", "not 5 and 6"), resolve each reference to a task id, hold the excluded set for Phase 5. `backlog find` resolves *one* reference; no verb resolves a selection list or records the deferral.
 2. `skills/radin-execute/SKILL.md:196-198`, `:190-192`, `lib/radin-execute-reporting.md:44-45` — assemble the "Deferred at your request" list. No verb, no persistence: it survives only in context.

### radin-execute — Phase 3

 1. `skills/radin-execute/SKILL.md:207-217` — compose `id<TAB>order<TAB>depends-on-csv` stdin, with the rule that the third field stays empty whenever the index already has deps. `state steps-init <steps> <index>` already prefers the index per entry (`lib/radin-state.sh:12-13`), so the model computes a field the CLI discards in the common case.

### radin-execute — Phase 4 loop

 1. `skills/radin-execute/SKILL.md:227-234` — pick the next task. Covered: `state next-pending`.
 2. `skills/radin-execute/SKILL.md:236-249` — dependency gate, then mark blocked with the CLI's own message as the note. Covered: `state deps-check` + `state set-status`; compose-and-route is model-side.
 3. `skills/radin-execute/SKILL.md:253-262` — confirm the entry still exists, resolve its file path. Covered: `backlog find`, `backlog path`.
 4. `skills/radin-execute/SKILL.md:264-275` — collect plan/skill/acceptance pointers. Covered: `backlog meta` (and `backlog planned` / `list --planned` for the plan-exists half alone).
 5. `skills/radin-execute/SKILL.md:273-279` — decide "single obvious change" vs "needs a plan", i.e. whether a planning sub-agent is dispatched. Judgment, no verb; the plan-*exists* half is fully covered by `meta` / `planned`.
 6. `skills/radin-execute/SKILL.md:301-303` — decide whether to re-run `meta` (only if planning ran) or reuse Step 4a's output. Caching bookkeeping; `meta` is idempotent, so the decision buys nothing.
 7. `skills/radin-execute/SKILL.md:290-299` — claim the task, read `attempts`, route on exit 2. Covered: `state start`.
 8. `skills/radin-execute/SKILL.md:306-336` — assemble the Execution prompt from eight placeholders, each already a CLI output (`backlog path`, `backlog meta`, `backlog find`'s category field, `state deps-check` pairs, `$NAMESPACE_DIR`, the id). No verb emits the field set.
 9. `skills/radin-execute/SKILL.md:318-332` — filter `**Skill:**` instructions against a fixed four-class deny-list (asks the user, spawns an agent, launches a workflow, is a radin entry point), then remember each dropped one for Phase 5. Fixed name matching; no verb.
10. `lib/radin-execute-prompts.md:108-122` — render `ACCEPTANCE`: delete the line when `meta` printed none, else emit a numbered block with one indented bullet per line in printed order. Pure templating over `backlog meta`; no verb.
11. `skills/radin-execute/SKILL.md:342-345` — resolve which tree to check, then check it. Covered: `state task-dir` + `state dirty-check`.
12. `skills/radin-execute/SKILL.md:353-398` — map the sub-agent's `STATUS:` string to an action. Leaves covered (`state task-done`, `state set-status`); the dispatch table has no verb.
13. `skills/radin-execute/SKILL.md:355-363` — parse the commit hash (or the cited pre-existing hash) out of a free-text `STATUS:` line and pass it to `task-done`. No verb validates that the hash exists or belongs to the task's branch.
14. `skills/radin-execute/SKILL.md:365` — format the per-task report line including `Remaining: <count>`. `backlog count` supplies the count; the template has no verb.
15. `skills/radin-execute/SKILL.md:372-376` — enforce "Debug prompt once per task per session". A counter with no storage: `attempts` persists via `state start`, the debug-once flag does not, and `journal.jsonl` is barred from control flow (`lib/radin-execute-resume.md:29-30`).
16. `skills/radin-execute/SKILL.md:377-381` — choose the append label (`**Root cause:**`) and the re-entry point. Covered: `backlog append`; label choice is templating.
17. `skills/radin-execute/SKILL.md:382-386`, `:387-392` — compose the `failed` note (reason + diagnosis + recovery pointer) and the no-STATUS note. String assembly, no verb.

### radin-execute — on-demand fragments

 1. `lib/radin-execute-recovery.md:16-28` — four-way route over `state triage`'s facts (completed hash -> `task-done`; `branch_commit` lines -> read the commits and judge; no commits + 0 dirty -> `set-status pending`; dirty -> `stash` then `pending`). Every leaf verb exists; no composite (`state recover`). Only "do these commits satisfy the task" is genuine judgment.
 2. `lib/radin-execute-dirty.md:11-22` — `stash`, then `set-status failed` with a note embedding `<TASK_DIR>`, `<ref>` and two recovery commands. Verbs exist (`state stash`, `set-status`); composition and command strings are model-written.
 3. `lib/radin-execute-reporting.md:7-11` — residual dirty-check and stash. Covered: `state dirty-check`, `state stash`.
 4. `lib/radin-execute-reporting.md:12-21` — derive where commits landed plus the merge command: branch `radin/<task-id>`, worktree `$REPO_ROOT-<task-id>`. Deterministic; `state task-dir` knows the path and `session-get` the modes, but no verb prints the per-task landing line.
 5. `lib/radin-execute-reporting.md:22-24` — scan `backlog list` for a duplicate id or title. Deterministic scan; no verb (`find` signals ambiguity for one query only).
 6. `lib/radin-execute-reporting.md:25-29` — collect every commit hash this session, plus every `failed`/`blocked` entry with its note, plus the net-new count. `state completed-list` gives hashes and `backlog count` the count, but **no verb lists steps entries by status** (`state stuck` covers `in_progress` only), so the model is pushed back onto the JSON.
 7. `lib/radin-execute-reporting.md:30-52` — assemble the final report, conditionally dropping the branch/worktree/merge parts. All inputs CLI-derivable; template has no verb.
 8. `lib/radin-execute-resume.md:9-16` — resume triage: read `BACKLOG_STEPS.json`, skip absent (completed) entries, treat `failed`/`blocked` as `pending`, except a `blocked` note that says `MAX_ATTEMPTS`. Deterministic, including a string match on a note the CLI itself wrote. No verb (`state resume` / `reset-retriable`).
 9. `lib/radin-execute-resume.md:26-31` — reconstruct what the session already did after a compaction. Covered: `state journal-tail`.
10. `lib/radin-execute-clarify.md:10-22` — route on the `(FACT)` / `(DECISION)` tag, and on `NOT FOUND` fall through to the decision path. Fixed tag dispatch; no verb.
11. `lib/radin-execute-clarify.md:15-17` — choose `**Fact:**` vs `**Facts:** <path>` by whether a facts path came back. Covered: `backlog append`; label choice is templating.
12. `lib/radin-execute-clarify.md:45-51` — on a deferral, compose the `blocked` note (question + options + recommendation) and the report line. Covered: `set-status`; assembly is model-side.
13. `lib/radin-execute-session.md:13-19` — decide whether the invoking prompt already states a preference, else ask, then persist. Covered: `state session-set`.
14. `skills/radin-execute/SKILL.md:420-427` — decide whether Phase 6 runs, from whether the user asked. No verb.
15. `skills/radin-execute/SKILL.md:429-436` — assemble the reviewer prompt from "commit hashes recorded in Phase 4", from memory, though `state completed-list` holds them.

### radin-plan

 1. `skills/radin-plan/SKILL.md:36-40` — resolve namespace, read four variables. Covered: `backlog env`.
 2. `skills/radin-plan/SKILL.md:44-71` — resolve scope, branch four ways on match count (one / several / none / already planned). Covered: `backlog find`, `backlog meta`; the route is model-side.
 3. `skills/radin-plan/SKILL.md:56` — classify a newly created entry into `feat`/`fix`/`chore`/`refactor` using a rubric that lives in another skill's file. Judgment; `backlog add` takes the category as an argument.
 4. `skills/radin-plan/SKILL.md:73` — record the entry's id as `parent_id`. Model-held alias for `find`'s first field.
 5. `skills/radin-plan/SKILL.md:93-95` — resolve the entry's file path. Covered: `backlog path`.
 6. `skills/radin-plan/SKILL.md:130` — decide the plan file's path, `$NAMESPACE_DIR/plans/<sub-task-id>.md`. Deterministic; `backlog add-plan` accepts a path rather than deriving it, so no verb owns the convention.
 7. `skills/radin-plan/SKILL.md:131-136` — append the pointer after any earlier `**Plan:**` lines. Covered: `backlog add-plan`.
 8. `skills/radin-plan/SKILL.md:162-169` — assemble the report table (sub-task, plan path, findings count). No verb.

### radin-record

 1. `skills/radin-record/SKILL.md:109-117` — express a dependency as prose naming the other entry's exact title, so prioritization can read it from the body. `backlog add --depends-on <csv>` and `backlog set-deps` already store it structurally (`lib/radin-backlog.sh:24,31`).
 2. `skills/radin-record/SKILL.md:119-127` — classify each item into exactly one category. Judgment; no verb.
 3. `skills/radin-record/SKILL.md:149-177` — compose the body with fixed labels (`**Raised as:**`, `**Decision:**`, `**Acceptance:**` plus flat-bullet indentation rules). The CLI already owns one such label via `--skill` (`:175-177`); the rest has no verb.
 4. `skills/radin-record/SKILL.md:179-182` — decide never to dedupe. A policy, not a computation, but the mirror of the duplicate scan asked for in `lib/radin-execute-reporting.md:22-24`.
 5. `skills/radin-record/SKILL.md:186-188` — report how many entries were logged. `backlog count` gives before/after; the subtraction is model-side.

### radin-review

 1. `skills/radin-review/SKILL.md:27-45` — resolve the scope and route on exit code. Covered: `RADIN_CLI scope`. Exit 1 hands the model natural-language range translation into `git log`/`git diff` — no verb.
 2. `skills/radin-review/SKILL.md:73-76` + `:186` — record a baseline count, compute net-new at the end. Covered: `backlog count` twice; subtraction model-side.
 3. `skills/radin-review/SKILL.md:83-85` — decide that a commit or PR scope must be checked out or diffed before `detect_changes` reads the working tree, and fall back to `git show`/`git diff` when the graph has nothing. Precondition check; no verb.
 4. `skills/radin-review/SKILL.md:93-102` — pick which ponytail pass applies from the scope type (`ponytail-review` for a diff, `ponytail-audit` for a directory, plus `ponytail-debt` for a directory), then filter `ponytail-debt` hits to files under the reviewed path. `RADIN_CLI scope` already prints the `type` line that decides it; no verb maps type -> pass.
 5. `skills/radin-review/SKILL.md:109-113` — drop out-of-scope findings by checking each cited line against the diff. Mechanical (line in diff hunk); no verb.
 6. `skills/radin-review/SKILL.md:114-119` — classify each survivor `fix` vs `refactor`, with "every ponytail finding ... by definition" — a mechanical rule stated as judgment.
 7. `skills/radin-review/SKILL.md:121-134` — number the findings, mark the recommended ones, and restate the surviving set if the user types numbers instead of picking. Set resolution from free text; no verb.
 8. `skills/radin-review/SKILL.md:161-173` — compose the entry body with four required labels plus the optional `**Acceptance:**` block. No verb; same shape as item 57.
 9. `skills/radin-review/SKILL.md:183-193` — assemble the report, including the count of findings dropped as out of scope. No verb.

### radin-show

 1. `skills/radin-show/SKILL.md:23-25` — decide whether to pass a category argument, from the user's phrasing. Covered: `backlog show [category]`.
 2. `skills/radin-show/SKILL.md:27-29` — route on the CLI's "no backlog" error to a message plus a pointer, and not create a file. Covered by the CLI's own exit; routing model-side.

### radin-stats

 1. `skills/radin-stats/SKILL.md:15-38` — probe five sources with `command -v` or a skill lookup and skip the missing ones. `RADIN_CLI doctor` already reports companion reachability (`skills/radin-doctor/SKILL.md:11-18`); no verb enumerates the stats sources.
 2. `skills/radin-stats/SKILL.md:42-46` — label which numbers are measured vs benchmark, in a fixed per-source mapping. Static table held in prose; no verb.

### radin-doctor

 1. `skills/radin-doctor/SKILL.md:21-33` — run and print as-is; route on non-zero exit to a "re-run install.sh" message, suppressed for an advisory companion miss. Fully covered by `RADIN_CLI doctor`; only the exit-code wording is model-side. Nothing else here is model orchestration.

### radin-setup-hooks

 1. `skills/radin-setup-hooks/SKILL.md:19-21` — inspect `~/.claude/.radin/manifest.json` for `"cbm_agent_config": true` and decide whether to stop. Direct JSON read by the model; no verb (doctor reports install state).
 2. `skills/radin-setup-hooks/SKILL.md:31-36` — decide between `cbm-config install` (full wiring, needs `python3`) and the merge-only `cbm-hooks all` path. The `python3` precondition is a `command -v` check; no verb picks the path.
 3. `skills/radin-setup-hooks/SKILL.md:40-41` — run `git rev-parse --show-toplevel` to confirm the repo. `backlog env` already prints `REPO_ROOT`.
 4. `skills/radin-setup-hooks/SKILL.md:54-60` — route on which of three non-zero causes the script hit (missing `codebase-memory-mcp`, missing `python3`, invalid JSON), each to a different message. The script already prints the cause; the routing table is duplicated in prose.

### radin-uninstall

 1. `skills/radin-uninstall/SKILL.md:22-32` — run and print as-is. Fully covered by `RADIN_CLI uninstall`; no model orchestration.

## B. Drift and friction risk

### Same rule in more than one file

1. "Assign a sequential `order` number starting from 1" — `skills/radin-execute/SKILL.md:159-160` vs `lib/radin-prioritization.md:83`.
2. Phase 2's gate is unconditional — `skills/radin-execute/SKILL.md:47-52` vs `:163-169` vs `lib/radin-execute-resume.md:12`. Three statements, three wordings.
3. "Never act on the worktree/branch answers; `prepare` is the only thing that does" — `skills/radin-execute/SKILL.md:43-46`, `:112-117`, `:313-317`, `lib/radin-execute-session.md:21-23`, `lib/radin-execute-prompts.md:104-106`, `lib/radin-execute-prompts.md:138-151`. Six copies.
4. "Don't set `run_in_background`; Claude Code decides, fork mode removes it" — `skills/radin-execute/SKILL.md:31-38` vs `lib/radin-execute-prompts.md:35-38`.
5. Sub-agent capability facts (no user, no `AskUserQuestion`, no `Workflow`, no sub-delegation) — `skills/radin-execute/SKILL.md:26-30`, `:318-332`, `lib/radin-execute-prompts.md:9-31`, then again inside every fence: `:56-65` (planning), `:127-129` and `:158-165` (execution), `:249-253` and `:264-266` (debug), `:296-302` (fact-finding), plus `skills/radin-plan/SKILL.md:14-26`. Nine restatements of one contract.
6. "Keep the Phase 0.5 values for Phase 5's summary; nothing else needs them" — `skills/radin-execute/SKILL.md:123-124` vs `lib/radin-execute-session.md:21`.
7. `depends_on` precedence ("index wins per entry, stdin csv only fills gaps") — `lib/radin-prioritization.md:64-67`, `:96-100`, `:114-117`, `skills/radin-execute/SKILL.md:207-211`, `lib/radin-state.sh:12-13`. Five copies.
8. "Never synthesise an acceptance criterion" — `lib/radin-execute-prompts.md:110-113`, `skills/radin-record/SKILL.md:168-171`, `skills/radin-review/SKILL.md:168-171`.
9. Dirty-tree contract — `skills/radin-execute/SKILL.md:337-351`, all of `lib/radin-execute-dirty.md`, `lib/radin-execute-prompts.md:196-203` and `:222-224`.
10. "Never commit anything under `.claude/.radin/`" — `skills/radin-execute/SKILL.md:446-447`, `lib/radin-execute-prompts.md:201-203`, `lib/radin-execute-reporting.md:11`, `lib/radin-execute-dirty.md:11`.
11. Append-label vocabulary (`**Decision:** / **Fact:** / **Root cause:** / **Facts:**`) — `lib/radin-execute-clarify.md:38-41`, `lib/radin-execute-prompts.md:132-137`, `skills/radin-record/SKILL.md:161-164`, `skills/radin-execute/SKILL.md:377-379`.
12. "Act only on the `STATUS:` line, never on prose" — `skills/radin-execute/SKILL.md:337-338`, `:387-392`, `lib/radin-execute-prompts.md:218-220`, `:226-228`.
13. Companion-tool guidance (`codebase-memory-mcp` verbs, `rtk`, `headroom`) — `lib/radin-execute-prompts.md:131`, `:254-257`, `:291-297`; `skills/radin-plan/SKILL.md:100-108`; `skills/radin-review/SKILL.md:79-91`. Five copies with **different tool sets**: `detect_changes` in review and debug only, `get_architecture` and `index_repository` in plan only, `search_code` in fact-finding only — against `AGENTS.md`'s rule that graph tool names live in four files only.
14. "Never verify a `SUCCESS` yourself; Phase 6 owns it" — `skills/radin-execute/SKILL.md:367-369` vs `lib/radin-execute-reporting.md:26-28`.
15. `MAX_ATTEMPTS` semantics — `skills/radin-execute/SKILL.md:297-299`, `lib/radin-execute-resume.md:14-16`, `lib/radin-state.sh:15` and `:54-56`.
16. "A task's file path can never go stale" — `skills/radin-execute/SKILL.md:261-262`, `lib/radin-prioritization.md:108-113`, `skills/radin-plan/SKILL.md:93-95`, `lib/radin-backlog.sh:9-15`.
17. "Deferred at your request" handling — `skills/radin-execute/SKILL.md:190-192`, `:196-198`, `lib/radin-execute-reporting.md:44-45`.
18. "Never assume on a broad ask, invoke grilling" — `skills/radin-execute/SKILL.md:62-66`, `skills/radin-plan/SKILL.md:23-26`, `skills/radin-record/SKILL.md:23-28` and `:49-51`, `skills/radin-review/SKILL.md:17-20`. Four files, four different exemption clauses.
19. Non-interactive-caller behavior — `skills/radin-review/SKILL.md:19-20`, `:41-44`, `:136-138`, `:170-171`, `:204-205`; `skills/radin-plan/SKILL.md:14-21`, `:53`, `:66-68`, `:84`, `:111-113`, `:128-129`. Eleven per-branch restatements of one caller property.
20. `reconcile`'s purpose — `skills/radin-execute/SKILL.md:136-143` vs `lib/radin-backlog.sh:35`.
21. "Never hand-edit the backlog / compute its paths yourself" — `skills/radin-execute/SKILL.md:90-93`, `skills/radin-plan/SKILL.md:30-33`, `skills/radin-record/SKILL.md:18-21`, `skills/radin-review/SKILL.md:69-71`, `skills/radin-show/SKILL.md:21-22`, `lib/radin-prioritization.md:14`.
22. Category list (`feat`/`fix`/`chore`/`refactor`) — enumerated in `skills/radin-record/SKILL.md:119-127`, `skills/radin-show/SKILL.md:24-25`, `lib/radin-prioritization.md:21-23`, `lib/radin-backlog.sh:57`, and mapped to skills again in `lib/radin-execute-prompts.md:180-186`.

### Contradictions

 1. **Deps as prose vs deps as a field.** `skills/radin-record/SKILL.md:109-117` requires the dependency in the body because "prioritization reads entry bodies for exactly this signal"; `lib/radin-prioritization.md:45-49` and `:64-67` read `depends_on` off the index line, and `lib/radin-backlog.sh:24,31` expose `--depends-on` / `set-deps`. Record never sets the field, so the structured path is dead on the write side.
 2. **"Never hand-parse" vs "read the JSON".** `skills/radin-execute/SKILL.md:92-93`, `lib/radin-prioritization.md:96`, `skills/radin-plan/SKILL.md:31-32` vs `lib/radin-execute-resume.md:9` ("Read `BACKLOG_STEPS.json`") and `:20-23` ("re-read it"), `lib/radin-execute-reporting.md:25-26` (every `failed`/`blocked` entry with its note — no verb offers this), `skills/radin-setup-hooks/SKILL.md:19-21` (read `manifest.json`).
 3. **Concurrency.** `skills/radin-execute/SKILL.md:53-57` "Read-only dispatches **always** run in parallel ... several may share one message" vs `:31-33` "You don't choose foreground or background", plus the install-time token at `:58` that the model cannot see in the source. Two absolutes and an invisible third rule to reconcile.
 4. **Skill filtering applied twice with different lists.** The router drops four classes (`skills/radin-execute/SKILL.md:318-332`) while being told never to second-guess fit (`:318-320`); the sub-agent is told to drop three at runtime on its own read (`lib/radin-execute-prompts.md:158-165`).
 5. **Ordering stated three ways.** `lib/radin-prioritization.md:20-24` (the CLI already sorts, unset last), `:39-44` (rules 1-2 restate it as a rule to apply), `:58-63` (rule 5: skip the work entirely). A reader must derive that rules 1-2 are no-ops whenever rule 5 fires.
 6. **Dedupe owner.** `skills/radin-record/SKILL.md:179-182` "never scan for near-duplicates ... let `radin-execute`, `radin-plan`, or a human dedupe later" vs `lib/radin-execute-reporting.md:22-24`, which only flags duplicates and explicitly refuses to guess — so no named owner actually dedupes.
 7. **`/radin-plan` reachability.** `skills/radin-execute/SKILL.md:280-283` "Never run `/radin-plan` in this context" and `:328-330` lists it among skills to drop, while `lib/radin-execute-prompts.md:16-19` names `/radin-plan` and `/radin-review` as the exception sub-agents do invoke.

### Ambiguous conditionals

 1. `skills/radin-execute/SKILL.md:273-279` — "single obvious change" vs "multiple files, structural choice, ambiguous scope". No test, and it decides whether a whole planning sub-agent runs.
 2. `lib/radin-prioritization.md:74-79` — infer a dependency whenever two bodies "name the same files, functions, or behavior" and one "would alter what the other assumes". Unbounded, and it writes into the state file.
 3. `skills/radin-execute/SKILL.md:188-199` — "route on the task-selection answer first, then the order answer". If the order answer is `No`, the flow returns to step 1 and re-asks both; whether the just-applied selection survives the re-ask is unstated.
 4. `skills/radin-record/SKILL.md:82-86` — the gate's pass condition is "there is no second reasonable way to do this", with a separate stub exemption stated twice (`:27-28`, `:51-57`).
 5. `skills/radin-review/SKILL.md:136-138` vs `:140` — Step 5 opens with an unconditional "Ask one yes/no"; its non-interactive exemption lives only in the previous step.
 6. `skills/radin-review/SKILL.md:57-62` — "report it only when the in-scope change is what makes it wrong" for out-of-scope problems the diff worsens, immediately before "a finding you cannot tie to a specific in-scope line is not a finding" (`:65-66`).
 7. `lib/radin-execute-recovery.md:21-24` — "They satisfy the task: run `task-done`. They don't: mark `blocked`." The satisfy test is the model's read of `git show` against the task file, with no bar given.
 8. `skills/radin-stats/SKILL.md:33-34` — "Any other installed tool ... belongs in this list too. Add it here" reads as an instruction to edit the skill file, with no trigger or owner.
 9. `skills/radin-execute/SKILL.md:393-398` vs `:387-392` — "no report yet" vs "a report with no `STATUS:` line". The distinction rests on whether the dispatch returned at all, which the router cannot always tell apart from a turn that ended early.

### Length competing for attention

 1. `lib/radin-execute-prompts.md:124-229` — the execution fence runs ~105 lines: nine numbered steps plus `1a`, `1b`, `2a`, `2b`, each restating a capability rule, with the mandatory `STATUS:` contract only at `:208-220` and further imperatives after the list at `:222-228`.
 2. `skills/radin-execute/SKILL.md` — 449 lines, eight phases, seven on-demand files. `Core Constraints` (`:24-58`) pre-states what Phases 0.5, 2, 4b and 5 each state again (items 2, 3, 4, 5, 25).
 3. `lib/radin-prioritization.md:34-83` — six numbered rules plus a six-item weighted list, where rule 5 makes the weighted pass unreachable for a fully prioritized backlog, and the operative condition sits last (`:58-63`).
 4. `skills/radin-record/SKILL.md:149-172` — one heredoc whose body carries four multi-sentence bracketed authoring instructions, including bullet-indentation rules (`:168-171`).
 5. `skills/radin-review/SKILL.md:49-66` — a standalone "Scope discipline" section that Step 3 (`:104-105`) then orders restated inside each review invocation, and Step 4 (`:109-113`) re-applies as a filter.

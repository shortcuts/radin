# Shared: radin-execute Sub-Agent Prompts

The verbatim prompts `radin-execute` hands to its sub-agents. The agent
reads this file at the start of Phase 4, once per session, and copies the
relevant prompt into each `Task` call. They live here, not inline in the
agent, because a session that stops at Phase 2 (the common first turn) never
reaches Phase 4 and never needs them.

Every one of these runs in a sub-agent, which has no channel to the user and
cannot be notified about a background task. So no prompt here may send a
sub-agent into a skill that asks in prose or spawns its own agent — it would
end its turn with no `STATUS:` line and the orchestrator would see a hang.

Delegation stops here too: no prompt may tell a sub-agent to spawn a sub-agent
of its own. Whether the *orchestrator* runs several of these at once is settled
by the concurrency rule in `agents/radin-execute.md`, written there at install
time from the user's answer — never a sub-agent's call, and never restated in
this file.

Substitute the `UPPERCASE` placeholders before sending. Send every prompt
with `model: "sonnet"` and `run_in_background: false`.

---

## Planning prompt (Step 4a)

Replace `TASK_ID` with the task's id.

```
Invoke the `/radin-plan` skill scoped to the backlog task with id
"TASK_ID". Resolve it via `radin-backlog.sh find "TASK_ID"` and read its
file (everything in `$BACKLOG_TASKS_DIR/TASK_ID.md`) as the actual task
scope. It writes the plan file(s) and appends the `**Plan:**` pointer(s)
to that same task file.

You run non-interactively: where the skill would ask the user for
confirmation (splitting the entry, overwriting an existing plan), take
the non-destructive path instead — don't split, don't overwrite. Do NOT
implement anything. Do not spawn a sub-agent, and do not invoke a skill
that spawns one or a background task (`/grilling`, `/research`): you
cannot be notified when it finishes, so waiting on it hangs the run.
Something you can only settle that way is BLOCKED material.

The plan must settle every decision: the executor makes no judgment
calls. Anything the entry leaves genuinely open is BLOCKED material —
never something to leave vague in the plan for the executor to hit
later.

Before reporting BLOCKED for anything, ask: is this actually a fact I could
go find myself (read more of the repo, check a config, run a read-only
command), or is it a real judgment call only the user can make (keep vs
delete, approach A vs B, a preference)? Go find the fact yourself first —
never block on something checkable. Only block on genuine judgment calls.

Keep your report to a few lines, then the LAST line exactly one of:
`STATUS: PLANNED — <plan file path(s)>`
`STATUS: BLOCKED (FACT) — <what's unverifiable from here and why — e.g. a
third-party API/library behavior local code and repo exploration can't
settle>`
`STATUS: BLOCKED (DECISION) — <the decision question, the candidate
options, and your recommendation>`
Use BLOCKED (DECISION) when planning surfaces genuine ambiguity only the
user can resolve — never guess. That includes the skill matching several
entries for this title, or matching none (backlog drift): report what it
found, never pick one and never create a new entry. Use BLOCKED (FACT)
only for something you tried and failed to verify yourself, not as a
shortcut around exploring the repo.
```

---

## Execution prompt (Step 4b)

Replace `TASK_FILE` with `$BACKLOG_TASKS_DIR/<id>.md`, `PLAN_PATHS` with
the plan file path(s) in order (or "none — implement directly from the
entry" if Step 4a skipped planning), `SKILLS` with the collected
`**Skill:**` name(s) or "none", `DEPENDS_ON` with the list of
`<id>: <commit hash>` pairs gathered in Step 4a-0 (or "none" if
`depends_on` was empty), `NAMESPACE_DIR` with `$NAMESPACE_DIR`, and
`TASK_ID` with the task's id. The worktree/branch answers are not
substituted anywhere: `radin-state.sh prepare` reads them from
`session.json` itself.

```
Execute the task described in TASK_FILE:

Do the task yourself: never spawn a sub-agent, and never invoke a skill that
spawns one.

(When exploring the codebase: if `code-review-graph` is installed and wired for this repo, use its MCP tools—`semantic_search_nodes`, `get_impact_radius`, `query_graph`—before Grep/Glob/Read. When running commands: prefer `rtk`-wrapped commands if `command -v rtk` succeeds for token savings.)
1. Read TASK_FILE to understand the task
1a. Set up the tree you will work in. One command decides it, from the
   worktree/branch preference the user already recorded for this repo:
   `bash "$HOME/.claude/.radin/lib/radin-state.sh" prepare "NAMESPACE_DIR" "TASK_ID"`.
   It prints one absolute path on stdout. `cd` there and do every step below
   in it. Whatever it prints is right — the repo root or a worktree, on a task
   branch or the branch the user already had checked out. You never decide
   this: no `git worktree add`, no `git checkout -b`, no `git switch -c`, and
   no switching onto a `radin/<task-id>` branch you happen to notice. The
   user's answer may be "no" to either, and this command has already applied
   it. Non-zero exit: stop and report `STATUS: FAILED` with its message.
   Anything uncommitted in the tree it hands you is a dead attempt's
   leftovers — commit it as part of this task if it belongs there, otherwise
   revert it before you start.
2. If PLAN_PATHS is not "none", read them in order — plan(s) already written for this
   task by radin-plan. Follow them; do not re-derive an approach from scratch. If
   there's more than one, they cover different parts of the same task — implement all
   of them. If PLAN_PATHS is "none", the task was judged straightforward enough to skip
   planning — implement directly from the entry text.
2a. If SKILLS is not "none", invoke each named skill (e.g. `/frontend-design`) before
   implementing. The user chose that skill for this task — invoke it as instructed, do
   not judge whether it's needed, redundant, or the right fit. One exception, and it is
   about capability, not fit: you cannot reach the user and cannot be notified about a
   background task. If a skill starts asking you questions it expects a human to answer,
   or wants to spawn its own agent, stop invoking it, take the non-destructive path, and
   name it in your report as skipped. Never wait on it — a wait here is a hang the
   orchestrator cannot break.
2b. If DEPENDS_ON is not "none", this task's scope/plan was written assuming certain
   other tasks in this backlog would land a certain way. Those tasks already committed
   this session at the listed hashes. Run `git show --stat <hash>` for each and skim
   the diff for any file/function this task's plan also touches. If nothing overlaps,
   proceed normally. If something does overlap, check whether the dependency's actual
   changes still match what this task's plan/entry assumed:
   - Assumptions still hold: proceed normally.
   - They diverged in a way you can resolve yourself (e.g. a renamed function, a moved
     file, an adjusted signature the plan didn't foresee but the fix is mechanical):
     implement against the current code, not the stale assumption, and say what you
     adjusted in your report.
   - They diverged in a way that changes a design decision the plan made (not just a
     mechanical detail): do not guess which way to resolve it — report
     `STATUS: BLOCKED (DECISION)` per step 9, describing the divergence.
3. Implement all changes described — minimum code that satisfies the task, per ponytail
4. Where the task changes behavior (not a pure deletion/rename), add or update a unit
   test that pins the expected behavior — follow existing test conventions in the repo
5. Run any required checks (lint, tests, format) per project conventions
6. Fix any issues before committing
7. Invoke the `/caveman-commit` skill to draft the commit message, then commit. If `/caveman-commit` is unavailable, write a conventional-commit message yourself.
8. Run `bash "$HOME/.claude/.radin/lib/radin-state.sh" dirty-check "$(pwd)"` from the tree
   step 1a handed you, so the check covers the files you actually touched.
   If anything is still uncommitted (including changes made incidentally while
   investigating, e.g. formatter/linter auto-fixes), either commit it as part of this
   task's commit or a separate scoped commit — never leave the working tree dirty when
   you report back. Never commit, revert, or otherwise touch anything under
   `.claude/.radin/` — that's the orchestrator's state, not task work; whether it gets
   committed at all is the repo owner's call
9. Before reporting BLOCKED for anything, ask: is this a fact you could go find yourself
   (read more of the repo, check a config, run a read-only command, check how an
   existing similar case was handled), or a real judgment call only the user can make?
   Go find the fact yourself first — never block on something checkable.
   Report back the LAST line of your response as exactly one of:
   `STATUS: SUCCESS — <commit hash(es), or "no new commit, already satisfied by <existing
   hash>">`
   `STATUS: FAILED — <reason>`
   `STATUS: BLOCKED (FACT) — <what's unverifiable from here and why — e.g. a third-party
   API/library behavior local code and repo exploration can't settle>`
   `STATUS: BLOCKED (DECISION) — <the decision question, the candidate options, and your
   recommendation>`
   Use BLOCKED (DECISION) when the task needs a judgment call the entry text and plan(s)
   don't settle (keep vs delete, approach A vs B). Do NOT pick a default and implement a
   guess — revert anything you touched, leave the tree clean, and report BLOCKED (DECISION).
   Use BLOCKED (FACT) only for something you tried and failed to verify yourself.
   This line is mandatory whether the task was implemented, found already done, or
   blocked — the orchestrator only acts on this explicit line, never on inferring intent
   from prose.

Do NOT skip checks. Do NOT commit if checks are failing. Do NOT leave uncommitted
changes on the branch — commit everything you touched, or `git checkout`/revert it if
it turns out to be unnecessary.

Keep your report brief: at most a few lines on what changed, then the STATUS line.
The orchestrator acts only on the STATUS line — everything else you write bloats its
context for the rest of the session.
```

---

## Fact-finding prompt (Clarifying Ambiguity, `BLOCKED (FACT)`)

Replace `QUESTION` with the sub-agent's stated question, and `TASK_FILE` with
the task's file. Answers a checkable question in one turn, so the orchestrator
never waits on a background research agent it cannot be notified about.

```
Answer one factual question about this codebase or its dependencies, and
change nothing: QUESTION

Context: the task at TASK_FILE was blocked on it.

Investigate read-only — read the repo, its lockfiles, its vendored
dependencies, its config; run read-only commands (`--help`, `--version`, a
query, a dry run). Prefer primary sources already on this machine over
recollection. Do NOT edit, create, or commit any file. Do NOT invoke a skill
that asks a human anything or spawns its own agent or background task: you
cannot reach the user and cannot be notified, so either one hangs you.

Report the answer in a few lines, with the file path, command output, or
version that establishes it. Then the LAST line exactly one of:
`STATUS: FOUND — <the answer, one sentence>`
`STATUS: NOT FOUND — <what you checked, and why it cannot be settled from
here>`
Use NOT FOUND only after you have actually looked. A question that turns out
to need a human's preference rather than a fact is NOT FOUND — say so.
```

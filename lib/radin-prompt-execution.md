# Template: radin-batch execution prompt (Phase 4)

Source text for `radin prompt execution <id>` (`lib/radin-prompt.sh`), which drops the
guarded blocks that do not apply to the task, substitutes every `UPPERCASE`
placeholder, and prints the result.

The `model:` line below is this role's sub-agent model, written in at install
time; `radin-prompt.sh` reads it from here. A `<!-- if:NAME -->` … `<!-- end -->`
block survives only when that guard is active for the task, and
`<!-- if:!NAME -->` is its inverse.

`model: "RADIN_MODEL_EXECUTION"`
`model-chore: "RADIN_MODEL_CHORE"`

A `chore` task runs on the `model-chore:` line instead.

```
Execute the task below.

Report back the LAST line of your response as exactly one of:
`STATUS: SUCCESS — <commit hash(es), or "no new commit, already satisfied by <existing
hash>">`
`STATUS: FAILED — <reason>`
`STATUS: INCONCLUSIVE — <what could not be checked, and why>`
`STATUS: BLOCKED (FACT) — <what's unverifiable from here and why, e.g. a third-party
API/library behavior local code and repo exploration can't settle>`
`STATUS: BLOCKED (DECISION) — <what you need from the user (a decision, a confirmation,
guidance or a human action), the options, and your recommendation>`
This line is mandatory whether the task was implemented, found already done, or
blocked. The router acts on this line alone, and your final message is exactly
this one line.

Before you report, append each item below to the task, one line each, with
`RADIN_CLI backlog append "TASK_ID"` and a `**Fact:** [measured|inferred|guess] <the line>`
line on stdin. On SUCCESS, `task-done` keeps these lines in the task's facts
file for `/radin-review`. Label every `**Fact:**` line: `measured` when you ran
a command or read a file this session and the line names which, `inferred` when
it follows from measured facts the line names, `guess` otherwise. A line with no
label is a guess.

Ground rules, applying to every step below:
- You are a leaf: do the task yourself, spawn no sub-agent, and expect no
  `Workflow` tool.
- You cannot reach the user and have no `AskUserQuestion`. A skill that starts
  asking, spawning or launching a workflow: stop invoking it, take the
  non-destructive path, and record it as a `**Fact:**` line (see above).
  Waiting on one is a hang the router cannot break.
- When a route fails, take the next open one (another
  command, tool, angle or reading of the task), and let FAILED and
  INCONCLUSIVE name each route tried. Find any checkable fact yourself (read
  more of the repo, check a config, run a read-only command, check how an
  existing similar case was handled) and tag only the unverifiable one
  BLOCKED (FACT). Needing the user's answer, confirmation or an action on
  their side is BLOCKED (DECISION) carrying exactly what unblocks you, with
  anything you touched reverted so the tree is clean; it is never FAILED or
  INCONCLUSIVE.
- Never commit, revert, or otherwise touch anything under `.claude/.radin/` —
  it is the router's state, not task work, except the `RADIN_CLI backlog
  append` call above.
- Explore through `codebase-memory-mcp`'s MCP tools before Grep/Glob/Read: a
  graph hit is a pointer, so read the file before you cite or edit it, and
  never conclude something is absent from an empty result. Wrap commands in
  `rtk`, for the token savings.
- Your only stops are the `STATUS:` lines above. Work beyond the task that you think would help goes
  in a `**Fact:**` line, not in the diff.

<!-- if:EPIC_CONTEXT -->
Shared context for the epic this task belongs to, inherited by every task in
it:

<epic>
EPIC_CONTEXT
</epic>

<!-- end -->
1. Your task, in full. Anything the router appended to it is part of the task,
   not commentary: `**Decision:**` lines are settled and
   binding, and so are `**Fact:**` and `**Root cause:**` lines labeled
   `measured` or `inferred`; one labeled `guess` or unlabeled is a lead you
   check before relying on it. This text, plus whatever it names, is the only
   cross-agent context you get.

<task>
TASK_BODY
</task>
<!-- if:FACTS -->
   Read FACTS as well: it holds the long form of the evidence behind one of
   those lines.
<!-- end -->
<!-- if:LOCATION -->
   LOCATION is the `path:line` this task's finding was cited at; start there.
<!-- end -->
1a. Set up the tree you will work in:
   `RADIN_CLI state prepare "TASK_ID"`.
   It prints one absolute path on stdout, and that path is the tree — repo root
   or worktree, task branch or the branch the user already had checked out:
   `cd` there and do every step below in it. It has already applied the user's
   recorded answer, so the tree is never yours to choose: no `git worktree
   add`, no `git checkout -b`, no `git switch -c`, and no switching onto a
   `radin/<task-id>` branch you happen to notice. Non-zero exit: stop and
   report `STATUS: FAILED` with its message.
   The tree starts clean: `prepare` stashes anything it found uncommitted and
   says where, so no work you did not write is yours to commit or revert.
<!-- if:ACCEPTANCE -->
ACCEPTANCE
<!-- end -->
<!-- if:PLAN_PATHS -->
2. Read PLAN_PATHS in order: they are the plan(s) `/radin-plan` already wrote
   for this task. Follow them rather than re-deriving an approach. Several of
   them cover different parts of the same task, so implement all of them.
   Where the code contradicts a plan step: a mechanical deviation (renamed
   function, moved file, adjusted signature) you adjust and record as a
   `**Fact:**` line; a deviation that changes a decision the plan made is
   `STATUS: BLOCKED (DECISION)`, describing it.
<!-- end -->
<!-- if:!PLAN_PATHS -->
2. This task has no plan, so implement directly from the entry text.
<!-- end -->
<!-- if:SKILLS -->
2a. Invoke each skill named here before implementing: SKILLS
   The user chose it for this task, so invoke it as instructed rather than
   judging whether it is needed, redundant, or the right fit.
<!-- end -->
<!-- if:DEPENDS_ON -->
2b. This task's scope/plan was written assuming other tasks would land a
   certain way. They already committed this session: DEPENDS_ON
   Run `git show --stat <hash>` for each and skim the diff for any
   file/function this task also touches. Nothing overlaps, or the assumptions
   still hold: proceed. A mechanical divergence (renamed function, moved file,
   adjusted signature): implement against the current code and record what
   you adjusted as a `**Fact:**` line. A divergence that changes a design
   decision the plan made: report `STATUS: BLOCKED (DECISION)` describing it,
   and guess nothing.
<!-- end -->
<!-- if:STALE_PLAN -->
2c. Commits landed after this task's plan was written and touched the files
   it names: STALE_PLAN
   Run `git show --stat <hash>` for each and skim the diff against the plan's
   steps. Nothing overlaps, or the assumptions still hold: proceed. A
   mechanical divergence (renamed function, moved file, adjusted signature):
   implement against the current code and record what you adjusted as a
   `**Fact:**` line. A divergence that changes a design decision the plan
   made: report `STATUS: BLOCKED (DECISION)` describing it, and guess
   nothing.
<!-- end -->
<!-- if:CAT_fix -->
3. Invoke `/caveman:surgical-patch` and implement through it: the narrowest
   layer that fixes it, with regression proof.
<!-- end -->
<!-- if:CAT_refactor -->
3. Invoke `/caveman:safe-refactor` and implement through it: verification
   brackets the structural edit.
<!-- end -->
<!-- if:CAT_feat -->
3. Invoke `/caveman:lean-build` and implement through it: reuse first, with an
   explicit stop condition.
<!-- end -->
<!-- if:CAT_chore -->
3. No category skill applies: the ladder below is the whole discipline.
<!-- end -->
   Apply the `/ponytail:ponytail` ladder in every case: the minimum code that
   satisfies the task, reusing what the repo already has. Its SubagentStart
   hook already put the ladder in your context, so invoke no skill for it. Use
   `headroom sg` (ast-grep) for mechanical multi-site renames and signature
   changes; hand-edit each site otherwise.
4. Where the task changes behavior (not a pure deletion/rename), add or update a unit
   test that pins the expected behavior, following existing test conventions in the repo.
   Run it without your change and confirm it fails for the reason the task
   names, then with your change and confirm it passes. A test that passes
   either way, or fails for another reason, pins nothing: correct it first.
   Make the code correct for every valid input, not only the tested ones. A
   test you believe is wrong is `STATUS: BLOCKED (DECISION)`, never code to
   work around.
   For each such test, record a `**Fact:**` line: `test <name>: failed before
   (<its failure>), passes now`.
5. Choose the checks from what your diff reaches: ask `codebase-memory-mcp`
   for the symbols your working-tree diff changes and their callers. Run the
   typecheck and the tests that exercise those callers as you go, widening to
   the whole suite only when the blast radius covers most of the repo. Once
   before committing, run lint and format scoped to the packages or
   directories you touched.
   A check counts only when it ran and exercised the change: a syntax-only
   check, or one that failed to start, does not. If all that is missing is
   the project's declared dependencies, install them with its own package
   manager and lockfile, never with sudo or the system package manager. If
   no real check can run here, record which one and why as a `**Fact:**`
   line. For a task that changes behavior, revert everything you touched,
   leave the tree clean, and report `STATUS: INCONCLUSIVE`. A check only the user can run (a device, a credential,
   an action on their side) is `STATUS: BLOCKED (DECISION)` naming it. A task with no behavior change keeps the `**Fact:**`
   line and continues.
   Prove the change on the real artifact: run the changed code path itself and
   read its actual output. "It compiles" and a passing proxy are not proof.
   A check that fails: suspect your observation (wrong command, stale build)
   before the code, then fix and re-run that same check until it is green. After
   three fix rounds on one failure, report `STATUS: FAILED` with its output. A
   test that still passes when the code under test returns nothing pins
   nothing: assert literal expected values.
   Fix what the checks surface before step 6.
5a. Stage your task's files (`git add <paths>`, never `.claude/.radin/`) and
   invoke `/radin-review` with scope `staged` and spec `TASK_ID`, inline. Fix
   every `critical` and `warning` finding in the tree, re-run step 5's checks,
   restage and review again. Two rounds at most: a `critical` still standing
   then is `STATUS: FAILED` with its citation. Fix a `nit` finding only when
   it sits in a file you staged; the skill writes no backlog entry.
6. Invoke the `/caveman:caveman-commit` skill to draft the commit message, then commit.
7. Run `RADIN_CLI state dirty-check` from the tree
   step 1a handed you, so the check covers the files you actually touched.
   Delete any scratch file or script you created only to iterate. If anything
   else is still uncommitted (including changes made incidentally while
   investigating, e.g. formatter/linter auto-fixes), either commit it as part of this
   task's commit or a separate scoped commit. Never leave the working tree dirty when
   you report back.
```

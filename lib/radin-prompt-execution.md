# Template: radin-execute execution prompt (Phase 4)

Source text for `radin prompt execution <id>` (`lib/radin-prompt.sh`), which drops the
guarded blocks that do not apply to the task, substitutes every `UPPERCASE`
placeholder, and prints the result. The router sends that output and never
reads this file.

The `model:` line below is this role's sub-agent model, written in at install
time from the user's answer; `radin-prompt.sh` reads it from here, so it lives
in one place. A `<!-- if:NAME -->` … `<!-- end -->` block survives only when
that guard is active for the task, and `<!-- if:!NAME -->` is its inverse.

The fence states the leaf contract itself: a sub-agent receives only the fence.

`model: "RADIN_MODEL_EXECUTION"`
`model-chore: "RADIN_MODEL_CHORE"`

A `chore` task runs on the `model-chore:` line instead.

```
Execute the task below.

Report back the LAST line of your response as exactly one of:
`STATUS: SUCCESS — <commit hash(es), or "no new commit, already satisfied by <existing
hash>">`
`STATUS: FAILED — <reason>`
`STATUS: BLOCKED (FACT) — <what's unverifiable from here and why, e.g. a third-party
API/library behavior local code and repo exploration can't settle>`
`STATUS: BLOCKED (DECISION) — <the decision question, the candidate options, and your
recommendation>`
This line is mandatory whether the task was implemented, found already done, or
blocked. The router acts only on this explicit line alone, never on intent
inferred from prose, and your final message is exactly this one line with
nothing before it.

Before you report, append each item below to the task, one line each, with
`RADIN_CLI backlog append "TASK_ID"` and a `**Fact:** <the line>` line on
stdin. On SUCCESS, `task-done` keeps these lines in the task's facts file for
`/radin-review`.

Ground rules, applying to every step below:
- You are a leaf: do the task yourself, spawn no sub-agent, and expect no
  `Workflow` tool (`/deep-research` and any saved workflow command fail).
- You cannot reach the user and have no `AskUserQuestion`. A skill that starts
  asking, spawning or launching a workflow: stop invoking it, take the
  non-destructive path, and record it as a `**Fact:**` line (see above).
  Waiting on one is a hang the router cannot break.
- Before reporting BLOCKED, ask whether this is a fact you could go find
  yourself (read more of the repo, check a config, run a read-only command,
  check how an existing similar case was handled) or a judgment call only the
  user can make. Find the fact yourself; tag the judgment call BLOCKED
  (DECISION), reverting anything you touched so the tree is clean, and the
  unverifiable fact BLOCKED (FACT).
- Never commit, revert, or otherwise touch anything under `.claude/.radin/` —
  it is the router's state, not task work, except the `RADIN_CLI backlog
  append` call above.
- Explore through `codebase-memory-mcp`'s MCP tools before Grep/Glob/Read: a
  graph hit is a pointer, so read the file before you cite or edit it, and
  never conclude something is absent from an empty result. Wrap commands in
  `rtk`, for the token savings.
- Keep working until the task is done and checked: your only stops are the
  `STATUS:` lines above. Work beyond the task that you think would help goes
  in a `**Fact:**` line, not in the diff.

<!-- if:EPIC_CONTEXT -->
Shared context for the epic this task belongs to, inherited by every task in
it:

<epic>
EPIC_CONTEXT
</epic>

<!-- end -->
1. Your task, in full. Anything the router appended to it is part of the task,
   not commentary: `**Decision:**`, `**Fact:**`, and `**Root cause:**` lines
   are settled and binding. This text, plus whatever it names, is the only
   cross-agent context you get, and that is deliberate: no other task's
   material reaches you.

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
   line.
<!-- if:TESTS_AT_END -->
   Fix what the checks surface before step 6. The router's session gate runs the
   whole suite once after the last task.
<!-- end -->
<!-- if:!TESTS_AT_END -->
   Then run the project's full check suite, as its own docs or CI config
   define it, once. Fix what they surface before step 6.
<!-- end -->
6. Invoke the `/caveman:caveman-commit` skill to draft the commit message, then commit.
7. Run `RADIN_CLI state dirty-check` from the tree
   step 1a handed you, so the check covers the files you actually touched.
   Delete any scratch file or script you created only to iterate. If anything
   else is still uncommitted (including changes made incidentally while
   investigating, e.g. formatter/linter auto-fixes), either commit it as part of this
   task's commit or a separate scoped commit. Never leave the working tree dirty when
   you report back.
```

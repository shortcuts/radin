# Template: radin-batch execution prompt (Phase 4)

Rendered by `radin prompt execution <id>`. `src/prompt.rs` holds the format.

<!-- host:claude -->
`model: "RADIN_MODEL_EXECUTION"`
`effort: "RADIN_EFFORT_EXECUTION"`
<!-- /host -->

```
Execute the task below.

Your final message is exactly one of these lines, and nothing else:
`STATUS: SUCCESS — <commit hash(es), or "no new commit, already satisfied by <existing
hash>">; built: <what now works, one clause>; chose: <each judgment call you
made and why, or "none">; open: <what you skipped, did not check, or a risk the user must know, or "none">; checks:
test=<pass|na>, lint=<pass|na>, review=pass`
`STATUS: FAILED — <reason>`
`STATUS: INCONCLUSIVE — <what could not be checked, and why>`
`STATUS: BLOCKED (FACT) — <what's unverifiable from here and why, e.g. a third-party
API/library behavior local code and repo exploration can't settle>`
`STATUS: BLOCKED (DECISION) — <the action only the user can take (a device, a
credential, a path to delete), the options, and your recommendation>`
This line is mandatory whether the task was implemented, found already done, or
blocked. The `checks:` clause is mandatory and last. `pass` means the check ran
this session and exercised the change. `na` is allowed for `test` and `lint`
only when step 5 or step 8 found nothing to run and a `**Fact:**` line says
why. `review` is the step 9 review. Any other value or a missing item makes the
router record `STATUS: INCONCLUSIVE`. `built:` names only what your own commits add. Credit work already on the branch to its hash in the first clause. The router acts on this line alone. Your commit stays on your own branch, and the router records the task done after the merge.

Before you report, record each item below with one call per line:
`RADIN_CLI backlog fact "TASK_ID" <measured|inferred|guess> "<the line>"`. On SUCCESS, `task-done` keeps these lines in the task's facts
file for `/radin-review`. Label every `**Fact:**` line: `measured` when you ran
a command or read a file this session and the line names which, `inferred` when
it follows from measured facts the line names, `guess` otherwise.

LEAF_CONTRACT

Ground rules, applying to every step below:
- Record any skill you stopped invoking as a `**Fact:**` line (see above).
- When a route fails, take the next open one (another
  command, tool, angle or reading of the task), and let FAILED and
  INCONCLUSIVE name each route tried. Find any checkable fact yourself (read
  more of the repo, check a config, run a read-only command, check how an
  existing similar case was handled) and tag only the unverifiable one
  BLOCKED (FACT). Needing an action only the user can take is BLOCKED
  (DECISION) carrying exactly what unblocks you, with anything you touched
  reverted so the tree is clean; it is never FAILED or INCONCLUSIVE. Every
  other choice is yours: take the option closest to the task's intent and name
  it in `chose:`.
- Never commit, revert, or otherwise touch anything under `.radin/`.
  It is the router's state, not task work, except the `RADIN_CLI backlog
  fact` calls above.
- Explore by this rule:

EXPLORE_RULE

- Your only stops are the `STATUS:` lines above. Work beyond the task that you think would help goes
  in a `**Fact:**` line, not in the diff. A check red on the base is the
  exception: step 8 fixes it.

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
2. Set up the tree you will work in:
   `RADIN_CLI state prepare "TASK_ID"`.
   It prints one absolute path on stdout, and that path is the tree — repo root
   or worktree, task branch or the branch the user already had checked out:
   `cd` there and do every step below in it. It has already applied the user's
   recorded answer, so the tree is never yours to choose: no `git worktree
   add`, no `git checkout -b`, no `git switch -c`, and no switching onto a
   `radin/<task-id>` branch you happen to notice. Non-zero exit: stop. When the
   message says a path exists but is not a registered worktree, delete nothing and
   report `STATUS: BLOCKED (DECISION)` naming that path, the options `Remove it` and
   `Leave it`, and `Leave it` as your recommendation. Otherwise report
   `STATUS: FAILED` with its message.
<!-- if:!STASH_BASE -->
   The tree starts clean: `prepare` committed anything it found uncommitted as a
   `wip:` commit and says where, so no work you did not write is yours to revert.
<!-- end -->
<!-- if:STASH_BASE -->
   Stashed work was triaged as the base of this task. `prepare` then prints
   "applied stash" on stderr: the tree starts from that uncommitted work. Read
   it as a draft: keep what the task needs, fix or finish it, and commit it
   with your own work. Never revert it wholesale. Never run `git stash
   apply` or `git stash pop` on the stash `prepare` made. `prepare` prints
   "did not apply" instead: the tree is clean, so work from scratch.
<!-- end -->
<!-- if:ACCEPTANCE -->
ACCEPTANCE
<!-- end -->
<!-- if:PLAN_PATHS -->
3. Read PLAN_PATHS in order: they are the plan(s) `/radin-plan` already wrote
   for this task. Follow them rather than re-deriving an approach. Several of
   them cover different parts of the same task, so implement all of them.
   Each `You see:` line under `## Changes` and each `- [ ]` box under
   `## Testing` is a check you run.
   Where the code contradicts a plan step: a mechanical deviation (renamed
   function, moved file, adjusted signature) you adjust and record as a
   `**Fact:**` line; a deviation that changes a decision the plan made you
   settle closest to the plan's intent and name in `chose:`.
<!-- end -->
<!-- if:!PLAN_PATHS -->
3. This task has no plan, so implement directly from the entry text.
<!-- end -->
<!-- if:SKILLS -->
Invoke each skill named here before implementing: SKILLS
   The user chose it for this task, so invoke it as instructed rather than
   judging whether it is needed, redundant, or the right fit.
<!-- end -->
<!-- if:DEPENDS_ON -->
This task's scope/plan was written assuming other tasks would land a
   certain way. They already committed this session: DEPENDS_ON
<!-- end -->
<!-- if:STALE_PLAN -->
Commits landed after this task's plan was written and touched the files
   it names: STALE_PLAN
<!-- end -->
<!-- if:DRIFT -->
   Run `git show --stat <hash>` for each commit above and skim the diff
   against the files and plan steps this task touches. Nothing overlaps, or
   the assumptions still hold: proceed. A mechanical divergence (renamed
   function, moved file, adjusted signature): implement against the current
   code and record what you adjusted as a `**Fact:**` line. A divergence that
   changes a design decision the plan made: settle it closest to the plan's
   intent and name it in `chose:`.
<!-- end -->
<!-- if:CAT_fix -->
4. Invoke `@@skill:surgical-patch@@` and implement through it: the narrowest
   layer that fixes it, with regression proof.
<!-- end -->
<!-- if:CAT_refactor -->
4. Invoke `@@skill:safe-refactor@@` and implement through it: verification
   brackets the structural edit.
<!-- end -->
<!-- if:CAT_feat -->
4. Invoke `@@skill:lean-build@@` and implement through it: reuse first, with an
   explicit stop condition.
<!-- end -->
<!-- if:CAT_chore -->
4. No category skill applies: the ladder below is the whole discipline.
<!-- end -->
   Apply the `@@skill:ponytail@@` ladder in every case. Its SubagentStart
   hook already put the ladder in your context, so invoke no skill for it.
5. Where the task changes behavior (not a pure deletion/rename), add or update a unit
   test that pins the expected behavior, following existing test conventions in the repo.
   Run it without your change and confirm it fails for the reason the task
   names, then with your change and confirm it passes. A test that passes
   either way, or fails for another reason, pins nothing: correct it first.
   Make the code correct for every valid input, not only the tested ones. A
   test you believe is wrong: correct the test, never work around it in code,
   and name it in `chose:`.
   For each such test, record a `**Fact:**` line: `test <name>: failed before
   (<its failure>), passes now`.
6. Comments in the code you write follow this rule:

COMMENT_RULE

7. Build in small units: one change, run its check, then the next. A unit
   that turns a check red is the one to fix before you move on.
8. Choose the checks from what your diff reaches: ask the graph
   for the symbols your working-tree diff changes and their callers. Run the
   typecheck and the tests that exercise those callers as you go, and no
   others: the session gate runs the whole suite once. Once before committing, run lint and format scoped to the packages or
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
   read its actual output. "It compiles", a passing proxy and a check on the
   wrong surface are not proof.
   Record one `backlog fact` line per acceptance criterion and per plan box,
   labeled `measured`: `<criterion or box>: <the command and the output that
   proves it>`. A criterion or box you could not prove makes the task
   `STATUS: INCONCLUSIVE` naming it, never `SUCCESS`.
   A check that fails: suspect your observation (wrong command, stale build)
   before the code, then fix and re-run that same check until it is green. After
   three fix rounds on one failure, report `STATUS: FAILED` with its output. A
   test that still passes when the code under test returns nothing pins
   nothing: assert literal expected values.
   A check that fails outside your diff: save your changes with
   `git stash push -u`, re-run that check on
   the base, then `git stash pop` (pop only when the stash saved something).
   Before you judge a red check, run `RADIN_CLI state base-failing "TASK_ID"`: a listed name is red on the base, so skip its stash re-run and never claim it as your regression. After the re-run, pipe the red names into `RADIN_CLI state base-failing "TASK_ID" --set`, one per line.
   An ignored `.radin/` stays in place. When `git check-ignore -q .radin` fails,
   append `-- . ':(exclude).radin'`: git rejects that pathspec for an ignored path. Red on
   the base too: fix it in this task through `@@skill:surgical-patch@@`, as its
   own commit. A fix out of reach: file it
   with `RADIN_CLI backlog add fix "<short title>" --location "<path:line>"`
   and a body that gives the failing check, its output and the cause, then
   finish your own task. A red base never makes the task `INCONCLUSIVE`.
   Fix what the checks surface before step 10.
9. Stage your task's files (`git add <paths>`, never `.radin/`) and
   follow the review brief at the end of this prompt at level `diff`: spec the
   plan(s) above, else this task, plus its acceptance criteria. Fix every
   `critical` and `warning` finding in the tree, re-run step 8's checks,
   restage and review again. Two rounds at most: a `critical` still standing
   then is `STATUS: FAILED` with its citation. Fix a `nit` finding only when
   it sits in a file you staged.
10. Invoke the `@@skill:caveman-commit@@` skill to draft the commit message, then commit.
11. Run `RADIN_CLI state dirty-check` from the tree
   step 2 handed you, so the check covers the files you actually touched.
   Delete any scratch file or script you created only to iterate. If anything
   else is still uncommitted (including changes made incidentally while
   investigating, e.g. formatter/linter auto-fixes), either commit it as part of this
   task's commit or a separate scoped commit. Never leave the working tree dirty when
   you report back.

Review brief (step 9):

REVIEW_CORE
```

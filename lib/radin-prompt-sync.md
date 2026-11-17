# Template: radin-batch lane sync prompt

Rendered by `radin prompt sync`. `src/prompt.rs` holds the format.

<!-- host:claude -->
`model: "RADIN_MODEL_EXECUTION"`

`effort: "RADIN_EFFORT_EXECUTION"`
<!-- /host -->

```
Work only in SYNC_DIR, the worktree of lane SYNC_LANE. A merge of SYNC_BASE into
the lane is in progress and has conflicts. Touch nothing under `.radin/`.
LEAF_CONTRACT

List the conflicted files with `git diff --name-only --diff-filter=U`.

Read the context of both sides. For each commit of `git log SYNC_BASE..HEAD`
and of `git log HEAD..SYNC_BASE`, run `RADIN_CLI state trace <commit>` to get its
task, then read the task with `RADIN_CLI backlog field <id> TASK_BODY` and
`RADIN_CLI backlog field <id> ACCEPTANCE`.

Resolve each conflict so both sides keep their intent. Run the repo's checks the
conflicting files reach. Stage the resolution and run `git commit --no-edit`.

When the acceptance criteria of two tasks exclude each other, run `git merge
--abort` and report a decision. You never pick between two product behaviors.

Your final message is exactly one of these lines, and nothing else:
`STATUS: SUCCESS — synced SYNC_LANE at <hash>`
`STATUS: BLOCKED (DECISION) — <the two behaviors in conflict>`
`STATUS: FAILED — <why the merge or its checks failed>`
```

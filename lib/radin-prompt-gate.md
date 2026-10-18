# Template: radin-batch session gate prompt (Phase 4.5)

Rendered by `radin prompt gate`. `lib/radin-prompt.sh` holds the format.

`model: "RADIN_MODEL_EXECUTION"`

```
Run this repo's full check suite (lint, tests, format), as its own docs or CI
config define it, `rtk`-wrapped. Run it once at the tip of each branch that
holds one of the commits below (`git branch --contains`). A branch checked out
in a linked worktree runs in that worktree (`git worktree list`). Touch nothing
under `.claude/.radin/`, and leave each checkout on the branch it started on.
LEAF_CONTRACT

The session's commits, oldest first: SESSION_COMMITS.

Green: report `STATUS: SUCCESS — suite green at <tip hash(es)>`.

Red: for each failing check, find the commit that broke it with
`git bisect run` over `<that branch's oldest session commit>^..<its tip>`,
running only that check, then `git bisect reset`. Fix forward on that branch
through `/caveman:surgical-patch`, commit through `/caveman:caveman-commit`
naming the culprit commit, and re-run the full suite. Leave the tree clean.

The LAST line is exactly one of:
`STATUS: SUCCESS — <"suite green at <hash>", or "fixed in <hash(es)>, culprit <hash(es)>">`
`STATUS: FAILED — <failing check>, culprit <hash>, <why no fix landed>`
`STATUS: INCONCLUSIVE — <check that could not run, and why>`
```

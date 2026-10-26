# Template: radin-batch session gate prompt (Phase 4.5)

Rendered by `radin prompt gate`. `lib/radin-prompt.sh` holds the format.

`model: "RADIN_MODEL_EXECUTION"`

`effort: "RADIN_EFFORT_EXECUTION"`

```
Run this repo's full check suite (lint, tests, format), as its own docs or CI
config define it, `rtk`-wrapped. Run it once at the tip of each branch
listed below, in the worktree on its line. Touch nothing under
`.claude/.radin/`, and leave each checkout on the branch it started on.
LEAF_CONTRACT

The session's branches, one per line: branch, tip, worktree, oldest session
commit, TAB-separated.
GATE_MAP

Green: report `STATUS: SUCCESS — suite green at <tip hash(es)>`.

Red: for each failing check, find the commit that broke it with
`git bisect run` over `<oldest session commit>^..<tip>` from its line,
running only that check, then `git bisect reset`. Fix forward on that branch
through `/caveman:surgical-patch`, commit through `/caveman:caveman-commit`
naming the culprit commit, and re-run the full suite. Leave the tree clean.

Your final message is exactly one of these lines, and nothing else:
`STATUS: SUCCESS — <"suite green at <hash>", or "fixed in <hash(es)>, culprit <hash(es)>">`
`STATUS: FAILED — <failing check>, culprit <hash>, <why no fix landed>`
`STATUS: INCONCLUSIVE — <check that could not run, and why>`
```

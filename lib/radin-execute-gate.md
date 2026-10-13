# Shared: radin-execute Session Gate

`radin-execute` reads this file at Phase 4.5, once per session that recorded a commit.

Dispatch one gate sub-agent (`model: "RADIN_MODEL_EXECUTION"`) with exactly:

```
Run this repo's full check suite (lint, tests, format), as its own docs or CI
config define it, `rtk`-wrapped. Run it once at the tip of each branch that
holds one of the commits below (`git branch --contains`). A branch checked out
in a linked worktree runs in that worktree (`git worktree list`). Touch nothing
under `.claude/.radin/`, and leave each checkout on the branch it started on.
You are a leaf: no user, no `AskUserQuestion`, no `Workflow`, no sub-agent of
your own.

The session's commits, oldest first: <commit hashes recorded in Phase 4>.

Green: report `STATUS: SUCCESS — suite green at <tip hash(es)>`.

Red: for each failing check, find the commit that broke it with
`git bisect run` over `<that branch's oldest session commit>^..<its tip>`,
running only that check, then `git bisect reset`. Fix forward on that branch
through `/caveman:surgical-patch`, commit through `/caveman:caveman-commit`
naming the culprit commit, and re-run the full suite. Leave the tree clean.

The LAST line is exactly one of:
`STATUS: SUCCESS — <"suite green at <hash>", or "fixed in <hash(es)>, culprit <hash(es)>">`
`STATUS: FAILED — <failing check>, culprit <hash>, <why no fix landed>`
```

Carry each fix hash into Phase 6's commit list. A `FAILED` line, or a last
line that is not a `STATUS:` line, goes to the user after the Phase 5 summary,
verbatim.

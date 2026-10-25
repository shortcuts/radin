# Template: radin-batch merge prompt (Phase 5.5)

Rendered by `radin prompt merge`. `lib/radin-prompt.sh` holds the format.

`model: "RADIN_MODEL_EXECUTION"`

```
Merge each task branch below into MERGE_BASE, in the listed order, with
`git merge <branch>`. Run every merge in the main checkout (`git rev-parse
--show-toplevel` of the repo, not a linked worktree), after `git checkout
MERGE_BASE`. Touch nothing under `.claude/.radin/`.
LEAF_CONTRACT

The branches are ones `radin state merge` could not merge cleanly.

The branches, as `branch (task commit)`: MERGE_BRANCHES.

A clean merge: continue with the next branch.

A conflict: resolve it so both sides keep their intent, run the repo's checks
the conflicting files reach, and finish the merge commit. When the two sides
change the same behavior in ways that exclude each other, run `git merge
--abort`, leave that branch as it is, and report it as a decision. You never
pick between two product behaviors.

After a branch merges, remove its worktree (`git worktree remove <path>`, path
from `git worktree list`) and delete it with `git branch -d`. `-d` refuses an
unmerged branch: never use `-D`. Leave an unmerged branch and its worktree in
place. Leave the checkout on MERGE_BASE with a clean tree.

Your final message is exactly one of these lines, and nothing else:
`STATUS: SUCCESS — merged <branch list> into MERGE_BASE at <tip hash>`
`STATUS: BLOCKED (DECISION) — <branch>: <the two behaviors in conflict>; merged <branch list, or "none">`
`STATUS: FAILED — <branch>, <why the merge or its checks failed>; merged <branch list, or "none">`
```

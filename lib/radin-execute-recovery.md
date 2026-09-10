# Shared: radin-execute Crash Recovery

`radin-execute` reads this file only when `radin-state.sh stuck` exits 0 —
a previous run dispatched a task and never got a terminal status for it.
Most runs never load it.

A stuck task's sub-agent died with the session, so what it left on disk is
unknown. Never re-dispatch one blind. For each id `stuck` printed:

```bash
radin state triage "$NAMESPACE_DIR" "<task id>"
```

It prints facts only (`attempts`, `completed`, `worktree`, `branch`, each
`branch_commit`, and `dirty_files`) and decides nothing. Route on them:

- `completed` names a hash: the crash hit between the commit and the
  bookkeeping. Re-run `task-done` with that hash; the CLI skips whatever
  already happened.
- `branch_commit` lines exist: the dead sub-agent committed the work but
  never reported. Read those commits (`git show`) against the task file. They
  satisfy the task: run `task-done` with the last hash. They don't: treat the
  partial work as the user's call, so mark the task `blocked`, `note` naming
  the branch and worktree to inspect.
- No commits, `dirty_files` is 0: nothing was left behind. `set-status` back
  to `pending` and let the loop retry it normally.
- No commits but `dirty_files` is non-zero: `stash` the tree it names, then
  `set-status` `pending` with the stash ref in the `note`.

Report every recovery decision in the Phase 5 summary.

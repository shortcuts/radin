# Shared: radin-batch Worktree/Branch Answers

`radin-batch` reads this file only when `RADIN_CLI state preflight` prints
`session<TAB>missing` at Phase 0. No worktree/branch answer is recorded for this repo yet.

The two answers are not independent. `worktree: yes` gives every task, solo or
parallel, `radin/<task-id>` in its own worktree. `worktree: no` never makes a
worktree, and `branch` applies only then: a branch in the main checkout on
`yes`, a commit to the base on `no`. The
`worktree` answer also sets concurrency, per the Core Constraints of
`RADIN_LIB/radin-run.md`. Say both when you ask.

Take the invoking prompt's preference if it states one, otherwise ask both in
<!-- host:claude -->
the same `AskUserQuestion` call as Phase 2's task selection, so one call
<!-- /host -->
<!-- host:agents -->
the same ask as Phase 2's task selection, so one call
<!-- /host -->
covers all three questions. Then persist them:

```bash
RADIN_CLI state session-set "<worktree yes|no>" "<branch yes|no>"
```

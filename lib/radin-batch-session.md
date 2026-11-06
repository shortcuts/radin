# Shared: radin-batch Worktree/Branch Answers

`radin-batch` reads this file only when `RADIN_CLI state preflight` prints
`session<TAB>missing` at Phase 0. No worktree/branch answer is recorded for this repo yet.

The two answers are not independent. `worktree: yes` allows a worktree only
for a group of 2 or more parallel tasks: each gets `radin/<task-id>` in its own
worktree. Any other task follows `branch`: a branch in the main checkout on
`yes`, a commit to the base on `no`. `worktree: no` never makes a worktree. The
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

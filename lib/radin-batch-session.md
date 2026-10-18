# Shared: radin-batch Worktree/Branch Answers

`radin-batch` reads this file only when `RADIN_CLI state session-get` exits 1
at Phase 0.5. No worktree/branch answer is recorded for this repo yet.

The two answers are not independent. A worktree cannot share the checkout's
branch, so `worktree: yes` always creates `radin/<task-id>` and the `branch`
answer changes nothing. `branch` decides only what happens under
`worktree: no`. The `worktree` answer also sets concurrency, per the Core
Constraints of `RADIN_LIB/radin-run.md`. Say both when you ask.

Take the invoking prompt's preference if it states one, otherwise ask both in
the same `AskUserQuestion` call as Phase 2's task selection, so one call
covers all three questions. Then persist them:

```bash
RADIN_CLI state session-set "<worktree yes|no>" "<branch yes|no>"
```

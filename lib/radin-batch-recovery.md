# Shared: radin-batch Crash Recovery

`radin-batch` reads this file only when `RADIN_CLI state preflight` prints a `stuck` line.
A previous run dispatched a task and never got a terminal status for it.

A stuck task's sub-agent died with the session, so what it left on disk is
unknown. Never re-dispatch one blind. For each id `stuck` printed:

```bash
RADIN_CLI state recover "<task id>"
```

Exit 0: it finished the recovery. Print the
`recovered<TAB><id><TAB><what it did>` line it printed and move on.

Exit 3: the one branch no command can settle. A dead sub-agent committed work
on the task's branch but never reported, so it printed the `branch`,
`worktree` and `branch_commit` lines. The bar is the criteria the entry states:

```bash
RADIN_CLI backlog meta "<task id>"
```

It prints one `acceptance<TAB><criterion>` line per criterion the entry states,
and none when it states none.

- **No `acceptance` line**: `RADIN_CLI state recover-reject "<task id>"`.
  Partial work is the user's call, and the command blocks the entry naming the
  branch and worktree to inspect. It needs no read of the commits.
- **At least one `acceptance` line**: never run `git show` yourself, because
  a large commit would fill the session's context. Dispatch one read-only
  sub-agent (`model: "RADIN_MODEL_REVIEW"`, `effort: "RADIN_EFFORT_REVIEW"`, `name: "radin-recover-<task id>"`; omit `effort` when it is empty).
  Send it the `branch_commit` hashes, the `worktree` path and the criteria,
  and ask it to read the commits against every criterion without editing
  anything. It ends with `STATUS: SUCCESS — <last hash>` when the commits meet
  every criterion, else `STATUS: FAILED — <the missed criterion>`.
  - **SUCCESS**: `RADIN_CLI state task-done "<task id>" "<last hash>"`.
  - **FAILED**, a criterion it cannot settle without running the project's
    checks, or no `STATUS:` line: `RADIN_CLI state recover-reject "<task id>"`.

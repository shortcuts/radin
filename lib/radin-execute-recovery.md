# Shared: radin-execute Crash Recovery

`radin-execute` reads this file only when `radin-state.sh stuck` exits 0 —
a previous run dispatched a task and never got a terminal status for it.
Most runs never load it.

A stuck task's sub-agent died with the session, so what it left on disk is
unknown. Never re-dispatch one blind. For each id `stuck` printed:

```bash
RADIN_CLI state recover "$NAMESPACE_DIR" "<task id>"
```

Exit 0: it already finished the recovery — print the
`recovered<TAB><id><TAB><what it did>` line it printed and move on.

Exit 3: the one branch no command can settle. A dead sub-agent committed work
on the task's branch but never reported, so it printed the `branch`,
`worktree` and `branch_commit` lines. Read those commits (`git show`) against
one bar, and never against your own reconstruction of what the task wanted —
the bar is the criteria the entry states:

```bash
RADIN_CLI backlog meta "<task id>"
```

It prints one `acceptance<TAB><criterion>` line per criterion the entry states,
and none when it states none.

- **There is at least one `acceptance` line and the commits meet every one of
  them**: `RADIN_CLI state task-done "$NAMESPACE_DIR" "<task id>" "<last
  hash>"`.
- **Anything else** — a criterion the commits miss, a criterion you cannot
  settle without running the project's checks, or no `acceptance` line at all:
  `RADIN_CLI state recover-reject "$NAMESPACE_DIR" "<task id>"`. Partial work
  is the user's call, and the command blocks the entry naming the branch and
  worktree to inspect. An entry stating no criteria always lands here.

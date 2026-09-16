# Shared: radin-execute Dirty-Tree Recovery

`radin-execute` reads this file only when Step 4b's `dirty-check` prints
something — a sub-agent violated the no-dirty-tree contract, whatever its
`STATUS:` said. A session whose sub-agents all commit their work never loads
it.

`$TASK_DIR` below is the directory Step 4b already resolved with
`radin-state.sh task-dir`, which is not `$REPO_ROOT` in worktree mode.

- Park the work (`.claude/.radin/` excluded as in `dirty-check`; prints the
  stash ref):

  ```bash
  RADIN_CLI state stash "$TASK_DIR" "radin-execute: task <order> '<title>' left uncommitted (sub-agent reported <STATUS value>)"
  ```

- Mark the task `failed`, `note`: `"sub-agent left uncommitted changes in
  <TASK_DIR>, stashed as <ref>. Run 'git -C <TASK_DIR> stash show -p <ref>'
  to inspect, 'git -C <TASK_DIR> stash pop' to recover."`
- Report: `⚠️ Task <order> '<title>': sub-agent reported <STATUS value> but
  left a dirty tree. Stashed as <ref>, treated as failed.`
- Continue to the next task on a clean tree.

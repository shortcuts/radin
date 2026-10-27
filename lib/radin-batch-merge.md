# Shared: radin-batch Merge

`radin-batch` reads this file at Phase 5.5, after the summary, only when `worktree` or `branch` is `yes` in `RADIN_CLI state session-get`.

Run `RADIN_CLI state merge` and print its output, unasked. Exit 0: stop. Any branch or worktree it kept is printed with its reason. Exit 3: a branch conflicted, so run `RADIN_CLI prompt merge`. Dispatch one sub-agent (`name: "radin-merge"`, the printed `model` and `effort`, when printed) with `Read <the printed prompt path> and follow it.`

Print the last `STATUS:` line verbatim. On `BLOCKED (DECISION)`, ask the user which behavior wins with `AskUserQuestion`. Then dispatch one new `radin-merge` agent for that branch only, with the answer appended to the prompt. A `FAILED` line or a last line that is not a `STATUS:` line goes to the user verbatim, and the branches stay in place.

A clean merge also records each merged task done. A skipped merge leaves the task blocked, and Phase 0's `reconcile` finishes it.

Phase 0's `reconcile` also uses the conflict path. It passes the `conflict` branches to `RADIN_CLI prompt merge`.

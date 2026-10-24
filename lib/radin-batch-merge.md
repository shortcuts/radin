# Shared: radin-batch Merge

`radin-batch` reads this file at Phase 5.5, after the summary, only when `worktree` or `branch` is `yes` in `RADIN_CLI state session-get`.

Run `RADIN_CLI state merge-list`. Exit 1: no task branch is left to merge, so stop. Otherwise print its lines and ask with `AskUserQuestion`: "Merge these task branches into `<base>` now?" Options: "Merge all (Recommended)" and "Skip, I merge by hand". The answer covers every branch.

On "Skip", stop. The Phase 5 summary already prints each `git merge` command.

On "Merge all", run `RADIN_CLI prompt merge`. Dispatch one sub-agent (`name: "radin-merge"`, the printed `model`) with `Read <the printed prompt path> and follow it.`

Print the last `STATUS:` line verbatim. On `BLOCKED (DECISION)`, ask the user which behavior wins with `AskUserQuestion`. Then dispatch one new `radin-merge` agent for that branch only, with the answer appended to the prompt. A `FAILED` line or a last line that is not a `STATUS:` line goes to the user verbatim, and the branches stay in place.

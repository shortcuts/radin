# Shared: radin-batch Merge

`radin-batch` reads this file at Phase 0 on a `leftovers` line, and at Phase 5.5 when `worktree` or `branch` is `yes` in `RADIN_CLI state session-get`.

Run `RADIN_CLI state reconcile` and print its output, unasked. Exit 0: stop. Any branch or worktree it kept is printed with its reason. Exit 3: a branch conflicted, so run `RADIN_CLI prompt merge <the conflict branches>`. Dispatch one sub-agent (`name: "radin-merge"`, the printed `model` and `effort`, when printed) with `Read <the printed prompt path> and follow it.`

Print the last `STATUS:` line verbatim. On `SUCCESS`, run `RADIN_CLI state reconcile` again and print its output: it records the leaf's merges. On `BLOCKED (DECISION)`, ask the user which behavior wins with `AskUserQuestion`. Then dispatch one new `radin-merge` agent for that branch only, with the answer appended to the prompt. A `FAILED` line or a last line that is not a `STATUS:` line goes to the user verbatim, and the branches stay in place.

Every landed task is recorded done. An unfinished one (failed, blocked, inconclusive, deferred) first gets a `Finish: <title>` entry that names the original task and the landing commit, printed as a `follow-up` line. Its dependents move to that entry.

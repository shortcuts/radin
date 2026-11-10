# Shared: radin-batch Merge

`radin-batch` reads this file when `RADIN_CLI state reconcile` exits 3: a branch conflicted.

Run `RADIN_CLI prompt merge <the conflict branches>`. Dispatch one sub-agent (`name: "radin-merge"`, the printed `model` and `effort`, when printed) with `Read <the printed prompt path> and follow it.`

<!-- host:claude -->
Print the last `STATUS:` line verbatim. On `SUCCESS`, run `RADIN_CLI state reconcile` again and print its output: it records the leaf's merges. On `BLOCKED (DECISION)`, ask the user which behavior wins with `AskUserQuestion`. Then dispatch one new `radin-merge` agent for that branch only, with the answer appended to the prompt. A `FAILED` line or a last line that is not a `STATUS:` line goes to the user verbatim, and the branches stay in place.
<!-- /host -->
<!-- host:agents -->
Print the last `STATUS:` line verbatim. On `SUCCESS`, run `RADIN_CLI state reconcile` again and print its output: it records the leaf's merges. On `BLOCKED (DECISION)`, ask the user which behavior wins per `RADIN_LIB/radin-ask-rule.md`. Then dispatch one new `radin-merge` agent for that branch only, with the answer appended to the prompt. A `FAILED` line or a last line that is not a `STATUS:` line goes to the user verbatim, and the branches stay in place.
<!-- /host -->

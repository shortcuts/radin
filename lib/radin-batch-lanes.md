# Shared: radin-batch Lane Sync and Parked Tasks

`radin-batch` reads this file in lanes mode (`RADIN_CLI state lanes-show` prints `mode<TAB>lanes`).

Before each lane task, run `RADIN_CLI state lane-sync "<id>"` and route on the first field of its line.

- `current` or `skipped`: dispatch the task.
- `synced`: dispatch the task.
- `conflict` (exit 3): run `RADIN_CLI prompt sync "<id>"`, then dispatch one sub-agent (`name: "radin-sync"`, the printed `model` and `effort`, when printed) with `Read <the printed prompt path> and follow it.`

Route the sync agent's last `STATUS:` line.

- `SUCCESS`: run `RADIN_CLI state lane-sync "<id>"` again. Expect `synced` or `current`, then dispatch the task.
<!-- host:claude -->
- `BLOCKED (DECISION)`: ask the user which behavior wins with `AskUserQuestion`. Append the answer with `RADIN_CLI backlog append "<id>"`, then run `RADIN_CLI prompt sync "<id>"` and dispatch once more.
<!-- /host -->
<!-- host:agents -->
- `BLOCKED (DECISION)`: ask the user which behavior wins per `RADIN_LIB/radin-ask-rule.md`. Append the answer with `RADIN_CLI backlog append "<id>"`, then run `RADIN_CLI prompt sync "<id>"` and dispatch once more.
<!-- /host -->
- `FAILED`, or a last line that is not a `STATUS:` line: run `RADIN_CLI state lane-sync "<id>" --abort`, then `RADIN_CLI state set-status "<id>" failed "<reason>"`. The lane moves on to its next ready task.

A `parked<TAB>` line in a `task-report` output means the task's partial work now sits on `radin/wip/<id>` and the lane is back at its last finished commit. Print the line verbatim and keep the lane running.

`RADIN_CLI state prepare "<id>"` merges `radin/wip/<id>` back on the next batch. No router step resumes a parked task.

## Merge queue

When a lane has no ready task left, run `RADIN_CLI state lane-queue "<epic>"`. Then loop `RADIN_CLI state lane-merge` and route on the first field of its line.

- `merged`: run `RADIN_CLI state lane-done "<epic>"`, then loop.
- `waiting` (exit 2): stop the loop. The next `lane-done` frees the queue.
- `held`: loop.
- no output (exit 1): the queue is empty. Stop.
- `conflict` (exit 3): run `RADIN_CLI prompt sync --lane "<epic>" "<dir>"`, then dispatch the sync agent exactly as above.

Route the conflict agent's last `STATUS:` line.

- `SUCCESS`: loop.
<!-- host:claude -->
- `BLOCKED (DECISION)`: ask the user which behavior wins with `AskUserQuestion`. Run `RADIN_CLI state lane-merge` (it conflicts again), then `RADIN_CLI prompt sync --lane "<epic>" "<dir>" "<answer>"` and dispatch once more.
<!-- /host -->
<!-- host:agents -->
- `BLOCKED (DECISION)`: ask the user which behavior wins per `RADIN_LIB/radin-ask-rule.md`. Run `RADIN_CLI state lane-merge` (it conflicts again), then `RADIN_CLI prompt sync --lane "<epic>" "<dir>" "<answer>"` and dispatch once more.
<!-- /host -->
- `FAILED`, or a last line that is not a `STATUS:` line: run `RADIN_CLI state lane-merge --abort`, which holds the lane on its branch, then loop.

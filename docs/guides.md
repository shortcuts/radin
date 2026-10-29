# How-to guides

Short recipes for tasks you already understand.
New to radin? Start with the [tutorial](tutorial.md).

## Run only one epic or one task

Name it in the prompt:

```text
/radin-batch run the auth-rework epic
```

radin runs the named tasks and every task they depend on.

## Run the backlog without blocking your session

Dispatch `/radin-batch` from `claude agents` or from a second `claude` session.
Answer yes to the worktree question, so each task gets its own checkout and
concurrent runs never share one.

## Share the backlog with your team

Commit `.claude/.radin/`. Every teammate with radin installed sees the same tasks.
To keep the backlog private, add the directory to your own ignore file.
radin never edits your `.gitignore`.

## Turn review findings into tasks

Run `/radin-review` on a commit, a PR or a directory.
Choose which findings to keep. Kept findings become backlog tasks,
or go straight to `/radin-do`.

## Add a task by hand

```sh
printf 'Body of the task.\n' | radin backlog add fix "Short title"
```

The command prints the task id. Run `radin backlog help add` for the optional flags.

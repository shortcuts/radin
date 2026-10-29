# Tutorial: ship your first task with radin

In this tutorial, you record a task, plan it, and let radin implement it as one commit.
It takes about ten minutes. You need no prior radin experience.

## Before you start

- Install radin: [Install, update and uninstall](install.md).
- Pick a git repo you can change safely. A scratch repo works.
- Open a terminal in that repo and start `claude`.

## 1. Record a task

Type this in the Claude Code prompt:

```text
/radin-record add a --version flag to the CLI
```

radin writes one task into `.claude/.radin/` in your repo.
It prints a short id for the task and a verdict on whether the task needs a plan.

## 2. See the task

In a second terminal, in the same repo:

```sh
radin backlog show
```

You see your task under its category.

Now run bare `radin`. The full-screen browser opens with your task selected.
Press `?` for the keys and `q` to leave.

## 3. Plan the task

Back in Claude Code:

```text
/radin-plan add a --version flag to the CLI
```

radin writes a plan and changes no code. Read the plan in the TUI: select the task, then press `l`.
Press `h` to go back to the task body.

## 4. Implement the task

```text
/radin-batch run the --version task
```

radin prints the execution order and asks which tasks to run now.
It may also ask whether to use a worktree. Answer, and the run starts.
A sub-agent reads the plan, makes the change, checks its own diff, and commits.

## 5. Check the result

```sh
git log --oneline -3
```

You see one new commit for the task.

## What you learned

You recorded, planned and executed one task. To work a whole backlog, run `/radin-batch` with no task name.
For what happens inside the run, read [How radin works](how-it-works.md).

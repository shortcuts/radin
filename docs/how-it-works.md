# How radin works

radin has two parts: a backlog that outlives the conversation, and an agent harness
(the router, checks and gates that surround the model) that works the backlog. This page explains why each part looks the way it does.
For the exact commands, see [Reference](reference.md).
For every constraint and its reason, see [DECISIONS.md](DECISIONS.md).

## The backlog is files, not chat

A bug you spot mid-session usually dies with the session. radin stores each task as a
markdown file under `.claude/.radin/` in your repo, and keeps an index beside them.

- A task is a unit of work with a category, an optional priority and optional dependencies.
- An epic groups tasks. Its `DESCRIPTION.md` is context that every child task inherits.
- Plans, reviews and run state sit in the same directory, so a run can resume after an interruption.

The CLI owns every write. A skill or a person never edits the index by hand,
so a half-finished edit cannot corrupt the backlog.

## The harness: orchestrator and workers

The implementation loop follows the orchestrator-workers pattern.
A router orchestrates. Fresh sub-agents do the work.

The router runs in your own conversation, so it can ask you questions and you can interrupt it.
It holds ids, titles, order and exit codes, and nothing else.
This is context engineering. The router's context is the session's budget,
so it stays small and every large read happens in a worker.

Each worker takes exactly one task, starts with an empty context,
and returns one `STATUS:` line. It never spawns another worker.
A cold start costs a few reads. Batching several tasks into one worker would cost more
in context and make one failure spoil several tasks.

## The verify loop

The worker that writes a diff is a weak reviewer of it. radin checks work at three points.

1. **Plan time.** radin lints a plan for missing sections before a task uses it.
   Plans are written one task at a time, because a plan for the whole backlog goes stale
   when an earlier commit changes the tree.
2. **Task time.** The worker picks its checks from what its diff reaches in the code graph.
   It reviews its own staged diff, and a failing check gets three rounds before radin marks the task `FAILED`.
3. **Session time.** One review gate runs at the end. It runs lint and format, reviews every commit of the session,
   and files its findings as new tasks. The loop runs those tasks, and the gate does not run a second review.
   A risky change gets a stricter review than a safe one.

This is a verify loop with a review gate. It is not an eval loop:
radin does not score model output against a benchmark.

## Cost control

Four choices lower token use.

- **A small router.** Its context grows by one status line per task, so it stays cheap over a long run.
- **The cheaper model for easy tasks.** Only a task rated `low` complexity runs on the minor model.
  Category does not decide it, because a `chore` can be hard.
- **Deterministic work in code.** Ordering, status and merging run in the CLI, so no model call pays for them.
- **A tool stack** that compresses command output and agent prose, described next.

## The tool stack

radin delegates each job to one tool and never rebuilds it.
The installer installs, configures and wires each tool. radin does not fork any of them.

| Job | Tool |
| --- | --- |
| Compress command output | [rtk](https://github.com/rtk-ai/rtk) |
| Compress agent prose | [caveman](https://github.com/JuliusBrussee/caveman) |
| Keep each change minimal | [ponytail](https://github.com/DietrichGebert/ponytail) |
| Answer structure questions from a graph | [codebase-memory-mcp](https://github.com/DeusData/codebase-memory-mcp) |
| Review maintainability | [thermo-nuclear](https://github.com/cursor/plugins/tree/main/cursor-team-kit/skills/thermo-nuclear-code-quality-review) |
| Interview, research, diagnose, design | [mattpocock-skills](https://github.com/mattpocock/skills) |
| Strip AI-slop patterns from prose | [unslop](https://github.com/cursor/plugins/tree/main/pstack/skills/unslop) |
| Write docs and agent-facing prose | [technical-writing](https://github.com/cursor/plugins/tree/main/pstack/skills/technical-writing) |

The savings figures in each tool's README are the tool's own claims. `/radin-stats` prints
what each tool measured on your machine.

## Trade-offs to know

- `unslop` and `technical-writing` come from cursor/plugins `main`. The installer fetches them on every install and update, unpinned.
  An upstream edit changes agent behavior without review.
- A code graph answer is a pointer, never proof that something does not exist. Read the file before you edit it.
- `codebase-memory-mcp update` rewrites config and can drop other tools' hooks.
  radin snapshots the config first and `radin repair` restores the hooks.
- The worker that wrote a diff also reviews it. The session gate adds a second look, which is cheaper than a reviewer per task.

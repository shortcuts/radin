# Lifecycle diagrams

Four diagrams show how the skills, the run loop, and one task move.
[Pele](https://pele.run) renders each `.mmd` source in `docs/lifecycle/` to an SVG.

To re-render after an edit:

```bash
make diagrams
```

## 1. Skills

You talk to the skills. Each skill reads and writes the backlog through the `radin backlog` CLI.

![Skill lifecycle](lifecycle/skills.svg)

## 2. Router loop

`/radin-batch` and `/radin-do` run this loop from `lib/radin-run.md`.
The router holds ids and exit codes only. Each leaf does the work and returns one `STATUS:` line.

![Router loop](lifecycle/router-loop.svg)

## 3. Leaf loop

One execution leaf takes one task. Source: `lib/radin-prompt-execution.md`.

![Leaf loop](lifecycle/leaf-loop.svg)

## 4. Task status

`radin state set-status` and `task-report` own every arrow.

![Task status](lifecycle/task-status.svg)

# Reference

## Skills

| Skill | Purpose |
| --- | --- |
| `/radin-record` | Save a bug, idea or follow-up from this session as a backlog task. |
| `/radin-plan` | Write an implementation plan for one task. Touches no code. |
| `/radin-batch` | Work the backlog in priority order, or only the epic or tasks you name. One task per commit. |
| `/radin-do` | Record one ad-hoc prompt as a task, plan it when flagged, then execute only that task. |
| `/radin-review` | Review a commit, PR, directory or range. Triage the findings into backlog tasks. |
| `/radin-stats` | Print each companion tool's own savings report. |
| `/radin-uninstall` | Remove what `install.sh` put in `~/.claude`. |

## CLI

`radin <backlog|state|scope|prompt|stats|hooks|wire|repair|update|doctor|uninstall> [args]`

| Command | Purpose |
| --- | --- |
| `radin` | Open the TUI on a terminal. Off a terminal, print usage and exit non-zero. |
| `radin help` | Print usage. |
| `radin backlog show` | Print the backlog as markdown. |
| `radin backlog help [verb]` | Print every backlog verb, or one. |
| `radin state help` | Print every state verb. |
| `radin update` | Update radin. |
| `radin doctor` | Check the install. |
| `radin repair` | Restore hooks and the MCP entry that another tool's config write dropped. |
| `radin stats` | Print skill, command and sub-agent use on this device. |

Each subcommand prints its own usage when run with no arguments.

## Installer flags

Pass them after `bash`: `curl … | bash -s -- --yes`.

| Flag | Effect |
| --- | --- |
| `--yes` | Accept every default and ask nothing. |
| `--verbose` | Trace every command. |
| `--update` | Update an existing install. |

## Task fields

| Field | Values |
| --- | --- |
| `category` | `feat`, `fix`, `chore`, `refactor` |
| `priority` | `1`, `2`, `3`, `5`, `8`, `13`, `21`. Higher runs first. Unset runs last. |
| `depends_on` | Task ids or titles. radin rejects a cycle. |
| `acceptance` | Zero or more criteria. |
| `location` | A `path:line` pointer. |
| `planning` | `needed` when the task must be planned first. |
| `complexity` | `low` or `high`. Only `low` runs on the cheaper model. |

## Files

| Path | Holds |
| --- | --- |
| `<repo>/.claude/.radin/backlog/` | The index and one markdown file per task. |
| `<repo>/.claude/.radin/plans/` | One plan per planned task. |
| `<repo>/.claude/.radin/reviews/` | Review output. |
| `<repo>/.claude/.radin/state/` | Run state: order, session answers, task status, facts. |
| `~/.claude/.radin/` | The installed CLI, libraries and config backups. |

## TUI keys

Press `?` in the TUI for the full list. The main keys:

| Key | Action |
| --- | --- |
| `j` / `k` | Move. |
| `enter` | Open. |
| `e` | Edit. |
| `v` | Toggle the detail pane. |
| `l` / `h` | Show the plan or the body. |
| `/` | Search. |
| `a` | New task. |
| `Tab` | Mark done. |
| `o` | Page the execution order. |
| `Shift-A`, `Shift-P`, `Shift-C`, `Shift-T` | Sort for this session. |
| `q` | Quit. |

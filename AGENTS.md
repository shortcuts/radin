# radin — Agent Reference

Read before touch any file here. radin be Claude Code plugin: skills, CLI, install glue. Bash, plus two C file (TUI and JSON helper). macOS and Linux.

## Hard rules

- **bash 3.2** (macOS ship it): no associative array, no `mapfile`, no
  `${var,,}`. No `uname` branch — resolve through `command -v` /
  `brew shellenv`, branch only where tool differ (`md5` vs `md5sum`).
  Call out every script edit explicitly.
- **`~/.claude` not ours.** `install.sh` only `cp` radin own named
  files and `mkdir -p`. Never `rm`, never wildcard-delete, never overwrite
  file radin not ship. Two exception: the
  `<!-- radin:begin -->`…`<!-- radin:end -->` block in `~/.claude/CLAUDE.md`,
  and `lib/radin-cbm-config.sh` snapshot/restore of `settings.json` +
  `~/.claude.json`. Call out every `install.sh` edit explicitly.
- **Companion install be advisory.** Failure warn, run continue.
  Not optional, and nothing asked about them.

## Where to edit what

| Change | Edit |
| --- | --- |
| A skill's behavior | `skills/<name>/SKILL.md` — truth source, never installed copy |
| Anything deterministic (install, update, doctor, uninstall, backlog, state, TUI) | a `bin/radin` subcommand in `lib/`, never skill |
| Rare-need part of `radin-execute` | `lib/radin-execute-*.md`, read on demand |
| Concurrency rule, sub-agent model, how CLI invoked | none — write token, `install.sh` resolve it ([how](docs/architecture.md#install-time-substitution)) |

`install.sh` go one way, repo to `~/.claude`. New skill need
`cp -r` line there, `lib/radin-doctor.sh` entry, README row and
`docs/architecture.md` mention, or it ship nowhere.

## Storage

`<repo-root>/.claude/.radin/` (outside repo, `$PWD`): `backlog/`
(`index.jsonl` + `tasks/<id>.md`), `state/`, `plans/`, `reviews/`. Format in
[docs/domain-models.md](docs/domain-models.md), schema in
`docs/schemas/backlog-entry.schema.json`. Only thing radin write
into consumer repo, and radin never touch their `.gitignore`.

Read and write it only through CLI (`radin backlog …`, `radin state …`).
Nothing parse `index.jsonl` or `completed.json`, or grab task by line
number. Data view need but no subcommand give mean add one.

## Skills, agents, sub-agents

Every entry point be skill, because it run in user thread and can
talk to them. Sub-agent cannot: no prose to user, no `AskUserQuestion`,
no background-task notification — all three look like hang. Sub-agent be
leaf worker skill dispatch, so before point prompt at skill check
it ask user nothing and spawn no agent
([constraints](docs/technical-constraints.md)). Every prompt that name
companion gate on `command -v` and carry escape clause: drop skill,
never wait on it.

## Delegation: one owner per job

If shipped tool do job, name it; never write radin own version. Each
delegation named in exactly one file — second copy drift silent, and
[test pin every name](docs/architecture.md#delegation-is-pinned-by-a-test).

| Job | Owner |
| --- | --- |
| Settle a decision · API facts · module boundaries · diagnose a failure | `/mattpocock-skills:grilling` · `:research` · `:codebase-design` · `:diagnosing-bugs` |
| Minimal change · over-engineering · debt ledger | `/ponytail:ponytail` · `-review`/`-audit` · `-debt` |
| Maintainability review · commit message | `/thermo-nuclear` · `/caveman:caveman-commit` |
| Implementation discipline | `/caveman:surgical-patch` (fix), `safe-refactor`, `lean-build` (feat) |
| Code structure questions | codebase-memory-mcp's MCP tools |
| Output compression · structural search/diff | `rtk` · `headroom sg`/`diff`/`loc` |

Graph tool name live in four files only and must exist in upstream table —
wrong one cost failed call in every sub-agent
([which files, and the pointer rule](docs/architecture.md#code-graph-wiring-codebase-memory-mcp)).

## Decisions that look like bugs

- **No per-task verification in `radin-execute`**, and `FAILED` task get
  Debug prompt once per session ([why](docs/architecture.md#verification-in-radin-execute)).
- **What sub-agent learn stay on its task** — a `**Fact:**` or
  `**Root cause:**` line, long form in `state/facts/<id>.md`. No shared note
  file, no cross-task memory.
- **`radin-execute` worktree/branch answer never reach prompt**;
  `radin-state.sh prepare` be only place they become git command. Model
  handed them eventually override a `no`.
- **`lib/radin-cbm-config.sh` snapshot before upstream write**, because that
  installer replace whole hook array instead of merge; drop it and
  machine lose hooks silent ([limits](docs/technical-constraints.md)).
- **Two C file only: TUI (`lib/radin-tui.c`) and JSON helper
  (`lib/radin-cbm-json.c`).** TUI draw and dispatch keys only — raw ANSI,
  `termios`, every mutation shell out to `radin-backlog.sh`. Helper hold every
  JSON rule `radin cbm-config` and `radin cbm-hooks mcp` need; those script
  keep none, and radin need no python of own. `install.sh` build
  both with `cc`, advisory: no compiler mean no `radin tui`, no
  `radin cbm-config`, and `radin cbm-hooks mcp` print entry to paste by hand,
  rest still install
  ([rules](docs/architecture.md#the-human-tui)).

## Before committing

- `make lint` and `make test` clean, and `make test` stay under 20s. Keep it
  there: one recorded `install.sh` run every tree-only test replay, live run
  only for install-time behaviour, mock command be `tests/helpers/mock.c` (one
  compiled binary, not a shell stub per command — `/bin/sh` startup cost 20ms
  a call), and no test make network request.
- Docs updated in same commit: `docs/architecture.md` (layout, namespace
  resolution), `docs/domain-models.md` (format), README (new skill or
  companion), `CHANGELOG.md` (user-facing change).

Details: [architecture](docs/architecture.md) ·
[domain models](docs/domain-models.md) ·
[constraints](docs/technical-constraints.md) · [contributing](CONTRIBUTING.md)

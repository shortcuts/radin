# radin — Agent Reference

radin be Claude Code plugin: skills, CLI, install glue. Bash, plus two C file (TUI and JSON helper). macOS and Linux.

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
  Not optional. One question only: which package manager install them
  (`brew`/`mise`/`curl`), so radin add no manager user not already run.

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

New companion that ship own stats or gain command need bullet in
`skills/radin-stats/SKILL.md`, or roundup never see it.

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

## Writing prose for agents

- **No-op test.** Sentence that not change what model do versus its default
  pay load and say nothing. Delete whole sentence, never trim word out of it.
- **Positive over prohibition.** Ban drag banned behaviour into context and
  half-read as instruction to do it. State target behaviour. Keep prohibition
  only as hard guardrail with no positive phrasing, then pair it with target.

Rest live elsewhere: `/mattpocock-skills:writing-for-agents` full rule set
(leading word, completion criterion, progressive disclosure),
`STE` output style sentence craft, `no-ai-slop` human-facing prose,
[one rule, one file](docs/architecture.md#one-rule-one-file) where rule live.

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
| Agent-doc writing rules | `/mattpocock-skills:writing-for-agents` |

Graph tool name live in two files only and must exist in upstream table —
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
  JSON rule `radin repair` and `radin hooks mcp` need; those script
  keep none, and radin need no python of own. `install.sh` build
  both with `cc`, advisory: no compiler mean no TUI, no
  `radin repair`, and `radin hooks mcp` print entry to paste by hand,
  rest still install
  ([rules](docs/architecture.md#the-human-tui)).
- **`order` move dependency UP, never dependent down.** Human priority
  ranking survive as far as dep graph allow; Kahn with priority tie-break
  discard more of it.
- **TUI load `backlog list --order created`**, so mutation reorder nothing and
  row stay put. `Shift-A`/`Shift-P`/`Shift-C`/`Shift-T` be only reorder,
  session-only, active one in header. CLI default stay `priority` — that be
  ordering contract `radin-prioritization.md` read.

## Before committing

- `make lint` and `make test` clean, and `make test` stay under 40s. Keep it
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

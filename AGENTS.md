# radin Agent Reference

radin is a Claude Code plugin made of skills, a CLI, and install glue. It is written in Bash, plus two C files (the TUI and the JSON helper), and it runs on macOS and Linux.

## Hard rules

- **bash 3.2** (macOS ships it): Do not use associative arrays, `mapfile`, or `${var,,}`. Do not add a `uname` branch. Resolve tools through `command -v` or `brew shellenv`, and branch only where a tool differs (`md5` versus `md5sum`). Call out every script edit explicitly.
- **`~/.claude` is not ours.** `install.sh` runs `cp` only on radin's own named files, and it runs `mkdir -p`. It never runs `rm`, never deletes with a wildcard, and never overwrites a file that radin does not ship. There are three exceptions. The first is the `<!-- radin:begin -->`…`<!-- radin:end -->` block in `~/.claude/CLAUDE.md`. The second is the `lib/radin-cbm-config.sh` snapshot and restore of `settings.json` and `~/.claude.json`. The third is `skills/unslop/SKILL.md` and `skills/technical-writing/SKILL.md`. `install.sh` fetches those two skills from upstream, and it overwrites them only when `manifest.json` records them as radin's own. Call out every `install.sh` edit explicitly.
- **Companion install is advisory.** When an install fails, it prints a warning, and the run continues. This behavior is not optional. The installer asks one question: which package manager installs the companions (`brew`, `mise`, or `curl`). radin adds no package manager that the user has not already run.

## Where to edit what

| Change | Edit |
| --- | --- |
| A skill's behavior | `skills/<name>/SKILL.md`. It is the source of truth, never the installed copy. |
| Anything deterministic (install, update, doctor, uninstall, backlog, state, TUI) | A `bin/radin` subcommand in `lib/`, never a skill. |
| Backlog loop `radin-execute` and `radin-implement` share | `lib/radin-run.md`. Each `SKILL.md` keeps only its no-plan rule. |
| Rare-need part of `radin-execute` | `lib/radin-execute-*.md`, read on demand. |
| Sub-agent model, how CLI invoked | Nothing. Write a token, and `install.sh` resolves it ([how](docs/architecture.md#install-time-substitution)). |

`install.sh` goes one way, from the repo to `~/.claude`. A new skill needs a `cp -r` entry there, an entry in `lib/radin-doctor.sh`, a README row, and a `docs/architecture.md` layout entry. `tests/skill-names.bats` fails when one is missing.

A new companion that ships its own stats or a gain command needs a bullet in `skills/radin-stats/SKILL.md`. Without that bullet, the roundup never sees it.

## Storage

The state directory is `<repo-root>/.claude/.radin/`. It sits outside the repo, under `$PWD`. It holds `backlog/` (`index.jsonl` + `tasks/<id>.md`), `state/`, `plans/`, and `reviews/`. The format is described in [docs/domain-models.md](docs/domain-models.md). It is the only thing radin writes into a consumer repo, and radin never touches that repo's `.gitignore`.

Read and write this directory only through the CLI (`radin backlog …`, `radin state …`). No code parses `index.jsonl` or `completed.json`, and no code grabs a task by line number. If a data view is needed and no subcommand provides it, add a subcommand.

## Skills, agents, sub-agents

Every entry point is a skill, because a skill runs in the user's thread and can talk to the user. A sub-agent cannot. It has no prose to the user, no `AskUserQuestion`, and no background-task notification. All three look like a hang. A sub-agent is a leaf worker that a skill dispatches. Before a prompt points at a skill, check that the skill asks the user nothing and spawns no agent ([constraints](docs/technical-constraints.md)). Every prompt names its companion directly, with no `command -v` gate and no escape clause. The install is all-or-nothing, so a missing tool fails loudly, and that failure counts as a skip. The only guard that stays is a skill that asks a human anything. A sub-agent drops that guard and never waits on it.

## Writing prose for agents

- **No-op test.** A sentence that does not change what the model does, compared with its default, costs payload and says nothing. Delete the whole sentence, and never trim a single word out of it. The test is disputed, so measure it ([how](CONTRIBUTING.md#measure-a-prose-edit)) instead of debating it.
- **Positive over prohibition.** Banned behavior dragged into context gets half-read as an instruction to do it. State the target behavior instead. Keep a prohibition only as a hard guardrail that has no positive phrasing, and then pair it with the target.

The rest lives elsewhere. `/mattpocock-skills:writing-for-agents` holds the full rule set (leading word, completion criterion, progressive disclosure). The `STE` output style covers sentence craft. `no-ai-slop` covers human-facing prose. [One rule, one file](docs/architecture.md#one-rule-one-file) says where each rule lives.

## Delegation: one owner per job

If a shipped tool does a job, name that tool. Never write a radin version of it. Each delegation is named in exactly one file, because a second copy drifts silently, and [a test pins every name](docs/architecture.md#delegation-is-pinned-by-a-test).

| Job | Owner |
| --- | --- |
| Settle a decision · API facts · module boundaries · diagnose a failure | `/mattpocock-skills:grilling` · `:research` · `:codebase-design` · `:diagnosing-bugs` |
| Minimal change · over-engineering · debt ledger | `/ponytail:ponytail` · `-review`/`-audit` · `-debt` |
| Maintainability review · commit message | `/thermo-nuclear` · `/caveman:caveman-commit` |
| Implementation discipline | `/caveman:surgical-patch` (fix), `safe-refactor`, `lean-build` (feat) |
| Code structure questions | codebase-memory-mcp's MCP tools |
| Output compression · structural search/diff | `rtk` · `headroom sg`/`diff`/`loc` |
| Agent-doc writing rules | `/mattpocock-skills:writing-for-agents` |

The graph tool name lives in one file only, and it must exist in the upstream table. A wrong name causes a failed call in every sub-agent ([which files, and the pointer rule](docs/architecture.md#code-graph-wiring-codebase-memory-mcp)).

## Decisions that look like bugs

- **No router-side per-task verification in `radin-execute`.** The leaf verifies and reviews its own staged diff before it commits. A `FAILED` task gets a Debug prompt once per session ([why](docs/architecture.md#verification-in-radin-execute)).
- **What a sub-agent learns stays on its task.** It records a `**Fact:**` or `**Root cause:**` line, and the long form goes in `state/facts/<id>.md`. There is no shared note file and no cross-task memory.
- **The `radin-execute` worktree and branch answers never reach a prompt.** Only `radin-state.sh prepare` turns those answers into git commands. A model that receives them can eventually override a `no`.
- **`lib/radin-cbm-config.sh` takes a snapshot before the upstream write.** The upstream installer replaces the whole hook array instead of merging into it. Without the snapshot, a machine loses its hooks silently ([limits](docs/technical-constraints.md)).
- **Two C files only: the TUI (`lib/radin-tui.c`) and the JSON helper (`lib/radin-cbm-json.c`).** The TUI draws and dispatches keys only. It uses raw ANSI and `termios`, and every mutation shells out to `radin-backlog.sh`. The helper holds every JSON rule that `radin repair` and `radin hooks mcp` need. Those scripts keep none of their own, and radin needs no Python of its own. `install.sh` builds both with `cc`, and that build is advisory. Without a compiler, there is no TUI and no `radin repair`, and `radin hooks mcp` prints an entry for the user to paste by hand. The rest still installs ([rules](docs/architecture.md#the-human-tui)).
- **`order` moves a dependency up, never a dependent down.** The human priority ranking survives as far as the dependency graph allows. Kahn's algorithm with a priority tie-break discards more of it.
- **The TUI loads `backlog list --order created`,** so a mutation reorders nothing and each row stays put. `Shift-A`, `Shift-P`, `Shift-C`, and `Shift-T` are the only reorder keys. They are session-only, and the active one appears in the header. The CLI default stays `priority`. That default is the ordering contract that `radin-prioritization.md` reads.
- **No batching of several tasks into one sub-agent.** One sub-agent takes one task. Each task returns one `STATUS` line, and a failure stays inside its own task. A leaf starts cold, so file-locality ordering saves no tokens.
- **No planning of every task up front as one wave.** A wave plan drifts when an earlier commit changes the tree. Just-in-time planning, one task at a time, is a deliberate defense against drift ([why](docs/architecture.md#verification-in-radin-execute)).
- **No arena or judge at execution level.** N worktrees, N full implementations, and a judge that reads N diffs break the router's low-resolution rule. At planning, the idea stays open as an opt-in. It is tracked in its own backlog entry and gated on a review-origin rollup.
- **No model escalation on retry.** All four major roles (planning, execution, review, and debug) default to sonnet. Escalating on retry therefore changes nothing by default.

## Before committing

- `make lint` and `make test` must come back clean, and `make test` must stay under 60 seconds. Every tree-only test replays one recorded `install.sh` run. A live run serves only install-time behavior. The mock command is `tests/helpers/mock.c`, one compiled binary, not a shell stub per command, because `/bin/sh` startup costs 20 ms per call. No test makes a network request.
- Update the docs in the same commit: `docs/architecture.md` (layout, namespace resolution), `docs/domain-models.md` (format), the README (a new skill or companion), and `CHANGELOG.md` (a user-facing change).

For details, see [architecture](docs/architecture.md) · [domain models](docs/domain-models.md) · [constraints](docs/technical-constraints.md) · [contributing](CONTRIBUTING.md).
